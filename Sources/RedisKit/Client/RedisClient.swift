import Foundation
import RESPWire

/// Where to send a command.
public enum Route: Sendable, Hashable {
    /// By the command's first key (cluster), else the primary node.
    case auto
    case key(RedisKey)
    case slot(Int)
    case node(Endpoint)
}

/// Which nodes a fan-out reaches.
public enum NodeSelection: Sendable, Hashable {
    case masters
    case replicas
    case all
}

public struct NodeReply: Sendable {
    public let endpoint: Endpoint
    public let result: Result<RESPValue, RedisError>
}

public enum ClientEvent: Sendable, Equatable {
    case failover(from: Endpoint, to: Endpoint)
    case topologyRefreshed(masters: Int, replicas: Int)
    case capabilityChanged(Capabilities.Feature)
}

/// A connected deployment: standalone, replica, Sentinel group, Cluster or proxy (design D5–D9).
///
/// Thread-safe; all methods may be called concurrently. Mutable topology state lives in a lock-protected
/// box, connections in per-node pools.
public final class RedisClient: Sendable {
    public let configuration: ClientConfiguration
    public let events: AsyncStream<ClientEvent>

    let registry: NodeRegistry
    let connector: EndpointConnector
    private let tunnels: TunnelManager?
    private let eventSink: AsyncStream<ClientEvent>.Continuation
    private let state: OSAllocatedUnfairLockBox<State>
    private let lastRefresh = OSAllocatedUnfairLockBox<ContinuousClock.Instant?>(nil)

    struct State: Sendable {
        var serverInfo = ServerInfo.unknown
        var capabilities = Capabilities()
        var deployment = Deployment.standalone
        var protocolVersion = 2
        var primary: Endpoint
        var sentinel: Endpoint?
        var slotMap = ClusterSlotMap.empty
        var modules: [ModuleInfo] = []
        var extraSpecs: [String: CommandSpec] = [:]
        var notes: [String] = []
        var info: InfoSnapshot?
    }

    static let maxRedirects = 6

    private init(configuration: ClientConfiguration, connector: @escaping EndpointConnector, tunnels: TunnelManager?, primary: Endpoint) {
        self.configuration = configuration
        self.connector = connector
        self.tunnels = tunnels
        registry = NodeRegistry(basePlan: configuration.basePlan, connector: connector, poolSize: configuration.poolSize,
                                commandTimeout: configuration.commandTimeout, limits: configuration.limits)
        state = OSAllocatedUnfairLockBox(State(primary: primary))
        (events, eventSink) = AsyncStream.makeStream(of: ClientEvent.self, bufferingPolicy: .bufferingNewest(32))
    }

    // MARK: Public state

    public var serverInfo: ServerInfo { state.value.serverInfo }
    public var capabilities: Capabilities { state.value.capabilities }
    public var deployment: Deployment { state.value.deployment }
    public var protocolVersion: Int { state.value.protocolVersion }
    public var primaryEndpoint: Endpoint { state.value.primary }
    public var sentinelEndpoint: Endpoint? { state.value.sentinel }
    public var slotMap: ClusterSlotMap { state.value.slotMap }
    public var modules: [ModuleInfo] { state.value.modules }
    /// Facts worth telling the user (auto-detected cluster, replica, password not needed…).
    public var notes: [String] { state.value.notes }
    /// The INFO reply seen while connecting (nil when INFO is unavailable).
    public var initialInfo: InfoSnapshot? { state.value.info }
    public var isTunnelled: Bool { tunnels != nil }
    public var usesTLS: Bool { configuration.tls != nil }

    /// Writes are blocked by the profile or because the connection is to a replica.
    public var isReadOnly: Bool {
        if configuration.readOnly { return true }
        if case .sentinel = deployment, case let .sentinel(_, _, role) = configuration.mode, role == .replica { return true }
        return deployment == .replica
    }

    public var hasJSONModule: Bool { modules.contains(where: \.isJSON) }

    /// Masters (cluster) or the primary node.
    public var masterEndpoints: [Endpoint] {
        let current = state.value
        if current.deployment.isCluster, !current.slotMap.shards.isEmpty { return current.slotMap.masters.map(\.endpoint) }
        return [current.primary]
    }

    /// Nodes to scan for keys: masters, or one replica per shard when `scanReplicas` is set.
    public var scanEndpoints: [(endpoint: Endpoint, isReplica: Bool)] {
        let current = state.value
        guard current.deployment.isCluster, !current.slotMap.shards.isEmpty else { return [(current.primary, false)] }
        return current.slotMap.shards.map { shard in
            if configuration.scanReplicas, let replica = shard.replicas.first(where: { $0.health != "failed" }) {
                return (replica.endpoint, true)
            }
            return (shard.master.endpoint, false)
        }
    }

    public func spec(for command: RedisCommand) -> CommandSpec? {
        if let known = CommandSpecs.spec(for: command) { return known }
        let extra = state.value.extraSpecs
        return extra[command.qualifiedName] ?? extra[command.name]
    }

    /// Commands the server reported that the static table lacks (module commands etc.).
    public var serverOnlyCommands: [CommandSpec] { Array(state.value.extraSpecs.values) }

    // MARK: Connect

    public static func connect(_ configuration: ClientConfiguration, transport: @escaping TransportFactory = Transports.network,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RedisClient {
        let tunnels = configuration.ssh.map { TunnelManager(configuration: $0, secret: configuration.sshSecret) }
        let connector = makeConnector(configuration, transport: transport, tunnels: tunnels)
        return try await connect(configuration, connector: connector, tunnels: tunnels, progress: progress)
    }

    /// Connects with a custom endpoint connector (tests, in-process fakes).
    public static func connect(_ configuration: ClientConfiguration, connector: @escaping EndpointConnector, tunnels: TunnelManager? = nil,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RedisClient {
        let initial: Endpoint
        switch configuration.mode {
        case let .standalone(endpoint): initial = endpoint
        case let .sentinel(sentinels, _, _):
            guard let first = sentinels.first else { throw RedisError(.invalidArgument, "Add at least one sentinel address") }
            initial = first
        case let .cluster(seeds):
            guard let first = seeds.first else { throw RedisError(.invalidArgument, "Add at least one cluster seed node") }
            initial = first
        }
        let client = RedisClient(configuration: configuration, connector: connector, tunnels: tunnels, primary: initial)
        do {
            try await client.bootstrap(progress: progress)
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    static func makeConnector(_ configuration: ClientConfiguration, transport: @escaping TransportFactory, tunnels: TunnelManager?) -> EndpointConnector {
        let options = TransportOptions(connectTimeout: configuration.connectTimeout, tls: configuration.tls,
                                       clientCertificatePassword: configuration.clientCertificatePassword)
        let addressMap = configuration.addressMap
        return { endpoint in
            let mapped = addressMap.resolve(endpoint)
            var target = mapped
            if let tunnels { target = try await tunnels.localEndpoint(for: mapped) }
            var effective = options
            if var tls = effective.tls, tls.serverName == nil, target != endpoint, !endpoint.isUnixSocket {
                tls.serverName = endpoint.host // verify the announced identity, not 127.0.0.1
                effective.tls = tls
            }
            return try await transport(target, effective)
        }
    }

    private func bootstrap(progress: @escaping @Sendable (String) -> Void) async throws {
        switch configuration.mode {
        case let .standalone(endpoint):
            progress("Connecting to \(endpoint)…")
            try await detect(on: endpoint)
        case let .sentinel(sentinels, masterName, role):
            progress("Asking sentinels for '\(masterName)'…")
            let resolver = sentinelResolver(sentinels: sentinels, masterName: masterName)
            let target = try await resolveSentinelTarget(resolver, role: role)
            progress("Connecting to \(role == .master ? "master" : "replica") \(target)…")
            try await detect(on: target)
            if role == .master, serverInfo.role == .replica {
                // Failover in progress: the sentinel answered with a stale master.
                try await Task.sleep(for: .milliseconds(800))
                let retry = try await resolveSentinelTarget(resolver, role: role)
                try await detect(on: retry)
                if serverInfo.role == .replica {
                    throw RedisError(.topology, "Sentinel reports \(retry) as master of '\(masterName)', but it is a replica. A failover may be in progress; try again shortly.")
                }
            }
        case let .cluster(seeds):
            var lastError: (any Error)?
            for seed in seeds {
                progress("Connecting to cluster node \(seed)…")
                do {
                    try await detect(on: seed)
                    lastError = nil
                    break
                } catch let error as RedisError where error.isConnectionFailure {
                    lastError = error
                    continue
                }
            }
            if let lastError { throw lastError }
        }
        if deployment.isCluster {
            progress("Loading cluster slots…")
            try await refreshTopology()
        }
    }

    private func sentinelResolver(sentinels: [Endpoint], masterName: String) -> SentinelResolver {
        SentinelResolver(sentinels: sentinels, masterName: masterName, credentials: configuration.sentinelCredentials,
                         connector: connector, timeout: min(configuration.commandTimeout, 10))
    }

    private func resolveSentinelTarget(_ resolver: SentinelResolver, role: ClientConfiguration.SentinelRole) async throws -> Endpoint {
        let (master, sentinel) = try await resolver.resolveMaster()
        state.withLock { $0.sentinel = sentinel }
        guard role == .replica else { return master }
        let replicas = try await resolver.replicas()
        guard let replica = replicas.first(where: \.isHealthy) else {
            throw RedisError(.topology, "Sentinel knows no healthy replica of '\(resolver.masterName)'")
        }
        return replica.endpoint
    }

    // MARK: Detection

    private func detect(on endpoint: Endpoint) async throws {
        let node = try await registry.node(endpoint)
        var info: InfoSnapshot?
        var infoFailure: ProbeFailure?
        do {
            let reply = try await node.pipeline([RedisCommand("INFO")])[0]
            if let message = reply.errorMessage {
                infoFailure = .message(message)
            } else if let text = reply.string ?? reply.text {
                info = InfoSnapshot.parse(text)
            }
        } catch let error as RedisError where error.isConnectionFailure && !error.isConnectStage {
            infoFailure = .dropped
        }
        if case let .message(message) = infoFailure, RedisError.isAuthenticationFailure(message) {
            // Pre-6.0 servers answer HELLO with "unknown command" even to unauthenticated clients and only
            // reveal the missing password on the next command.
            throw RedisError(.authentication, "The server requires a password. Enter the password (and ACL user if any) for this connection.", code: "NOAUTH")
        }

        let handshake = node.firstHandshake
        var server = ServerInfo.unknown
        if let hello = handshake?.hello { server = ServerInfo(hello: hello) }
        if let info {
            let fromInfo = ServerInfo(info: info)
            if fromInfo.family != .unknown || server.family == .unknown { server = fromInfo }
        }
        var notes: [String] = []
        if let note = handshake?.authenticationNote { notes.append(note) }

        // Deployment.
        var deployment: Deployment
        var infoPermissionDenied = false
        var infoDisabled = false
        if case let .proxy(flavor) = configuration.proxyHint {
            deployment = .proxy(flavor)
        } else if let infoFailure {
            if case let .message(message) = infoFailure, message.uppercased().hasPrefix("NOPERM") {
                infoPermissionDenied = true
                deployment = try modeDeployment(server: server, endpoint: endpoint, notes: &notes)
            } else if case .message = infoFailure, handshake?.hello != nil {
                // A server that identified itself via HELLO but refuses INFO has INFO renamed/disabled.
                infoDisabled = true
                deployment = try modeDeployment(server: server, endpoint: endpoint, notes: &notes)
            } else {
                deployment = .proxy(ProxyDetector.classify(infoError: infoFailure, helloDropped: handshake?.helloDroppedConnection ?? false))
            }
        } else if let info, let flavor = ProxyDetector.flavor(fromInfo: info) {
            deployment = .proxy(flavor)
        } else {
            deployment = try modeDeployment(server: server, endpoint: endpoint, notes: &notes)
        }
        // A backend reporting Redis ≥ 6.0 through INFO while HELLO is unknown means a proxy is forwarding INFO.
        if !deployment.isProxy, let version = server.version, version >= ServerVersion(6, 0, 0),
           let reason = handshake?.helloFallbackReason, RedisError.looksLikeUnavailableCommand(reason) {
            deployment = .proxy(ProxyDetector.classify(infoError: .message(reason), helloDropped: false))
        }
        if case let .proxy(flavor) = deployment {
            notes.append("Connected through \(flavor == .unknown ? "a proxy" : flavor.displayName). Features the proxy does not forward are disabled.")
        }

        var capabilities = Capabilities.derive(server: server, deployment: deployment)
        if infoPermissionDenied { capabilities.markUnavailable(.info, reason: "Your ACL user is not allowed to run INFO.") }
        if infoDisabled { capabilities.markUnavailable(.info, reason: "INFO is renamed or disabled on this server.") }
        if handshake?.protocolVersion == 3 { capabilities.markAvailable(.resp3) } else if handshake?.helloFallbackReason != nil {
            capabilities.markUnavailable(.resp3, reason: "RESP3 negotiation failed: \(handshake?.helloFallbackReason ?? "")")
        }

        var modules: [ModuleInfo] = []
        var extraSpecs: [String: CommandSpec] = [:]
        if deployment.isProxy {
            if info != nil { capabilities.markAvailable(.info) }
            try await probeProxyFeatures(node: node, flavor: deploymentFlavor(deployment), capabilities: &capabilities)
        } else {
            var probes: [RedisCommand] = []
            let wantsList = (server.version ?? ServerVersion(7, 0, 0)) >= ServerVersion(7, 0, 0)
            if capabilities.supports(.commandInfo) { probes.append(wantsList ? RedisCommand("COMMAND", ["LIST"]) : RedisCommand("COMMAND")) }
            if capabilities.supports(.modules) { probes.append(RedisCommand("MODULE", ["LIST"])) }
            if !probes.isEmpty, let replies = try? await node.pipeline(probes) {
                if let commandReply = zip(probes, replies).first(where: { $0.0.name == "COMMAND" })?.1,
                   let message = commandReply.errorMessage, RedisError.looksLikeUnavailableCommand(message), !infoDisabled {
                    // COMMAND exists since 2.8.13: refusing it means a proxy sits in front of the server.
                    deployment = .proxy(ProxyDetector.classify(infoError: .message(message), helloDropped: false))
                    notes.append("Connected through a proxy (it forwards INFO but rejects COMMAND). Features the proxy does not forward are disabled.")
                    capabilities = Capabilities.derive(server: server, deployment: deployment)
                    if info != nil { capabilities.markAvailable(.info) }
                    try await probeProxyFeatures(node: node, flavor: deploymentFlavor(deployment), capabilities: &capabilities)
                }
                for (command, reply) in zip(probes, replies) where !reply.isError && !deployment.isProxy {
                    if command.name == "COMMAND" {
                        if command.arguments.count > 1 {
                            capabilities.apply(commandNames: Set((reply.array ?? []).compactMap { $0.string?.lowercased() }))
                        } else {
                            let specs = CommandSpec.parseCommandReply(reply)
                            capabilities.apply(commandNames: Set(specs.filter { !$0.name.contains(" ") }.map { $0.name.lowercased() }))
                            for spec in specs where CommandSpecs.table[spec.name] == nil { extraSpecs[spec.name] = spec }
                        }
                    } else {
                        modules = ModuleInfo.parse(reply)
                    }
                }
            }
            // Name RESP2 connections only once we know this is a real Redis (proxies may drop CLIENT).
            if !deployment.isProxy, handshake?.protocolVersion != 3, server.family != .unknown,
               (server.version ?? ServerVersion(0)) >= ServerVersion(2, 6, 9) {
                await registry.updateAll { $0.setNameOnRESP2 = true }
            }
        }
        if server.role == .replica, deployment == .replica { notes.append("Connected to a replica: the connection is read-only.") }
        await registry.learn(from: node.plan)

        state.withLock { state in
            state.primary = endpoint
            state.serverInfo = server
            state.capabilities = capabilities
            state.deployment = deployment
            state.protocolVersion = handshake?.protocolVersion ?? 2
            state.modules = modules
            state.extraSpecs = extraSpecs
            state.notes = notes
            state.info = info
        }
        if !deployment.isProxy, (server.version ?? ServerVersion(0)) >= ServerVersion(7, 0, 0), capabilities.supports(.commandInfo) {
            Task { [weak self] in await self?.loadServerCommandTable() }
        }
    }

    private func deploymentFlavor(_ deployment: Deployment) -> ProxyFlavor {
        if case let .proxy(flavor) = deployment { return flavor }
        return .unknown
    }

    private func modeDeployment(server: ServerInfo, endpoint: Endpoint, notes: inout [String]) throws -> Deployment {
        if server.mode == "sentinel" || server.role == .sentinel {
            throw RedisError(.invalidArgument, "\(endpoint) is a Sentinel, not a data node. Choose Sentinel mode and enter the master name.")
        }
        switch configuration.mode {
        case let .sentinel(_, masterName, _):
            return .sentinel(masterName: masterName)
        case .cluster:
            guard server.mode == "cluster" else {
                throw RedisError(.invalidArgument, "\(endpoint) is not a cluster node (cluster mode is disabled). Use Standalone mode.")
            }
            return .cluster
        case .standalone:
            if server.mode == "cluster" {
                notes.append("Detected Redis Cluster: commands are routed by hash slot and keys are scanned on every master.")
                return .cluster
            }
            return server.role == .replica ? .replica : .standalone
        }
    }

    /// Probes what a proxy forwards, each command on a connection that is re-opened after a drop.
    private func probeProxyFeatures(node: NodeClient, flavor: ProxyFlavor, capabilities: inout Capabilities) async throws {
        let probes: [(Capabilities.Feature, RedisCommand)] = [
            (.scan, RedisCommand("SCAN", ["0", "COUNT", "1"])),
            (.scanType, RedisCommand("SCAN", ["0", "COUNT", "1", "TYPE", "string"])),
            (.dbsize, RedisCommand("DBSIZE")),
            (.select, RedisCommand("SELECT", [.int(configuration.database)])),
            (.config, RedisCommand("CONFIG", ["GET", "maxmemory"])),
            (.clientList, RedisCommand("CLIENT", ["LIST"])),
            (.slowlog, RedisCommand("SLOWLOG", ["LEN"])),
            (.memoryUsage, RedisCommand("MEMORY", ["USAGE", "__ccinnredis_probe__"])),
            (.pubsubIntrospection, RedisCommand("PUBSUB", ["CHANNELS", "__ccinnredis_probe__"])),
            (.commandInfo, RedisCommand("COMMAND", ["COUNT"])),
            (.modules, RedisCommand("MODULE", ["LIST"])),
            (.role, RedisCommand("ROLE")),
            (.latency, RedisCommand("LATENCY", ["LATEST"])),
            (.pubsub, RedisCommand("SUBSCRIBE", ["__ccinnredis_probe__"])),
        ]
        let name = flavor == .unknown ? "The proxy" : flavor.displayName
        var connection: RedisConnection?
        // A peer that also drops PING and plain reads is not a proxy (e.g. a TLS port spoken to in clear text).
        if flavor == .twemproxy || flavor == .unknown, let probe = try? await node.dedicatedConnection().0 {
            let alive = (try? await probe.pipeline([RedisCommand("PING")], timeout: 5)) != nil
            await probe.close()
            if !alive, let second = try? await node.dedicatedConnection().0 {
                let reads = (try? await second.pipeline([RedisCommand("EXISTS", ["__ccinnredis_probe__"])], timeout: 5)) != nil
                await second.close()
                if !reads {
                    throw RedisError(.network, "\(node.endpoint) closes the connection for every command (HELLO, INFO, PING, EXISTS). If the server expects TLS, enable TLS for this connection; otherwise check that this is a Redis port.")
                }
            }
        }
        for (feature, command) in probes {
            if feature == .scanType, !capabilities.supports(.scan) { continue }
            if connection == nil { connection = try? await node.dedicatedConnection().0 }
            guard let probe = connection else {
                capabilities.markUnavailable(feature, reason: "Could not open a probe connection to check \(feature.title).")
                continue
            }
            do {
                let reply = try await probe.pipeline([command], timeout: 5)[0]
                if let message = reply.errorMessage {
                    let lower = message.lowercased()
                    if RedisError.looksLikeUnavailableCommand(message) || lower.hasPrefix("noperm") || lower.contains("syntax") {
                        capabilities.markUnavailable(feature, reason: "\(name) rejects \(command.qualifiedName): \(message)")
                    } else {
                        capabilities.markAvailable(feature) // the command exists; it just failed on the probe key
                    }
                } else {
                    capabilities.markAvailable(feature)
                    if feature == .clientList { capabilities.markAvailable(.clientKill) }
                    if feature == .slowlog { capabilities.markAvailable(.slowlogClientInfo) }
                }
            } catch {
                capabilities.markUnavailable(feature, reason: "\(name) closed the connection when it received \(command.qualifiedName), so \(feature.title.lowercased()) is not available.")
                connection = nil
            }
            if feature == .pubsub, let used = connection {
                await used.close() // left in subscriber mode
                connection = nil
            }
        }
        if let connection { await connection.close() }
    }

    /// Loads the full `COMMAND` table (7.0+) in the background for routing/completion of module commands.
    private func loadServerCommandTable() async {
        guard let node = try? await registry.node(primaryEndpoint),
              let reply = try? await node.send(RedisCommand("COMMAND"), timeout: 30) else { return }
        var extra: [String: CommandSpec] = [:]
        for spec in CommandSpec.parseCommandReply(reply) where CommandSpecs.table[spec.name] == nil { extra[spec.name] = spec }
        state.withLock { $0.extraSpecs.merge(extra) { current, _ in current } }
    }

    // MARK: Execution

    /// Executes one command; error replies are thrown as `RedisError.server`.
    @discardableResult
    public func execute(_ command: RedisCommand, route: Route = .auto) async throws -> RESPValue {
        let reply = try await executeAllowingErrors(command, route: route)
        if let message = reply.errorMessage { throw RedisError.server(message) }
        return reply
    }

    /// Executes one command and returns error replies as values (console).
    public func executeAllowingErrors(_ command: RedisCommand, route: Route = .auto) async throws -> RESPValue {
        try enforceReadOnly([command])
        switch deployment {
        case .cluster:
            return try await executeInCluster(command, route: route)
        default:
            return try await executeOnPrimary([command], route: route)[0]
        }
    }

    /// Pipelines commands (grouped per node in a cluster); error replies are values, order preserved.
    public func pipeline(_ commands: [RedisCommand]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        try enforceReadOnly(commands)
        guard deployment.isCluster else { return try await executeOnPrimary(commands, route: .auto) }

        var groups: [Endpoint: [Int]] = [:]
        var order: [Endpoint] = []
        for (index, command) in commands.enumerated() {
            let target = try endpoint(for: command, route: .auto)
            if groups[target] == nil { order.append(target) }
            groups[target, default: []].append(index)
        }
        var results = [RESPValue](repeating: .null, count: commands.count)
        try await withThrowingTaskGroup(of: [(Int, RESPValue)].self) { group in
            for target in order {
                let indices = groups[target] ?? []
                group.addTask {
                    let node = try await self.registry.node(target)
                    let replies = try await node.pipeline(indices.map { commands[$0] })
                    var resolved: [(Int, RESPValue)] = []
                    for (offset, reply) in replies.enumerated() {
                        let index = indices[offset]
                        if let message = reply.errorMessage, Redirect(message: message, fallbackHost: target.host) != nil {
                            resolved.append((index, try await self.executeInCluster(commands[index], route: .auto)))
                        } else {
                            resolved.append((index, reply))
                        }
                    }
                    return resolved
                }
            }
            for try await chunk in group {
                for (index, reply) in chunk { results[index] = reply }
            }
        }
        return results
    }

    /// Runs a command on several nodes concurrently (INFO per node, DBSIZE…).
    public func fanOut(_ command: RedisCommand, nodes selection: NodeSelection = .masters) async throws -> [NodeReply] {
        try enforceReadOnly([command])
        let endpoints = nodeEndpoints(selection)
        return await withTaskGroup(of: NodeReply.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do {
                        let node = try await self.registry.node(endpoint, readOnlyReplica: selection != .masters && self.isReplicaEndpoint(endpoint))
                        let reply = try await node.pipeline([command])[0]
                        if let message = reply.errorMessage { return NodeReply(endpoint: endpoint, result: .failure(.server(message))) }
                        return NodeReply(endpoint: endpoint, result: .success(reply))
                    } catch {
                        return NodeReply(endpoint: endpoint, result: .failure(RedisConnection.normalize(error)))
                    }
                }
            }
            var replies: [NodeReply] = []
            for await reply in group { replies.append(reply) }
            return replies.sorted { $0.endpoint < $1.endpoint }
        }
    }

    public func nodeEndpoints(_ selection: NodeSelection) -> [Endpoint] {
        let current = state.value
        guard current.deployment.isCluster, !current.slotMap.shards.isEmpty else { return [current.primary] }
        switch selection {
        case .masters: return current.slotMap.masters.map(\.endpoint)
        case .replicas: return current.slotMap.shards.flatMap(\.replicas).map(\.endpoint)
        case .all: return current.slotMap.allNodes.map(\.endpoint)
        }
    }

    private func isReplicaEndpoint(_ endpoint: Endpoint) -> Bool {
        state.value.slotMap.shards.contains { $0.replicas.contains { $0.endpoint == endpoint } }
    }

    /// A connection outside the pools (console tab, Pub/Sub, MONITOR). The caller must close it.
    public func dedicatedConnection(route: Route = .auto, command: RedisCommand? = nil) async throws -> (RedisConnection, HandshakeOutcome) {
        let target: Endpoint
        if deployment.isCluster {
            target = try endpoint(for: command ?? RedisCommand("PING"), route: route)
        } else if case let .node(endpoint) = route {
            target = endpoint
        } else {
            target = primaryEndpoint
        }
        let node = try await registry.node(target, readOnlyReplica: isReplicaEndpoint(target))
        return try await node.dedicatedConnection()
    }

    /// Node client for direct per-node work (scans, analysis).
    public func node(_ endpoint: Endpoint) async throws -> NodeClient {
        try await registry.node(endpoint, readOnlyReplica: isReplicaEndpoint(endpoint))
    }

    public func close() async {
        await registry.closeAll()
        await tunnels?.closeAll()
        eventSink.finish()
    }

    /// Marks a feature unavailable after a runtime `unknown command` (e.g. UNLINK through a proxy).
    public func markUnavailable(_ feature: Capabilities.Feature, reason: String) {
        let changed = state.withLock { state -> Bool in
            guard state.capabilities.supports(feature) else { return false }
            state.capabilities.markUnavailable(feature, reason: reason)
            return true
        }
        if changed { eventSink.yield(.capabilityChanged(feature)) }
    }

    // MARK: Read-only enforcement (design D14)

    func enforceReadOnly(_ commands: [RedisCommand]) throws {
        guard isReadOnly else { return }
        for command in commands {
            guard let spec = spec(for: command) else {
                throw RedisError(.readOnly, "\(command.name) is not a known read command; read-only mode only sends commands it knows are safe.")
            }
            if spec.isWrite || (spec.flags.contains(.dangerous) && !spec.flags.contains(.readonly)) {
                let reason = deployment == .replica ? "this connection is to a replica" : "this connection is read-only"
                throw RedisError(.readOnly, "\(spec.name) was not sent: \(reason).")
            }
        }
    }

    // MARK: Standalone / Sentinel

    private func executeOnPrimary(_ commands: [RedisCommand], route: Route) async throws -> [RESPValue] {
        var target = primaryEndpoint
        if case let .node(endpoint) = route { target = endpoint }
        let isSentinel: Bool = if case .sentinel = deployment { true } else { false }
        for attempt in 0..<2 {
            let node = try await registry.node(target)
            do {
                let replies = try await node.pipeline(commands)
                if isSentinel, attempt == 0, !isReadOnly,
                   replies.contains(where: { $0.errorMessage?.uppercased().hasPrefix("READONLY") == true }) {
                    target = try await followFailover()
                    continue
                }
                return replies
            } catch let error as RedisError where isSentinel && attempt == 0 && error.isConnectStage {
                target = try await followFailover()
            }
        }
        throw RedisError(.topology, "The master of the Sentinel group is not reachable")
    }

    /// Re-resolves the Sentinel master; returns the endpoint to use.
    @discardableResult
    public func followFailover() async throws -> Endpoint {
        guard case let .sentinel(sentinels, masterName, role) = configuration.mode else { return primaryEndpoint }
        let resolver = sentinelResolver(sentinels: sentinels, masterName: masterName)
        let previous = primaryEndpoint
        let next = try await resolveSentinelTarget(resolver, role: role)
        if next != previous {
            state.withLock { $0.primary = next }
            await registry.remove(previous)
            eventSink.yield(.failover(from: previous, to: next))
        }
        return next
    }

    // MARK: Cluster (design D7)

    func endpoint(for command: RedisCommand, route: Route) throws -> Endpoint {
        let current = state.value
        guard current.deployment.isCluster else {
            if case let .node(endpoint) = route { return endpoint }
            return current.primary
        }
        let slot: Int?
        switch route {
        case let .node(endpoint): return endpoint
        case let .key(key): slot = HashSlot.slot(for: key)
        case let .slot(value): slot = value
        case .auto:
            let indices = spec(for: command)?.keyIndices(in: command.arguments) ?? []
            slot = indices.first.map { HashSlot.slot(bytes: command.arguments[$0]) }
        }
        guard let slot else { return current.slotMap.masters.first?.endpoint ?? current.primary }
        guard let owner = current.slotMap.master(forSlot: slot) else {
            throw RedisError(.topology, "Slot \(slot) is not served by any node (the cluster is not fully covered)")
        }
        return owner.endpoint
    }

    private func executeInCluster(_ command: RedisCommand, route: Route) async throws -> RESPValue {
        let spec = spec(for: command)
        if case .auto = route, let spec {
            if spec.flags.contains(.allMasters) { return try await executeOnAllMasters(command, spec: spec) }
            if let split = try await executeSplitAcrossSlots(command, spec: spec) { return split }
        }
        var target = try endpoint(for: command, route: route)
        var asking = false
        var refreshedAfterFailure = false
        for attempt in 0..<Self.maxRedirects {
            let reply: RESPValue
            do {
                let node = try await registry.node(target)
                if asking {
                    reply = try await node.pipeline([RedisCommand("ASKING"), command])[1]
                } else {
                    reply = try await node.pipeline([command])[0]
                }
            } catch let error as RedisError where error.isConnectStage && !refreshedAfterFailure {
                refreshedAfterFailure = true
                try? await refreshTopology(force: true)
                target = try endpoint(for: command, route: route)
                continue
            }
            guard let message = reply.errorMessage else { return reply }
            if let redirect = Redirect(message: message, fallbackHost: target.host) {
                switch redirect {
                case let .moved(slot, endpoint):
                    state.withLock { $0.slotMap = $0.slotMap.reassigning(slot: slot, to: endpoint) }
                    scheduleTopologyRefresh()
                    target = endpoint
                    asking = false
                case let .ask(_, endpoint):
                    target = endpoint
                    asking = true
                }
                continue
            }
            if message.hasPrefix("TRYAGAIN") {
                try await Task.sleep(for: .milliseconds(40 * (attempt + 1)))
                continue
            }
            return reply
        }
        throw RedisError(.topology, "Too many cluster redirects for \(command.name); the cluster may be resharding")
    }

    private func executeOnAllMasters(_ command: RedisCommand, spec: CommandSpec) async throws -> RESPValue {
        if spec.name == "SCAN" {
            throw RedisError(.unsupported, "SCAN runs per node in a cluster. Use the key browser, or pick a node in the console.")
        }
        let replies = try await fanOut(command, nodes: .masters)
        var values: [RESPValue] = []
        for reply in replies {
            switch reply.result {
            case let .success(value): values.append(value)
            case let .failure(error):
                if error.kind == .server { return .error("\(error.message) (from \(reply.endpoint))") }
                throw error
            }
        }
        switch spec.name {
        case "DBSIZE":
            return .integer(values.reduce(0) { $0 &+ ($1.int ?? 0) })
        case "KEYS":
            return .array(values.flatMap { $0.array ?? [] })
        default:
            return values.first ?? .simpleString("OK")
        }
    }

    /// Splits DEL/UNLINK/EXISTS/TOUCH/MGET/MSET whose keys span several slots; `nil` when not needed.
    private func executeSplitAcrossSlots(_ command: RedisCommand, spec: CommandSpec) async throws -> RESPValue? {
        let splittable: Set<String> = ["DEL", "UNLINK", "EXISTS", "TOUCH", "MGET", "MSET"]
        guard splittable.contains(spec.name) else { return nil }
        let keyIndices = spec.keyIndices(in: command.arguments)
        let slots = keyIndices.map { HashSlot.slot(bytes: command.arguments[$0]) }
        guard Set(slots).count > 1 else { return nil }

        var groups: [Int: [Int]] = [:] // slot -> positions in keyIndices
        var order: [Int] = []
        for (position, slot) in slots.enumerated() {
            if groups[slot] == nil { order.append(slot) }
            groups[slot, default: []].append(position)
        }
        let name = command.arguments[0]
        var parts: [(slot: Int, positions: [Int], command: RedisCommand)] = []
        for slot in order {
            let positions = groups[slot] ?? []
            var arguments = [name]
            for position in positions {
                let keyIndex = keyIndices[position]
                arguments.append(command.arguments[keyIndex])
                if spec.name == "MSET", keyIndex + 1 < command.arguments.count { arguments.append(command.arguments[keyIndex + 1]) }
            }
            parts.append((slot, positions, RedisCommand(rawArguments: arguments)))
        }
        let replies = try await withThrowingTaskGroup(of: (Int, RESPValue).self) { group in
            for (index, part) in parts.enumerated() {
                group.addTask { (index, try await self.executeInCluster(part.command, route: .slot(part.slot))) }
            }
            var collected = [RESPValue](repeating: .null, count: parts.count)
            for try await (index, reply) in group { collected[index] = reply }
            return collected
        }
        if let failure = replies.first(where: \.isError) { return failure }
        switch spec.name {
        case "MGET":
            var values = [RESPValue](repeating: .null, count: keyIndices.count)
            for (part, reply) in zip(parts, replies) {
                for (offset, position) in part.positions.enumerated() {
                    if let array = reply.array, array.indices.contains(offset) { values[position] = array[offset] }
                }
            }
            return .array(values)
        case "MSET":
            return .simpleString("OK")
        default:
            return .integer(replies.reduce(0) { $0 &+ ($1.int ?? 0) })
        }
    }

    private func scheduleTopologyRefresh() {
        Task { [weak self] in try? await self?.refreshTopology() }
    }

    /// Reloads the slot map (rate-limited unless forced).
    public func refreshTopology(force: Bool = false) async throws {
        let now = ContinuousClock.now
        let allowed = lastRefresh.withLock { last -> Bool in
            if !force, let last, now - last < .seconds(2) { return false }
            last = now
            return true
        }
        guard allowed || state.value.slotMap.shards.isEmpty else { return }

        var candidates = state.value.slotMap.masters.map(\.endpoint)
        if case let .cluster(seeds) = configuration.mode { candidates += seeds }
        candidates.append(primaryEndpoint)
        var seen = Set<Endpoint>()
        candidates = candidates.filter { seen.insert($0).inserted }

        var lastError: (any Error)?
        for candidate in candidates {
            do {
                let node = try await registry.node(candidate)
                var map: ClusterSlotMap?
                if capabilities.supports(.clusterShards) {
                    let reply = try await node.pipeline([RedisCommand("CLUSTER", ["SHARDS"])])[0]
                    if !reply.isError { map = try ClusterSlotMap(clusterShards: reply, queriedNode: candidate, preferTLSPort: usesTLS) }
                }
                if map == nil || map?.shards.isEmpty == true {
                    let reply = try await node.pipeline([RedisCommand("CLUSTER", ["SLOTS"])])[0]
                    if !reply.isError { map = try ClusterSlotMap(clusterSlots: reply, queriedNode: candidate) }
                }
                if map == nil || map?.shards.isEmpty == true {
                    let reply = try await node.send(RedisCommand("CLUSTER", ["NODES"]))
                    map = try ClusterSlotMap(clusterNodes: ClusterNodeInfo.parse(clusterNodes: reply.string ?? "", queriedNode: candidate))
                }
                guard let map, !map.shards.isEmpty else { throw RedisError(.topology, "\(candidate) reported no slot owners") }
                state.withLock { $0.slotMap = map }
                eventSink.yield(.topologyRefreshed(masters: map.shards.count, replicas: map.shards.reduce(0) { $0 + $1.replicas.count }))
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RedisError(.topology, "No cluster node answered")
    }
}
