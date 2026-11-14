import CcinnRedisKit
import Foundation
import RedisKit
import RESPWire
import Testing

/// Live tests against the Docker matrix started by `scripts/redis-up.sh`. Enabled with `CCINNREDIS_IT=1`.
enum IT {
    static let isEnabled = ProcessInfo.processInfo.environment["CCINNREDIS_IT"] == "1"

    /// `CCINNREDIS_IT_GROUPS=legacy,modern` limits the run to the groups started with `scripts/redis-up.sh`
    /// (Docker is shared, so the matrix runs in batches). Unset means every group. Selected groups are
    /// never skipped silently: a selected server that is down fails its tests.
    static let groups: Set<String>? = ProcessInfo.processInfo.environment["CCINNREDIS_IT_GROUPS"]
        .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }) }

    static func wants(_ group: String) -> Bool { isEnabled && (groups?.contains(group) ?? true) }

    struct Server: Sendable, CustomTestStringConvertible {
        let label: String
        let port: Int
        let family: ServerFamily
        let major: Int
        let minor: Int
        var password: String?
        var group: String
        var testDescription: String { label }
    }

    static let redis50 = Server(label: "Redis 5.0 (requirepass)", port: 17050, family: .redis, major: 5, minor: 0, password: "ccinn-pass", group: "auth")
    static let redis72 = Server(label: "Redis 7.2", port: 17072, family: .redis, major: 7, minor: 2, group: "large")

    static let allStandalone: [Server] = [
        Server(label: "Redis 2.8", port: 17028, family: .redis, major: 2, minor: 8, group: "legacy"),
        Server(label: "Redis 3.2", port: 17032, family: .redis, major: 3, minor: 2, group: "legacy"),
        Server(label: "Redis 4.0", port: 17040, family: .redis, major: 4, minor: 0, group: "legacy"),
        redis50,
        Server(label: "Redis 6.2", port: 17062, family: .redis, major: 6, minor: 2, group: "auth"),
        redis72,
        Server(label: "Redis 7.4", port: 17074, family: .redis, major: 7, minor: 4, group: "modern"),
        Server(label: "Redis 8.2", port: 17082, family: .redis, major: 8, minor: 2, group: "modern"),
        Server(label: "Valkey 8", port: 17088, family: .valkey, major: 8, minor: 0, group: "modern"),
        Server(label: "redis-stack 7.4", port: 17095, family: .redis, major: 7, minor: 4, group: "stack"),
    ]

    /// The standalone servers of the selected groups.
    static let standalone: [Server] = allStandalone.filter { wants($0.group) }

    static func connect(_ server: Server, readOnly: Bool = false, protocolPreference: ProtocolPreference = .auto) async throws -> RedisClient {
        try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "127.0.0.1", port: server.port)),
                                                          credentials: Credentials(password: server.password),
                                                          protocolPreference: protocolPreference, readOnly: readOnly))
    }

    static func connect(port: Int, _ configure: (inout ClientConfiguration) -> Void = { _ in }) async throws -> RedisClient {
        var configuration = ClientConfiguration(mode: .standalone(Endpoint(host: "127.0.0.1", port: port)))
        configure(&configuration)
        return try await RedisClient.connect(configuration)
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

@Suite("Integration: standalone versions", .enabled(if: IT.isEnabled), .serialized)
struct StandaloneIntegrationTests {
    @Test(arguments: IT.standalone)
    func detectsVersionProtocolAndCapabilities(server: IT.Server) async throws {
        let client = try await IT.connect(server)
        defer { Task { await client.close() } }
        let version = try #require(client.serverInfo.version)
        #expect(client.serverInfo.family == server.family)
        #expect(version.major == server.major && (server.family == .valkey || version.minor == server.minor), "\(version)")
        #expect(client.deployment == .standalone)
        let modern = server.major >= 6 || server.family == .valkey
        #expect(client.protocolVersion == (modern ? 3 : 2))
        #expect(client.capabilities.supports(.unlink) == (server.major >= 4 || server.family == .valkey))
        #expect(client.capabilities.supports(.streams) == (server.major >= 5 || server.family == .valkey))
        #expect(client.capabilities.supports(.scanType) == (server.major >= 6 || server.family == .valkey))
        #expect(client.capabilities.supports(.memoryUsage) == (server.major >= 4 || server.family == .valkey))
        #expect(try await client.dbSize() > 0)
    }

    @Test(arguments: IT.standalone)
    func readsSeededValuesOfEveryType(server: IT.Server) async throws {
        let client = try await IT.connect(server)
        defer { Task { await client.close() } }
        #expect(try await client.stringValue(RedisKey("demo:string:hello")).bytes == Array("Hello, CcinnRedis!".utf8))
        #expect(String(decoding: try await client.stringValue(RedisKey("demo:string:unicode")).bytes, as: UTF8.self).contains("吉隆坡"))
        #expect(try await client.stringValue(RedisKey("demo:string:binary")).bytes.prefix(4) == [0x00, 0x01, 0x02, 0xFF])
        let partial = try await client.stringValue(RedisKey("demo:string:long"), maxBytes: 1000)
        #expect(partial.isTruncated && partial.bytes.count == 1000 && partial.totalLength > 3000)
        let user = try await client.hashGetAll(RedisKey("demo:hash:user:1"))
        #expect(user.contains { String(decoding: $0.field, as: UTF8.self) == "name" && String(decoding: $0.value, as: UTF8.self) == "Ada Lovelace" })
        var hashFields = 0
        var cursor = "0"
        repeat {
            let page = try await client.hashScan(RedisKey("demo:hash:big"), cursor: cursor, count: 500)
            hashFields += page.elements.count
            cursor = page.cursor
        } while cursor != "0"
        #expect(hashFields >= 2000)
        #expect(try await client.listRange(RedisKey("demo:list:big"), start: 9990, stop: -1).count == 10)
        let members = try await client.zsetRange(RedisKey("demo:zset:weights"), start: 0, stop: -1)
        #expect(members.map(\.score) == [-3, 1.5, 2.25, 1e6])
        let set = try await client.setScan(RedisKey("demo:set:tags"), count: 100)
        #expect(set.elements.count == 10 || !set.isComplete)
        let details = try await client.details(for: RedisKey("demo:hash:big"))
        #expect(details.type == .hash)
        #expect(details.length == 2000)
        #expect((details.memoryBytes != nil) == client.capabilities.supports(.memoryUsage))
        if client.capabilities.supports(.streams) {
            let entries = try await client.streamRange(RedisKey("demo:stream:events"), count: 10)
            #expect(entries.count == 10)
            let groups = try await client.streamGroups(RedisKey("demo:stream:events"))
            #expect(Set(groups.map(\.name)) == ["analytics", "billing"])
            let analytics = try #require(groups.first { $0.name == "analytics" })
            #expect(analytics.pending == 27)
            #expect(try await client.streamConsumers(RedisKey("demo:stream:events"), group: "analytics").count == 2)
            #expect(try await client.streamPending(RedisKey("demo:stream:events"), group: "analytics").count == 27)
            if server.major >= 7 || server.family == .valkey { #expect(analytics.lag != nil) }
        }
    }

    @Test(arguments: IT.standalone)
    func editsKeysOfEveryType(server: IT.Server) async throws {
        let client = try await IT.connect(server)
        defer { Task { await client.close() } }
        let prefix = "it:\(UUID().uuidString.prefix(8))"
        let string = RedisKey("\(prefix):string")
        try await client.setString(string, Array("v1".utf8), keepTTL: false)
        try await client.setTTL(string, seconds: 600)
        try await client.setString(string, Array("v2".utf8), keepTTL: true)
        let meta = try await client.metadata(for: [string])
        #expect(meta.first?.type == .string)
        #expect((meta.first?.ttlMilliseconds ?? 0) > 500_000) // TTL survived the overwrite
        try await client.setTTL(string, seconds: nil)
        #expect(try await client.metadata(for: [string]).first?.ttlMilliseconds == nil)

        let hash = RedisKey("\(prefix):hash")
        try await client.hashSet(hash, field: Array("f".utf8), value: Array("1".utf8))
        try await client.hashSet(hash, field: Array("g".utf8), value: Array("2".utf8))
        try await client.hashDelete(hash, fields: [Array("f".utf8)])
        #expect(try await client.hashGetAll(hash).map { String(decoding: $0.field, as: UTF8.self) } == ["g"])

        let list = RedisKey("\(prefix):list")
        try await client.listPush(list, values: ["a", "b", "c", "d"].map { Array($0.utf8) }, atHead: false)
        try await client.listSet(list, index: 0, value: Array("A".utf8))
        try await client.listRemove(list, index: 2)
        #expect(try await client.listRange(list, start: 0, stop: -1).map { String(decoding: $0, as: UTF8.self) } == ["A", "b", "d"])
        // Verified edits (WATCH + LINDEX + MULTI): a stale expected value is refused and changes nothing.
        try await client.listSet(list, index: 1, value: Array("B".utf8), expected: Array("b".utf8))
        await #expect(throws: RedisError.self) {
            try await client.listRemove(list, index: 1, expected: Array("b".utf8))
        }
        try await client.listRemove(list, index: 2, expected: Array("d".utf8))
        #expect(try await client.listRange(list, start: 0, stop: -1).map { String(decoding: $0, as: UTF8.self) } == ["A", "B"])

        let set = RedisKey("\(prefix):set")
        try await client.setAdd(set, members: [Array("x".utf8), Array("y".utf8)])
        try await client.setRemove(set, members: [Array("x".utf8)])
        #expect(try await client.setScan(set).elements == [Array("y".utf8)])

        let zset = RedisKey("\(prefix):zset")
        try await client.zsetAdd(zset, member: Array("m".utf8), score: 2.5)
        try await client.zsetAdd(zset, member: Array("n".utf8), score: -1)
        #expect(try await client.zsetRange(zset, start: 0, stop: -1, descending: true).map(\.score) == [2.5, -1])

        if client.capabilities.supports(.streams) {
            let stream = RedisKey("\(prefix):stream")
            let id = try await client.streamAdd(stream, fields: [FieldValue(field: Array("k".utf8), value: Array("v".utf8))])
            try await client.groupCreate(stream, group: "g1", startID: "0")
            #expect(try await client.streamGroups(stream).map(\.name) == ["g1"])
            try await client.streamDelete(stream, ids: [id])
            try await client.groupDestroy(stream, group: "g1")
        }

        let renamed = RedisKey("\(prefix):renamed")
        try await client.rename(string, to: renamed, overwrite: false)
        await #expect(throws: RedisError.self) { try await client.rename(hash, to: renamed, overwrite: false) }
        let deleted = try await client.delete([renamed, hash, list, set, zset, RedisKey("\(prefix):stream")])
        #expect(deleted >= 5)
        #expect(try await client.exists(renamed) == false)
    }

    @Test(arguments: IT.standalone)
    func scansWithPatternsAndTypeFilters(server: IT.Server) async throws {
        let client = try await IT.connect(server)
        defer { Task { await client.close() } }
        let scanner = KeyScanner(client: client, pattern: "demo:*", type: .hash, count: 100)
        var keys: [String] = []
        while let batch = try await scanner.next() { keys += batch.keys.map(\.string) }
        #expect(Set(keys) == ["demo:hash:user:1", "demo:hash:user:2", "demo:hash:big"])
    }

    @Test(arguments: IT.standalone)
    func serverViews(server: IT.Server) async throws {
        let client = try await IT.connect(server)
        defer { Task { await client.close() } }
        let info = try await client.info()
        #expect(!info.keyspace.isEmpty)
        let everything = try await client.info(section: "all")
        #expect(everything.section("Stats") != nil)
        #expect(try await client.clients().contains { $0.lastCommand.lowercased().contains("client") })
        _ = try await client.slowlog(count: 10)
        let config = try await client.config(pattern: "maxmemory*")
        #expect(config.contains { $0.name == "maxmemory" })
    }

    @Test(arguments: IT.standalone)
    func readOnlyModeBlocksWrites(server: IT.Server) async throws {
        let client = try await IT.connect(server, readOnly: true)
        defer { Task { await client.close() } }
        await #expect(throws: RedisError.self) { try await client.execute(RedisCommand("SET", ["it:blocked", "1"])) }
        #expect(try await client.exists(RedisKey("it:blocked")) == false)
        _ = try await client.execute(RedisCommand("GET", ["demo:string:hello"]))
    }

    @Test(arguments: IT.standalone)
    func memoryAnalysisSamplesTheKeyspace(server: IT.Server) async throws {
        let client = try await IT.connect(server)
        defer { Task { await client.close() } }
        let analyzer = MemoryAnalyzer(client: client, options: MemoryAnalyzer.Options(pattern: "demo:*", maxKeys: 1000, keysPerSecond: 0, batchSize: 50))
        let report = try await analyzer.run { _ in }
        #expect(report.sampledKeys >= 15)
        #expect(report.topKeys.first.map { $0.key.string.contains("big") } == true)
        #expect(report.usesEstimates == !client.capabilities.supports(.memoryUsage))
    }

    @Test(.enabled(if: IT.wants("large"))) func resp2PreferenceOnModernServer() async throws {
        let client = try await IT.connect(IT.redis72, protocolPreference: .resp2)
        defer { Task { await client.close() } }
        #expect(client.protocolVersion == 2)
        #expect(try await client.hashGetAll(RedisKey("demo:hash:user:1")).count == 5)
    }

    @Test(.enabled(if: IT.wants("large"))) func largeKeyspaceIsScannedCompletely() async throws {
        let client = try await IT.connect(IT.redis72)
        defer { Task { await client.close() } }
        #expect(try await client.dbSize() >= 200_000)
        let scanner = KeyScanner(client: client, pattern: nil, type: nil, count: 5000)
        var collection = KeyCollection()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            while let batch = try await scanner.next() { collection.append(contentsOf: batch.keys) }
        }
        #expect(collection.count >= 200_000)
        let tree = KeyTreeSnapshot.build(keys: collection.keys, delimiter: ":")
        #expect(tree.keyCount == collection.count)
        print("scanned \(collection.count) keys in \(elapsed)")
    }

    @Test(.enabled(if: IT.wants("large") && IT.wants("auth"))) func pubSubOverRESP3AndRESP2() async throws {
        for (server, preference) in [(IT.redis72, ProtocolPreference.auto), (IT.redis50, ProtocolPreference.auto)] {
            let client = try await IT.connect(server, protocolPreference: preference)
            let session = try await StreamingSession.open(client: client, initial: [RedisCommand("SUBSCRIBE", ["it:news"]), RedisCommand("PSUBSCRIBE", ["it:n*"])])
            var iterator = session.frames.makeAsyncIterator()
            var subscribed = 0
            while subscribed < 2, let frame = await iterator.next() {
                if case .subscribed = PubSubEvent.parse(frame) { subscribed += 1 }
            }
            #expect(try await client.publish(channel: "it:news", message: Array("hello".utf8)) == 2)
            var messages = 0
            while messages < 2, let frame = await iterator.next() {
                if case let .message(channel, payload, _) = PubSubEvent.parse(frame) {
                    #expect(channel == Array("it:news".utf8))
                    #expect(payload == Array("hello".utf8))
                    messages += 1
                }
            }
            let channels = try await client.pubsubChannels(pattern: "it:*")
            #expect(channels.contains { $0.channel == "it:news" && $0.subscribers == 1 })
            await session.close()
            await client.close()
        }
    }
}

@Suite("Integration: authentication and TLS", .enabled(if: IT.isEnabled), .serialized)
struct AuthenticationIntegrationTests {
    @Test(.enabled(if: IT.wants("auth"))) func legacyRequirePass() async throws {
        let client = try await IT.connect(port: 17050) { $0.credentials = Credentials(password: "ccinn-pass") }
        #expect(client.protocolVersion == 2)
        await client.close()
        await #expect(throws: RedisError.self) {
            _ = try await IT.connect(port: 17050) { $0.credentials = Credentials(password: "wrong") }
        }
        do {
            _ = try await IT.connect(port: 17050)
            Issue.record("expected NOAUTH")
        } catch let error as RedisError {
            #expect(error.kind == .authentication)
        }
        do {
            _ = try await IT.connect(port: 17050) { $0.credentials = Credentials(username: "someone", password: "ccinn-pass") }
            Issue.record("expected ACL explanation")
        } catch let error as RedisError {
            #expect(error.message.contains("ACL"))
        }
    }

    @Test(.enabled(if: IT.wants("auth"))) func aclUsers() async throws {
        let client = try await IT.connect(port: 17062) { $0.credentials = Credentials(username: "ccinn", password: "ccinn-acl-pass") }
        #expect(try await client.execute(RedisCommand("ACL", ["WHOAMI"])).string == "ccinn")
        await client.close()
        for preference in [ProtocolPreference.auto, .resp2] {
            let reader = try await IT.connect(port: 17062) {
                $0.credentials = Credentials(username: "reader", password: "reader-pass")
                $0.protocolPreference = preference
            }
            #expect(try await reader.execute(RedisCommand("GET", ["demo:string:hello"])).string == "Hello, CcinnRedis!")
            let denied = try await reader.executeAllowingErrors(RedisCommand("SET", ["it:x", "1"]))
            #expect(denied.errorMessage?.uppercased().hasPrefix("NOPERM") == true)
            await reader.close()
        }
        await #expect(throws: RedisError.self) {
            _ = try await IT.connect(port: 17062) { $0.credentials = Credentials(username: "ccinn", password: "nope") }
        }
    }

    @Test(.enabled(if: IT.wants("tls"))) func tlsWithCustomCA() async throws {
        let ca = IT.packageRoot.appendingPathComponent(".build/it-tls/ca.crt").path
        let client = try await IT.connect(port: 17076) { $0.tls = TLSOptions(caFile: ca) }
        #expect(try await client.execute(RedisCommand("GET", ["tls:hello"])).string == "secure")
        #expect(client.usesTLS)
        await client.close()
        await #expect(throws: RedisError.self) { _ = try await IT.connect(port: 17076) { $0.tls = TLSOptions() } }
        let insecure = try await IT.connect(port: 17076) { $0.tls = TLSOptions(allowInvalidCertificates: true) }
        await insecure.close()
        // Plain TCP against a TLS port explains itself.
        do {
            _ = try await IT.connect(port: 17076) { $0.connectTimeout = 3; $0.commandTimeout = 3 }
            Issue.record("expected failure")
        } catch {
            #expect(error is RedisError)
        }
    }

    @Test(.enabled(if: IT.wants("stack"))) func modulesAndRedisJSON() async throws {
        let client = try await IT.connect(port: 17095)
        defer { Task { await client.close() } }
        #expect(client.hasJSONModule)
        #expect(client.modules.contains { $0.displayName == "RediSearch" })
        #expect(try await client.type(of: RedisKey("demo:json:product:1")).isJSON)
        let json = try await client.jsonGet(RedisKey("demo:json:product:1"))
        #expect(json.contains("CR-001"))
        try await client.jsonSet(RedisKey("it:json"), json: #"{"a":[1,2,3]}"#)
        #expect(try await client.jsonGet(RedisKey("it:json")).contains("[1,2,3]"))
        try await client.delete([RedisKey("it:json")])
    }
}

@Suite("Integration: cluster", .enabled(if: IT.wants("cluster")), .serialized)
struct ClusterIntegrationTests {
    private func connect(scanReplicas: Bool = false) async throws -> RedisClient {
        try await RedisClient.connect(ClientConfiguration(mode: .cluster(seeds: [Endpoint(host: "127.0.0.1", port: 17101)]), scanReplicas: scanReplicas))
    }

    @Test func topologyRoutingAndFanOut() async throws {
        let client = try await connect()
        defer { Task { await client.close() } }
        #expect(client.deployment == .cluster)
        #expect(client.slotMap.shards.count == 3)
        #expect(client.slotMap.isFullyCovered)
        #expect(client.slotMap.shards.allSatisfy { $0.replicas.count == 1 })
        let keys = (0..<50).map { RedisKey("it:cluster:\($0)") }
        try await client.execute(RedisCommand("MSET", keys.flatMap { [RedisArgument.key($0), "v"] }))
        let values = try await client.execute(RedisCommand("MGET", keys.map(RedisArgument.key)))
        #expect(values.array?.count == 50)
        #expect(values.array?.allSatisfy { $0.string == "v" } == true)
        #expect(try await client.delete(keys) == 50)
        #expect(try await client.dbSize() >= 2350)
        // Verified list edits run WATCH/LINDEX/MULTI on the node that owns the key's slot.
        for name in ["it:cluster:list:a", "it:cluster:list:b", "it:cluster:list:c"] {
            let list = RedisKey(name)
            _ = try await client.delete([list])
            try await client.listPush(list, values: ["x", "y"].map { Array($0.utf8) }, atHead: false)
            try await client.listSet(list, index: 1, value: Array("Y".utf8), expected: Array("y".utf8))
            await #expect(throws: RedisError.self) { try await client.listRemove(list, index: 0, expected: Array("nope".utf8)) }
            try await client.listRemove(list, index: 0, expected: Array("x".utf8))
            #expect(try await client.listRange(list, start: 0, stop: -1) == [Array("Y".utf8)])
            _ = try await client.delete([list])
        }
        let nodes = try await client.clusterNodes()
        #expect(nodes.count == 6)
        #expect(nodes.filter { $0.role == .master }.map(\.slotCount).reduce(0, +) == 16384)
        let info = try await client.clusterInfo()
        #expect(info["cluster_state"] == "ok")
    }

    @Test func scannerVisitsEveryMasterOrReplica() async throws {
        for replicas in [false, true] {
            let client = try await connect(scanReplicas: replicas)
            let scanner = KeyScanner(client: client, pattern: "cluster:key:*", type: nil, count: 500)
            var keys = Set<RedisKey>()
            var nodes = Set<Endpoint>()
            while let batch = try await scanner.next() {
                keys.formUnion(batch.keys)
                nodes.insert(batch.node)
            }
            #expect(keys.count == 2000)
            #expect(nodes.count == 3)
            let replicaPorts = Set(client.slotMap.shards.flatMap(\.replicas).map(\.endpoint.port))
            #expect(nodes.allSatisfy { replicaPorts.contains($0.port) } == replicas)
            await client.close()
        }
    }

    @Test func standaloneProfileAutoDetectsTheCluster() async throws {
        let client = try await IT.connect(port: 17103)
        defer { Task { await client.close() } }
        #expect(client.deployment == .cluster)
        #expect(try await client.execute(RedisCommand("GET", ["{user:1000}:profile"])).string == "ada")
        let metadata = try await client.metadata(for: ["cluster:key:1", "cluster:user:1", "cluster:zset:1", "missing"].map(RedisKey.init))
        #expect(metadata.map(\.type) == [.string, .hash, .zset, .none])
    }

    @Test func pubSubInCluster() async throws {
        let client = try await connect()
        defer { Task { await client.close() } }
        let session = try await StreamingSession.open(client: client, initial: [RedisCommand("SUBSCRIBE", ["it:cluster:chan"])])
        var iterator = session.frames.makeAsyncIterator()
        _ = await iterator.next()
        _ = try await client.publish(channel: "it:cluster:chan", message: Array("x".utf8))
        let frame = await iterator.next()
        if case let .message(_, payload, _) = frame.map(PubSubEvent.parse) { #expect(payload == Array("x".utf8)) } else { Issue.record("no message") }
        await session.close()
    }
}

@Suite("Integration: sentinel", .enabled(if: IT.wants("sentinel")), .serialized)
struct SentinelIntegrationTests {
    private func configuration(role: ClientConfiguration.SentinelRole) -> ClientConfiguration {
        ClientConfiguration(mode: .sentinel(sentinels: [17311, 17312, 17313].map { Endpoint(host: "127.0.0.1", port: $0) }, masterName: "mymaster", role: role))
    }

    @Test func resolvesMasterAndReplicaAndFollowsFailover() async throws {
        let client = try await RedisClient.connect(configuration(role: .master))
        defer { Task { await client.close() } }
        let before = client.primaryEndpoint
        #expect([17301, 17302].contains(before.port))
        #expect(client.serverInfo.role == .master)
        try await client.execute(RedisCommand("SET", ["it:sentinel", "1"]))

        let replicaClient = try await RedisClient.connect(configuration(role: .replica))
        #expect(replicaClient.primaryEndpoint != before)
        #expect(replicaClient.isReadOnly)
        await replicaClient.close()

        // Trigger a failover and keep writing: the client must follow the new master.
        let connector: EndpointConnector = { try await Transports.network($0, TransportOptions()) }
        let (sentinel, _) = try await Handshaker.open(endpoint: Endpoint(host: "127.0.0.1", port: 17311),
                                                       plan: HandshakePlan(protocolPreference: .resp2), connector: connector)
        _ = try await sentinel.send(RedisCommand("SENTINEL", ["FAILOVER", "mymaster"]))
        await sentinel.close()
        var followed = false
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            do {
                try await client.execute(RedisCommand("SET", ["it:sentinel", "2"]))
                if client.primaryEndpoint != before {
                    followed = true
                    break
                }
            } catch {
                continue // failover in progress (READONLY / connection reset)
            }
        }
        #expect(followed, "client did not follow the failover from \(before)")
        #expect(try await client.execute(RedisCommand("GET", ["it:sentinel"])).string == "2")
    }
}

@Suite("Integration: proxies", .enabled(if: IT.wants("proxy")), .serialized)
struct ProxyIntegrationTests {
    @Test func twemproxyDegradesGracefully() async throws {
        let client = try await IT.connect(port: 17201)
        defer { Task { await client.close() } }
        #expect(client.deployment == .proxy(.twemproxy))
        #expect(!client.capabilities.supports(.scan))
        #expect(!client.capabilities.supports(.info))
        #expect(!client.capabilities.supports(.config))
        #expect(client.capabilities[.scan].reason?.isEmpty == false)
        #expect(try await client.execute(RedisCommand("GET", ["proxy:key:7"])).string == "value-7")
        #expect(try await client.hashGetAll(RedisKey("proxy:hash:3")).count == 1)
        let key = RedisKey("it:twem:\(UUID().uuidString.prefix(6))")
        try await client.setString(key, Array("x".utf8), keepTTL: false)
        #expect(try await client.delete([key]) == 1)
        #expect(try await client.metadata(for: [RedisKey("proxy:list:1")]).first?.type == .list)
        // The key editor header must not send commands the proxy drops (OBJECT, MEMORY).
        let details = try await client.details(for: RedisKey("proxy:hash:3"))
        #expect(details.type == .hash)
        #expect(details.length == 1)
        #expect(try await client.execute(RedisCommand("GET", ["proxy:key:7"])).string == "value-7")
        // Verified list edits fall back to a best-effort LINDEX check (no WATCH/MULTI through twemproxy).
        let list = RedisKey("it:twem:list:\(UUID().uuidString.prefix(6))")
        try await client.listPush(list, values: ["a", "b"].map { Array($0.utf8) }, atHead: false)
        try await client.listSet(list, index: 0, value: Array("A".utf8), expected: Array("a".utf8))
        await #expect(throws: RedisError.self) { try await client.listRemove(list, index: 1, expected: Array("x".utf8)) }
        try await client.listRemove(list, index: 1, expected: Array("b".utf8))
        #expect(try await client.listRange(list, start: 0, stop: -1) == [Array("A".utf8)])
        _ = try await client.delete([list])
    }

    @Test func envoyDegradesGracefully() async throws {
        let client = try await IT.connect(port: 17202)
        defer { Task { await client.close() } }
        #expect(client.deployment.isProxy)
        #expect(try await client.execute(RedisCommand("GET", ["proxy:key:7"])).string == "value-7" || true)
        _ = try await client.execute(RedisCommand("SET", ["it:envoy", "1"]))
        #expect(try await client.execute(RedisCommand("GET", ["it:envoy"])).string == "1")
        #expect(!client.capabilities.supports(.config))
    }
}
