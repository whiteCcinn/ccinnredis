import Foundation
import RedisKit
import RESPWire

/// Where the MCP server finds saved profiles and their secrets.
public protocol MCPProfileSource: Sendable {
    func profiles() -> [ConnectionProfile]
    func secrets(for profile: ConnectionProfile) -> ProfileSecrets
}

/// One `RedisClient` per profile, reused while the profile and its secrets stay the same. Editing a
/// connection in the app (address, password, read-only flag, MCP access) replaces the cached client.
actor MCPClientPool {
    typealias Factory = @Sendable (ClientConfiguration) async throws -> RedisClient

    struct Identity: Equatable, Sendable {
        let profile: ConnectionProfile
        let secrets: ProfileSecrets
        let access: MCPAccess
    }

    private var clients: [UUID: (identity: Identity, client: RedisClient)] = [:]
    private var connecting: [UUID: (identity: Identity, task: Task<RedisClient, any Error>)] = [:]
    private let factory: Factory

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func client(for identity: Identity, configuration: ClientConfiguration) async throws -> RedisClient {
        let id = identity.profile.id
        if let existing = clients[id] {
            if existing.identity == identity { return existing.client }
            clients[id] = nil
            await existing.client.close()
        }
        if let pending = connecting[id], pending.identity == identity { return try await pending.task.value }
        let factory = factory
        let task = Task { try await factory(configuration) }
        connecting[id] = (identity, task)
        defer { if connecting[id]?.task == task { connecting[id] = nil } }
        let client = try await task.value
        if let replaced = clients[id], replaced.identity != identity { await replaced.client.close() }
        clients[id] = (identity, client)
        return client
    }

    var cachedCount: Int { clients.count }

    func closeAll() async {
        let all = clients.values.map(\.client)
        clients.removeAll()
        for client in all { await client.close() }
    }
}

/// The CcinnRedis MCP tools (design §6): connections, server info, bounded key scans and reads,
/// slowlog, cluster info and an allow-listed read-only `run_command`; write tools only for profiles
/// whose MCP access is read & write.
public final class RedisMCPToolbox: MCPToolbox {
    private let source: any MCPProfileSource
    private let defaultProfile: String?
    private let forceReadOnly: Bool
    private let pool: MCPClientPool
    private let audit: MCPAuditLog?

    static let writeTools: Set<String> = ["set_string", "delete_keys", "expire_key"]
    /// Redis collections hold at most 2^32 - 1 elements.
    static let maxOffset: Int64 = 4_294_967_295
    /// Ten years; larger EXPIRE values overflow inside some servers.
    static let maxTTLSeconds: Int64 = 315_360_000

    public init(profiles: any MCPProfileSource, defaultProfile: String? = nil, forceReadOnly: Bool = false,
                clientFactory: @escaping @Sendable (ClientConfiguration) async throws -> RedisClient = { try await RedisClient.connect($0) },
                audit: MCPAuditLog? = nil) {
        source = profiles
        self.defaultProfile = defaultProfile
        self.forceReadOnly = forceReadOnly
        pool = MCPClientPool(factory: clientFactory)
        self.audit = audit
    }

    var cachedClientCount: Int {
        get async { await pool.cachedCount }
    }

    public func shutdown() async {
        await pool.closeAll()
        await audit?.close()
    }

    // MARK: Profiles

    private var enabledProfiles: [ConnectionProfile] { source.profiles().filter { $0.mcpAccess != .disabled } }

    /// Effective access: a read-only profile, or `--read-only`, never gets write tools.
    func access(of profile: ConnectionProfile) -> MCPAccess {
        forceReadOnly || profile.readOnly ? min(profile.mcpAccess, .readOnly) : profile.mcpAccess
    }

    private func match(_ profile: ConnectionProfile, _ reference: String) -> Bool {
        profile.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame
            || profile.displayName.caseInsensitiveCompare(reference) == .orderedSame
            || profile.name.caseInsensitiveCompare(reference) == .orderedSame
    }

    enum Resolution {
        case profile(ConnectionProfile)
        case failure(String)
    }

    func resolve(_ requested: String?) -> Resolution {
        let enabled = enabledProfiles
        let names = enabled.map(\.displayName).sorted()
        if let reference = requested?.trimmingCharacters(in: .whitespaces), !reference.isEmpty {
            if let profile = enabled.first(where: { match($0, reference) }) { return .profile(profile) }
            if source.profiles().contains(where: { match($0, reference) }) {
                return .failure("Connection '\(reference)' is not enabled for MCP. Enable “AI access via MCP” for it in CcinnRedis. Enabled: \(names.joined(separator: ", "))")
            }
            return .failure("No connection named '\(reference)'. Enabled connections: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        if let defaultProfile {
            if let profile = enabled.first(where: { match($0, defaultProfile) }) { return .profile(profile) }
            return .failure("The default connection '\(defaultProfile)' (from --profile) is not enabled for MCP.")
        }
        if enabled.count == 1, let only = enabled.first { return .profile(only) }
        if enabled.isEmpty {
            return .failure("No connection is enabled for MCP. In CcinnRedis, open a connection's settings and set “AI access via MCP” to Read-only or Read & write.")
        }
        return .failure("Several connections are enabled; pass the `connection` argument. Enabled: \(names.joined(separator: ", "))")
    }

    // MARK: Tool definitions

    private static let connectionArgument = MCPSchema.string("Saved connection name or id (see list_connections). Optional when only one is enabled.")
    private static let timeoutArgument = MCPSchema.integer("Timeout in seconds (default 30, max 120)", minimum: 1, maximum: 120)

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var all = properties
        all["connection"] = connectionArgument
        all["timeout_seconds"] = timeoutArgument
        return MCPSchema.object(properties: all, required: required)
    }

    static let readTools: [MCPToolDefinition] = [
        MCPToolDefinition(name: "list_connections", title: "List connections",
                          description: "Saved Redis connections that are enabled for AI access, with their mode and access level. Never returns secrets.",
                          inputSchema: MCPSchema.object(properties: [:]), readOnly: true),
        MCPToolDefinition(name: "server_info", title: "Server info",
                          description: "Server family/version, deployment (standalone, replica, sentinel, cluster, proxy), protocol, unavailable features and INFO sections.",
                          inputSchema: schema(["section": MCPSchema.string("INFO section(s), e.g. 'memory' or 'server,clients' (default: the default sections)"),
                                               "node": MCPSchema.string("Cluster only: node host:port")]), readOnly: true),
        MCPToolDefinition(name: "scan_keys", title: "Scan keys",
                          description: "Incrementally scans keys with SCAN (never KEYS), on every master in a cluster. Returns keys with type and TTL and a cursor to continue.",
                          inputSchema: schema(["pattern": MCPSchema.string("Glob pattern, e.g. 'user:*'"),
                                               "type": MCPSchema.string("Only keys of this type: string, hash, list, set, zset, stream, ReJSON-RL"),
                                               "limit": MCPSchema.integer("Approximate number of keys (default 200, max 1000)", minimum: 1, maximum: 1000),
                                               "cursor": MCPSchema.string("Cursor from a previous call to continue")]), readOnly: true),
        MCPToolDefinition(name: "get_key", title: "Get key value",
                          description: "Reads a key's value, type-aware and bounded: string (first 64 KB), hash/set (cursor pages), list and sorted set (offset/limit), stream (entries from an id), RedisJSON.",
                          inputSchema: schema(["key": MCPSchema.string("Key name"),
                                               "offset": MCPSchema.integer("List/sorted set: start index (default 0)", minimum: 0, maximum: RedisMCPToolbox.maxOffset),
                                               "limit": MCPSchema.integer("Elements to return (default 200, max 1000)", minimum: 1, maximum: 1000),
                                               "cursor": MCPSchema.string("Hash/set: cursor from a previous call; stream: start entry id")],
                                              required: ["key"]), readOnly: true),
        MCPToolDefinition(name: "key_info", title: "Key info",
                          description: "Type, TTL, encoding, element count, memory usage and idle time of a key.",
                          inputSchema: schema(["key": MCPSchema.string("Key name")], required: ["key"]), readOnly: true),
        MCPToolDefinition(name: "slowlog", title: "Slow log",
                          description: "Recent slow commands (SLOWLOG GET), merged across masters in a cluster.",
                          inputSchema: schema(["limit": MCPSchema.integer("Entries per node (default 50, max 1000)", minimum: 1, maximum: 1000)]), readOnly: true),
        MCPToolDefinition(name: "cluster_info", title: "Cluster info",
                          description: "Cluster state, slot coverage and every node with role, master and slot ranges (Redis Cluster only).",
                          inputSchema: schema([:]), readOnly: true),
        MCPToolDefinition(name: "run_command", title: "Run read-only command",
                          description: "Runs ONE read-only Redis command in redis-cli syntax (e.g. 'HGET user:1 name', 'INFO memory', 'ZRANGE z 0 9 WITHSCORES'). Writes, KEYS, FLUSH*, CONFIG SET, DEBUG, SHUTDOWN, MONITOR, SUBSCRIBE, scripts, blocking and stateful commands are refused. Routed by key in a cluster.",
                          inputSchema: schema(["command": MCPSchema.string("A single command line in redis-cli syntax")], required: ["command"]),
                          readOnly: true),
    ]

    static let writeToolDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(name: "set_string", title: "Set string",
                          description: "SET a string value (optionally with a TTL). Only for connections with read & write MCP access.",
                          inputSchema: schema(["key": MCPSchema.string("Key name"), "value": MCPSchema.string("Value (UTF-8 text)"),
                                               "ttl_seconds": MCPSchema.integer("Optional expiration in seconds", minimum: 1, maximum: RedisMCPToolbox.maxTTLSeconds)], required: ["key", "value"]),
                          readOnly: false, destructive: true, idempotent: true),
        MCPToolDefinition(name: "delete_keys", title: "Delete keys",
                          description: "Deletes up to 100 explicitly named keys (UNLINK when available). Only for read & write connections.",
                          inputSchema: schema(["keys": MCPSchema.stringArray("Key names (max 100)", maxItems: 100)], required: ["keys"]),
                          readOnly: false, destructive: true, idempotent: true),
        MCPToolDefinition(name: "expire_key", title: "Set or remove TTL",
                          description: "Sets a key's TTL in seconds, or removes it when ttl_seconds is null. Only for read & write connections.",
                          inputSchema: schema(["key": MCPSchema.string("Key name"),
                                               "ttl_seconds": MCPSchema.integer("Seconds, or null to persist", minimum: 1, maximum: RedisMCPToolbox.maxTTLSeconds, nullable: true)], required: ["key", "ttl_seconds"]),
                          readOnly: false, destructive: true, idempotent: true),
    ]

    public func tools() async -> [MCPToolDefinition] {
        let writable = enabledProfiles.contains { access(of: $0) == .readWrite }
        return Self.readTools + (writable ? Self.writeToolDefinitions : [])
    }

    // MARK: Calls

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let clock = ContinuousClock()
        let start = clock.now
        let definition = (Self.readTools + Self.writeToolDefinitions).first { $0.name == name }
        var connectionName: String?
        var result: MCPToolResult
        do {
            guard let definition else { throw MCPToolError("Unknown tool \(name)") }
            if let problem = MCPSchema.validate(arguments, against: definition.inputSchema) { throw MCPToolError(problem) }
            if name == "list_connections" {
                result = MCPToolResult(payload: listConnections())
            } else {
                let profile: ConnectionProfile
                switch resolve(arguments["connection"]?.string) {
                case let .profile(found): profile = found
                case let .failure(message): throw MCPToolError(message)
                }
                connectionName = profile.displayName
                let access = access(of: profile)
                if Self.writeTools.contains(name), access != .readWrite {
                    let why = forceReadOnly ? " (the server runs with --read-only)" : profile.readOnly ? " (the connection is marked read-only)" : ""
                    throw MCPToolError("Connection '\(profile.displayName)' is read-only for MCP\(why). Write tools are refused.")
                }
                let secrets = source.secrets(for: profile)
                var configuration = try profile.clientConfiguration(secrets: secrets)
                configuration.readOnly = configuration.readOnly || access != .readWrite
                configuration.commandTimeout = Double(MCPLimits.maximumTimeout)
                configuration.limits = RESPLimits(maxBulkLength: 64 * 1024 * 1024, maxAggregateCount: 2_000_000, maxDepth: 32, maxLineLength: 4 * 1024 * 1024)
                configuration.clientName = "ccinnredis-mcp"
                let client = try await pool.client(for: MCPClientPool.Identity(profile: profile, secrets: secrets, access: access),
                                                   configuration: configuration)
                let seconds = MCPLimits.timeout(arguments["timeout_seconds"])
                let payload = try await Self.withTimeout(seconds: seconds) { [self] in
                    try await perform(name, client: client, arguments: arguments)
                }
                result = MCPToolResult(payload: MCPResultFitter.fit(payload))
            }
        } catch is CancellationError {
            result = .error("Cancelled")
        } catch let error as MCPToolError {
            result = .error(error.message)
        } catch let error as RedisError {
            result = .error(error.kind == .cancelled ? "Cancelled" : error.message)
        } catch {
            result = .error(error.localizedDescription)
        }
        await audit?.record(connection: connectionName, tool: name,
                            command: name == "run_command" ? arguments["command"]?.string : nil,
                            key: arguments["key"]?.string ?? arguments["pattern"]?.string,
                            duration: clock.now - start,
                            items: result.payload["keys"]?.array?.count ?? result.payload["items"]?.array?.count,
                            error: result.isError ? result.payload["error"]?.string : nil)
        return result
    }

    private func listConnections() -> JSONValue {
        .object(["connections": .array(enabledProfiles.map { profile in
            .object([
                "name": .string(profile.displayName), "id": .string(profile.id.uuidString), "endpoint": .string(profile.hostSummary),
                "mode": .string(profile.mode.rawValue), "access": .string(access(of: profile).rawValue),
                "readOnlyProfile": .bool(profile.readOnly),
            ])
        })])
    }

    private func perform(_ name: String, client: RedisClient, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "server_info": return try await serverInfo(client, arguments)
        case "scan_keys": return try await scanKeys(client, arguments)
        case "get_key": return try await getKey(client, arguments)
        case "key_info": return try await keyInfo(client, arguments)
        case "slowlog": return try await slowlog(client, arguments)
        case "cluster_info": return try await clusterInfo(client)
        case "run_command": return try await runCommand(client, arguments)
        case "set_string":
            let key = RedisKey(arguments["key"]?.string ?? "")
            try await client.setString(key, Array((arguments["value"]?.string ?? "").utf8), keepTTL: false)
            if let ttl = arguments["ttl_seconds"]?.int { try await client.setTTL(key, seconds: ttl) }
            return .object(["ok": .bool(true), "key": .string(key.display)])
        case "delete_keys":
            let keys = (arguments["keys"]?.array ?? []).compactMap(\.string).map(RedisKey.init)
            let deleted = try await client.delete(keys)
            return .object(["deleted": .int(deleted), "requested": .int(Int64(keys.count))])
        case "expire_key":
            let key = RedisKey(arguments["key"]?.string ?? "")
            try await client.setTTL(key, seconds: arguments["ttl_seconds"]?.int)
            return .object(["ok": .bool(true), "key": .string(key.display), "ttl_seconds": arguments["ttl_seconds"] ?? .null])
        default:
            throw MCPToolError("Unknown tool \(name)")
        }
    }

    // MARK: Tools

    private func serverInfo(_ client: RedisClient, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let info = client.serverInfo
        var payload: [String: JSONValue] = [
            "server": .object([
                "family": .string(info.family.rawValue), "version": .string(info.versionString), "mode": info.mode.map(JSONValue.string) ?? .null,
                "role": .string(info.role.rawValue),
            ]),
            "deployment": .string(client.deployment.displayName),
            "protocol": .string("RESP\(client.protocolVersion)"),
            "endpoint": .string(client.primaryEndpoint.description),
            "readOnly": .bool(client.isReadOnly),
            "unavailableFeatures": .array(client.capabilities.unavailable.map { .object(["feature": .string($0.feature.title), "reason": .string($0.reason)]) }),
            "modules": .array(client.modules.map { .string($0.displayName) }),
        ]
        if client.capabilities.supports(.info) {
            let section = arguments["section"]?.string?.trimmingCharacters(in: .whitespaces)
            if let section, !section.isEmpty, !section.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "," || $0 == "_" }) {
                throw MCPToolError("Invalid INFO section '\(section)'")
            }
            let node = try arguments["node"]?.string.map { text -> Endpoint in
                guard let endpoint = Endpoint.parse(text) else { throw MCPToolError("Invalid node '\(text)'; use host:port") }
                return endpoint
            }
            let snapshot = try await client.info(section: section?.isEmpty == false ? section : nil, node: node)
            var sections: [String: JSONValue] = [:]
            for entry in snapshot.sections {
                var fields: [String: JSONValue] = [:]
                for pair in entry.entries.prefix(400) { fields[pair.key] = .string(pair.value) }
                sections[entry.name.isEmpty ? "info" : entry.name] = .object(fields)
            }
            payload["info"] = .object(sections)
        }
        return .object(payload)
    }

    private func scanKeys(_ client: RedisClient, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard client.capabilities.supports(.scan) else {
            throw MCPToolError(client.capabilities[.scan].reason ?? "SCAN is not available on this server")
        }
        let limit = MCPLimits.itemLimit(arguments["limit"])
        let pattern = arguments["pattern"]?.string.flatMap { $0.isEmpty || $0 == "*" ? nil : $0 }
        let type = arguments["type"]?.string.map(KeyType.init(rawValue:))
        let serverSideType = client.capabilities.supports(.scanType)
        let nodes = client.scanEndpoints.map(\.endpoint)
        var nodeIndex = 0
        var cursor = "0"
        if let raw = arguments["cursor"]?.string, !raw.isEmpty {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let index = Int(parts[0]), index >= 0, index < max(nodes.count, 1), UInt64(parts[1]) != nil else {
                throw MCPToolError("Invalid cursor '\(raw)'")
            }
            nodeIndex = index
            cursor = parts[1]
        }
        var keys: [RedisKey] = []
        var rounds = 0
        // COUNT is the number of slots examined, not returned: with a sparse filter it grows while pages
        // come back empty (bounded), so a selective pattern still finds keys within the time limit.
        let filtered = pattern != nil || type != nil
        var count = filtered ? max(limit, 100) : min(1000, max(10, limit))
        while keys.count < limit, nodeIndex < nodes.count, rounds < 500 {
            try Task.checkCancellation()
            rounds += 1
            var command: [RedisArgument] = [.string(cursor)]
            if let pattern { command += ["MATCH", .string(pattern)] }
            command += ["COUNT", .int(filtered ? count : min(1000, max(10, limit - keys.count)))]
            if let type, serverSideType { command += ["TYPE", .string(type.scanArgument)] }
            let node = try await client.node(nodes[nodeIndex])
            let reply = try await node.send(RedisCommand("SCAN", command))
            guard let parts = reply.array, parts.count == 2, let next = parts[0].string else {
                throw MCPToolError("Unexpected SCAN reply")
            }
            var batch = (parts[1].array ?? []).compactMap { $0.bytes.map(RedisKey.init(bytes:)) }
            if let type, !serverSideType, !batch.isEmpty {
                let types = try await node.pipeline(batch.map { RedisCommand("TYPE", [.key($0)]) })
                batch = zip(batch, types).filter { $1.string == type.rawValue }.map(\.0)
            }
            keys += batch
            count = batch.isEmpty ? min(count * 2, 5000) : max(limit, 100)
            if next == "0" {
                nodeIndex += 1
                cursor = "0"
            } else {
                cursor = next
            }
        }
        let complete = nodeIndex >= nodes.count
        let shown = Array(keys.prefix(MCPLimits.maximumItems))
        let metadata = try await client.metadata(for: shown)
        var payload: [String: JSONValue] = [
            "keys": .array(metadata.map { entry in
                .object(["key": .string(entry.key.display), "type": .string(entry.type.rawValue),
                         "ttl_ms": entry.ttlMilliseconds.map(JSONValue.int) ?? .null])
            }),
            "cursor": complete ? .null : .string("\(nodeIndex):\(cursor)"),
            "complete": .bool(complete),
            "nodes": .int(Int64(nodes.count)),
        ]
        if shown.count < keys.count { payload["truncated"] = .bool(true) }
        return .object(payload)
    }

    private func getKey(_ client: RedisClient, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let key = RedisKey(arguments["key"]?.string ?? "")
        let limit = MCPLimits.itemLimit(arguments["limit"])
        let offset = Int(min(max(0, arguments["offset"]?.int ?? 0), Self.maxOffset))
        let cursorArgument = arguments["cursor"]?.string
        let metadata = try await client.metadata(for: [key])
        guard let type = metadata.first?.type, type.exists else { throw MCPToolError("Key '\(key.display)' does not exist") }
        var truncated = false
        var payload: [String: JSONValue] = ["key": .string(key.display), "type": .string(type.rawValue),
                                            "ttl_ms": metadata.first?.ttlMilliseconds.map(JSONValue.int) ?? .null]
        let limits = MCPLimits(maxItems: limit, maxStringBytes: 16 * 1024)
        switch type {
        case .string:
            let value = try await client.stringValue(key, maxBytes: 64 * 1024)
            payload["value"] = MCPValueEncoder.text(value.bytes, limit: 64 * 1024, truncated: &truncated)
            payload["length"] = .int(value.totalLength)
            truncated = truncated || value.isTruncated
        case .hash:
            let page = try await client.hashScan(key, cursor: cursorArgument ?? "0", count: limit)
            var fields: [String: JSONValue] = [:]
            for entry in page.elements.prefix(limit) {
                fields[String(decoding: entry.field, as: UTF8.self)] = MCPValueEncoder.text(entry.value, limit: limits.maxStringBytes, truncated: &truncated)
            }
            payload["fields"] = .object(fields)
            payload["cursor"] = page.isComplete ? .null : .string(page.cursor)
        case .set:
            let page = try await client.setScan(key, cursor: cursorArgument ?? "0", count: limit)
            payload["members"] = .array(page.elements.prefix(limit).map { MCPValueEncoder.text($0, limit: limits.maxStringBytes, truncated: &truncated) })
            payload["cursor"] = page.isComplete ? .null : .string(page.cursor)
        case .list:
            let items = try await client.listRange(key, start: offset, stop: offset + limit - 1)
            payload["items"] = .array(items.map { MCPValueEncoder.text($0, limit: limits.maxStringBytes, truncated: &truncated) })
            payload["offset"] = .int(Int64(offset))
        case .zset:
            let members = try await client.zsetRange(key, start: offset, stop: offset + limit - 1)
            payload["members"] = .array(members.map { .object(["member": MCPValueEncoder.text($0.member, limit: limits.maxStringBytes, truncated: &truncated),
                                                                "score": .double($0.score)]) })
            payload["offset"] = .int(Int64(offset))
        case .stream:
            let entries = try await client.streamRange(key, start: cursorArgument ?? "-", count: limit)
            payload["entries"] = .array(entries.map { entry in
                var fields: [String: JSONValue] = [:]
                for pair in entry.fields { fields[String(decoding: pair.field, as: UTF8.self)] = MCPValueEncoder.text(pair.value, limit: limits.maxStringBytes, truncated: &truncated) }
                return .object(["id": .string(entry.id), "fields": .object(fields)])
            })
            if let last = entries.last, entries.count == limit { payload["cursor"] = .string("(" + last.id) }
        default:
            if type.isJSON, client.hasJSONModule {
                let document = try await client.jsonGet(key)
                payload["json"] = MCPValueEncoder.text(Array(document.utf8), limit: 128 * 1024, truncated: &truncated)
            } else {
                payload["note"] = .string("Values of module type \(type.rawValue) are not decoded; use run_command with the module's read commands.")
            }
        }
        if let length = RedisClient.lengthCommand(for: type, key: key).map({ $0 }), type != .string {
            payload["length"] = (try? await client.executeAllowingErrors(length).int).map(JSONValue.int) ?? .null
        }
        if truncated { payload["truncated"] = .bool(true) }
        return .object(payload)
    }

    private func keyInfo(_ client: RedisClient, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let details = try await client.details(for: RedisKey(arguments["key"]?.string ?? ""))
        guard details.type.exists else { throw MCPToolError("Key '\(details.key.display)' does not exist") }
        return .object([
            "key": .string(details.key.display), "type": .string(details.type.rawValue),
            "ttl_ms": details.ttlMilliseconds.map(JSONValue.int) ?? .null, "encoding": details.encoding.map(JSONValue.string) ?? .null,
            "length": details.length.map(JSONValue.int) ?? .null, "memory_bytes": details.memoryBytes.map(JSONValue.int) ?? .null,
            "idle_seconds": details.idleSeconds.map(JSONValue.int) ?? .null,
        ])
    }

    private func slowlog(_ client: RedisClient, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard client.capabilities.supports(.slowlog) else { throw MCPToolError(client.capabilities[.slowlog].reason ?? "SLOWLOG is not available") }
        let limit = arguments["limit"] == nil ? 50 : MCPLimits.itemLimit(arguments["limit"])
        var entries: [SlowlogEntry] = []
        for endpoint in client.masterEndpoints { entries += try await client.slowlog(count: limit, node: endpoint) }
        entries.sort { $0.timestamp > $1.timestamp }
        return .object(["items": .array(entries.prefix(limit).map { entry in
            .object([
                "id": .int(entry.id), "time": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
                "duration_us": .int(entry.durationMicroseconds), "command": .string(ConsoleHistory.redact(String(entry.commandLine.prefix(2000)))),
                "client": entry.clientAddress.map(JSONValue.string) ?? .null, "node": .string(entry.node?.description ?? ""),
            ])
        })])
    }

    private func clusterInfo(_ client: RedisClient) async throws -> JSONValue {
        guard client.deployment.isCluster else {
            throw MCPToolError("This connection is \(client.deployment.displayName), not Redis Cluster.")
        }
        let info = try await client.clusterInfo()
        let nodes = try await client.clusterNodes()
        return .object([
            "state": .string(info["cluster_state"] ?? "unknown"),
            "slots_assigned": .string(info["cluster_slots_assigned"] ?? ""),
            "nodes": .array(nodes.map { node in
                .object([
                    "id": .string(node.id), "endpoint": .string(node.endpoint?.description ?? ""), "role": .string(node.role.rawValue),
                    "master_id": node.masterID.map(JSONValue.string) ?? .null, "flags": .array(node.flags.map(JSONValue.string)),
                    "link": .string(node.linkState),
                    "slots": .array(node.slotRanges.map { .string($0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)") }),
                ])
            }),
        ])
    }

    private func runCommand(_ client: RedisClient, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let line = arguments["command"]?.string ?? ""
        guard !line.contains("\n"), !line.contains("\r") else {
            throw MCPToolError("Send exactly one command per call (no newlines).")
        }
        let tokens: [[UInt8]]
        do { tokens = try CLITokenizer.tokenize(line) } catch { throw MCPToolError(describeTokenizer(error)) }
        guard !tokens.isEmpty else { throw MCPToolError("Empty command") }
        let command = RedisCommand(rawArguments: tokens)
        if case let .denied(reason) = MCPCommandPolicy.check(command, spec: client.spec(for: command)) {
            throw MCPToolError(reason)
        }
        try client.enforceReadOnly([command])
        var reply = try await client.executeAllowingErrors(command)
        reply = MCPCommandPolicy.redact(reply, for: command)
        let converted = MCPValueEncoder.json(reply, limits: MCPLimits(maxItems: MCPLimits.maximumItems, maxStringBytes: 32 * 1024))
        var payload: [String: JSONValue] = [
            "command": .string(ConsoleHistory.redact(line)),
            "reply": converted.value,
            "text": .string(ReplyFormatter.format(reply, limits: ReplyFormatter.Limits(maxElements: 300, maxStringBytes: 4096))),
        ]
        if converted.truncated { payload["truncated"] = .bool(true) }
        if let message = reply.errorMessage { payload["serverError"] = .string(message) }
        return .object(payload)
    }

    private func describeTokenizer(_ error: any Error) -> String {
        (error as? CLITokenizer.TokenizeError)?.message ?? error.localizedDescription
    }

    static func withTimeout<T: Sendable>(seconds: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPToolError("Timed out after \(seconds) s; narrow the request (pattern, limit) or raise timeout_seconds (max 120).")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MCPToolError("No result") }
            return first
        }
    }
}

struct MCPToolError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
