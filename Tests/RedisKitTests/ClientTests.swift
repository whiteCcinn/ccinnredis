import Foundation
import os
import RESPWire
import Testing
@testable import RedisKit

/// A tiny keyspace for client-level tests (strings, hashes, sets, zsets; SCAN; TYPE; PTTL).
final class MiniKeyspace: @unchecked Sendable {
    enum Value { case string(String), hash([String: String]), set(Set<String>), zset([String: Double]) }
    private let lock = OSAllocatedUnfairLock()
    private var data: [String: Value] = [:]

    init(_ initial: [String: Value] = [:]) { data = initial }

    func handle(_ request: FakeRequest, resp3: Bool) -> FakeAction? {
        lock.lock()
        defer { lock.unlock() }
        let args = request.strings
        switch request.name {
        case "GET":
            if case let .string(value)? = data[args[1]] { return .reply(.bulk(value)) }
            return .reply(.null)
        case "SET":
            data[args[1]] = .string(args[2])
            return .reply(.ok)
        case "TYPE":
            switch data[args[1]] {
            case .string?: return .reply(.simpleString("string"))
            case .hash?: return .reply(.simpleString("hash"))
            case .set?: return .reply(.simpleString("set"))
            case .zset?: return .reply(.simpleString("zset"))
            case nil: return .reply(.simpleString("none"))
            }
        case "PTTL": return .reply(.integer(data[args[1]] == nil ? -2 : -1))
        case "EXISTS", "DEL", "UNLINK", "TOUCH":
            var count: Int64 = 0
            for key in args.dropFirst() where data[key] != nil {
                count += 1
                if request.name == "DEL" || request.name == "UNLINK" { data[key] = nil }
            }
            return .reply(.integer(count))
        case "MGET":
            return .reply(.array(args.dropFirst().map { if case let .string(v)? = data[$0] { .bulk(v) } else { .null } }))
        case "DBSIZE": return .reply(.integer(Int64(data.count)))
        case "SCAN":
            var keys = data.keys.sorted()
            if let index = args.firstIndex(where: { $0.uppercased() == "MATCH" }), index + 1 < args.count {
                let pattern = args[index + 1].replacingOccurrences(of: "*", with: "")
                keys = keys.filter { $0.hasPrefix(pattern) }
            }
            if let index = args.firstIndex(where: { $0.uppercased() == "TYPE" }), index + 1 < args.count {
                let wanted = args[index + 1]
                keys = keys.filter { key in
                    switch data[key] {
                    case .string?: wanted == "string"
                    case .hash?: wanted == "hash"
                    case .set?: wanted == "set"
                    case .zset?: wanted == "zset"
                    case nil: false
                    }
                }
            }
            // Two pages: cursor 0 → 1 → 0.
            let half = keys.count / 2
            if args[1] == "0" { return .reply(.array([.bulk("1"), .array(keys.prefix(half).map { .bulk($0) })])) }
            return .reply(.array([.bulk("0"), .array(keys.dropFirst(half).map { .bulk($0) })]))
        case "HGETALL":
            guard case let .hash(fields)? = data[args[1]] else { return .reply(resp3 ? .map([]) : .array([])) }
            let sorted = fields.sorted { $0.key < $1.key }
            if resp3 { return .reply(.map(sorted.map { RESPPair(.bulk($0.key), .bulk($0.value)) })) }
            return .reply(.array(sorted.flatMap { [.bulk($0.key), .bulk($0.value)] }))
        case "ZRANGE":
            guard case let .zset(members)? = data[args[1]] else { return .reply(.array([])) }
            let sorted = members.sorted { $0.value < $1.value }
            if resp3 { return .reply(.array(sorted.map { .array([.bulk($0.key), .double($0.value)]) })) }
            return .reply(.array(sorted.flatMap { [.bulk($0.key), .bulk(String($0.value))] }))
        default:
            return nil
        }
    }
}

/// Standalone server answering HELLO (or not) and INFO, delegating data commands to `keyspace`.
func standaloneBackend(version: String = "7.2.4", hello: Bool = true, keyspace: MiniKeyspace = MiniKeyspace(),
                       extra: @escaping @Sendable (FakeRequest) -> FakeAction? = { _ in nil }) -> FakeRedisBackend {
    FakeRedisBackend { request in
        if let action = extra(request) { return action }
        switch request.name {
        case "HELLO": return hello ? .reply(helloReply(version: version)) : .reply(.err("ERR unknown command 'HELLO'"))
        case "INFO": return .reply(.bulk("# Server\r\nredis_version:\(version)\r\nredis_mode:standalone\r\n# Replication\r\nrole:master\r\n"))
        case "COMMAND":
            if request.argument(1)?.uppercased() == "LIST" { return .reply(.array(["get", "set", "scan", "info", "unlink", "memory", "config", "client", "slowlog", "subscribe", "pubsub", "xadd", "hello", "object", "dbsize", "select", "keys", "module", "role", "function", "acl", "latency", "monitor", "rename", "copy", "getdel", "lpos", "expiretime", "xautoclaim", "ssubscribe"].map { .bulk($0) })) }
            return .reply(.array([]))
        case "MODULE": return .reply(.array([]))
        case "CLIENT": return .reply(.ok)
        case "PING": return .reply(.simpleString("PONG"))
        default:
            return keyspace.handle(request, resp3: hello) ?? .reply(.err("ERR unknown command '\(request.name)'"))
        }
    }
}

@Suite("Client: standalone and versions")
struct StandaloneClientTests {
    @Test func modernServerUsesRESP3AndDerivesCapabilities() async throws {
        let backend = standaloneBackend()
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
        #expect(client.protocolVersion == 3)
        #expect(client.serverInfo.version == ServerVersion(7, 2, 4))
        #expect(client.deployment == .standalone)
        #expect(client.capabilities.supports(.unlink))
        #expect(client.capabilities.supports(.resp3))
        #expect(!client.isReadOnly)
        await client.close()
    }

    @Test func oldServerFallsBackAndDisablesModernFeatures() async throws {
        let keyspace = MiniKeyspace(["a": .string("1"), "b": .string("2")])
        let backend = standaloneBackend(version: "3.2.12", hello: false, keyspace: keyspace)
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
        #expect(client.protocolVersion == 2)
        #expect(!client.capabilities.supports(.unlink))
        #expect(!client.capabilities.supports(.memoryUsage))
        // Delete uses DEL because UNLINK needs 4.0.
        #expect(try await client.delete([RedisKey("a")]) == 1)
        #expect(backend.commandNames.contains("DEL"))
        #expect(!backend.commandNames.contains("UNLINK"))
        // RESP2 connections are named once detection proved a real Redis.
        _ = try await client.execute(RedisCommand("GET", ["b"]))
        await client.close()
    }

    @Test func unlinkFallsBackToDelOnUnknownCommand() async throws {
        let keyspace = MiniKeyspace(["a": .string("1")])
        let backend = standaloneBackend(keyspace: keyspace, extra: { request in
            request.name == "UNLINK" ? .reply(.err("ERR unknown command 'UNLINK'")) : nil
        })
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
        #expect(try await client.delete([RedisKey("a")]) == 1)
        #expect(!client.capabilities.supports(.unlink))
        await client.close()
    }

    @Test func readOnlyProfileBlocksWritesBeforeSending() async throws {
        let backend = standaloneBackend()
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h")), readOnly: true), connector: backend.connector)
        do {
            try await client.execute(RedisCommand("SET", ["k", "v"]))
            Issue.record("expected read-only error")
        } catch let error as RedisError {
            #expect(error.kind == .readOnly)
        }
        await #expect(throws: RedisError.self) { try await client.execute(RedisCommand("FLUSHALL")) }
        await #expect(throws: RedisError.self) { try await client.execute(RedisCommand("SOMEMODULE.WRITE", ["x"])) }
        #expect(!backend.commandNames.contains("SET"))
        #expect(!backend.commandNames.contains("FLUSHALL"))
        _ = try await client.execute(RedisCommand("GET", ["k"]))
        await client.close()
    }

    @Test func replicaIsReadOnlyAutomatically() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "HELLO": .reply(helloReply(role: "replica"))
            case "INFO": .reply(.bulk("# Server\nredis_version:7.2.4\nredis_mode:standalone\n# Replication\nrole:slave\nmaster_host:10.0.0.1\nmaster_port:6379\n"))
            default: .reply(.array([]))
            }
        }
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
        #expect(client.deployment == .replica)
        #expect(client.isReadOnly)
        await client.close()
    }

    @Test func sentinelPortIsExplained() async {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "HELLO": .reply(.err("ERR unknown command"))
            case "INFO": .reply(.bulk("# Server\nredis_version:7.2.4\nredis_mode:sentinel\n"))
            default: .reply(.ok)
            }
        }
        do {
            _ = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h", port: 26379))), connector: backend.connector)
            Issue.record("expected failure")
        } catch let error as RedisError {
            #expect(error.message.contains("Sentinel"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func valuesAreNormalisedAcrossRESP2AndRESP3() async throws {
        for hello in [true, false] {
            let keyspace = MiniKeyspace(["h": .hash(["f1": "v1", "f2": "v2"]), "z": .zset(["a": 1, "b": 2.5])])
            let backend = standaloneBackend(hello: hello, keyspace: keyspace)
            let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
            let fields = try await client.hashGetAll(RedisKey("h"))
            #expect(fields.map { String(decoding: $0.field, as: UTF8.self) } == ["f1", "f2"])
            let members = try await client.zsetRange(RedisKey("z"), start: 0, stop: -1)
            #expect(members.map(\.score) == [1, 2.5])
            await client.close()
        }
    }

    @Test func scannerFiltersTypesClientSideOnOldServers() async throws {
        let keyspace = MiniKeyspace(["s1": .string("x"), "h1": .hash(["a": "b"]), "s2": .string("y"), "h2": .hash(["c": "d"])])
        let backend = standaloneBackend(version: "5.0.14", hello: false, keyspace: keyspace)
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
        #expect(!client.capabilities.supports(.scanType))
        let scanner = KeyScanner(client: client, pattern: nil, type: .hash)
        var keys: [String] = []
        while let batch = try await scanner.next() { keys += batch.keys.map(\.string) }
        #expect(keys.sorted() == ["h1", "h2"])
        #expect(!backend.commands.contains { $0.first == "SCAN" && $0.contains("TYPE") })
        await client.close()
    }
}

@Suite("Client: proxies")
struct ProxyClientTests {
    /// twemproxy: drops the connection on HELLO, INFO, SCAN, CONFIG… but forwards data commands.
    private func twemproxy(keyspace: MiniKeyspace = MiniKeyspace()) -> FakeRedisBackend {
        FakeRedisBackend { request in
            switch request.name {
            case "HELLO", "INFO", "SCAN", "CONFIG", "CLIENT", "SLOWLOG", "SELECT", "COMMAND", "MODULE", "ROLE", "LATENCY", "SUBSCRIBE", "PUBSUB", "MEMORY", "DBSIZE", "UNLINK":
                .drop
            case "PING": .reply(.simpleString("PONG"))
            default: keyspace.handle(request, resp3: false) ?? .drop
            }
        }
    }

    @Test func twemproxyIsDetectedAndDegradesGracefully() async throws {
        let keyspace = MiniKeyspace(["user:1": .string("alice")])
        let backend = twemproxy(keyspace: keyspace)
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "proxy"))), connector: backend.connector)
        #expect(client.deployment == .proxy(.twemproxy))
        #expect(client.protocolVersion == 2)
        #expect(!client.capabilities.supports(.scan))
        #expect(!client.capabilities.supports(.info))
        #expect(!client.capabilities.supports(.select))
        #expect(client.capabilities[.scan].reason?.contains("twemproxy") == true)
        // Data commands still work after the probes.
        #expect(try await client.execute(RedisCommand("GET", ["user:1"])).string == "alice")
        // The key scanner explains instead of dropping connections.
        let scanner = KeyScanner(client: client, pattern: nil, type: nil)
        await #expect(throws: RedisError.self) { _ = try await scanner.next() }
        // Deletes fall back to DEL when UNLINK is not forwarded.
        _ = try await client.execute(RedisCommand("SET", ["k", "v"]))
        await client.close()
    }

    @Test func declaredProxySkipsInfoClassification() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "INFO": .reply(.bulk("# Server\nredis_version:5.0.5\n"))
            case "SCAN": .reply(.array([.bulk("0"), .array([])]))
            case "HELLO": .reply(.err("ERR unsupported command 'hello'"))
            default: .reply(.err("ERR unsupported command '\(request.name.lowercased())'"))
            }
        }
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "envoy")), proxyHint: .proxy(.envoy)),
                                                   connector: backend.connector)
        #expect(client.deployment == .proxy(.envoy))
        #expect(client.capabilities.supports(.scan))
        #expect(client.capabilities.supports(.info))
        #expect(!client.capabilities.supports(.config))
        await client.close()
    }

    @Test func envoyIsRecognisedFromItsErrors() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "GET": .reply(.bulk("v"))
            default: .reply(.err("ERR unsupported command '\(request.name.lowercased())'"))
            }
        }
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "envoy"))), connector: backend.connector)
        #expect(client.deployment == .proxy(.envoy))
        #expect(try await client.execute(RedisCommand("GET", ["a"])).string == "v")
        await client.close()
    }
}

/// Three-master cluster fake. Slots: node1 0-5460, node2 5461-10922, node3 10923-16383.
final class FakeCluster: @unchecked Sendable {
    let nodes = [Endpoint(host: "127.0.0.1", port: 7001), Endpoint(host: "127.0.0.1", port: 7002), Endpoint(host: "127.0.0.1", port: 7003)]
    let replicas = [Endpoint(host: "127.0.0.1", port: 7004)]
    private let lock = OSAllocatedUnfairLock()
    private var data: [Endpoint: [String: String]] = [:]
    /// Slot that node 1 currently answers with MOVED to node 2 (simulates a stale map).
    var movedSlot: Int?
    /// Slot that is being migrated: node owner answers ASK to node 3.
    var askSlot: Int?

    func owner(of slot: Int) -> Endpoint {
        if slot <= 5460 { return nodes[0] }
        if slot <= 10922 { return nodes[1] }
        return nodes[2]
    }

    lazy var backend: FakeRedisBackend = FakeRedisBackend { request in self.handle(request) } // test-only retain cycle

    func store(_ key: String, _ value: String) {
        let node = owner(of: HashSlot.slot(for: RedisKey(key)))
        lock.withLock { data[node, default: [:]][key] = value }
    }

    func handle(_ request: FakeRequest) -> FakeAction {
        let args = request.strings
        switch request.name {
        case "HELLO": return .reply(helloReply(mode: "cluster"))
        case "INFO": return .reply(.bulk("# Server\nredis_version:7.2.4\nredis_mode:cluster\n# Replication\nrole:master\n"))
        case "COMMAND", "MODULE": return .reply(.array([]))
        case "CLUSTER":
            if args[1].uppercased() == "SHARDS" {
                func node(_ endpoint: Endpoint, _ role: String) -> RESPValue {
                    .map([RESPPair(.bulk("id"), .bulk("id\(endpoint.port)")), RESPPair(.bulk("port"), .integer(Int64(endpoint.port))),
                          RESPPair(.bulk("ip"), .bulk(endpoint.host)), RESPPair(.bulk("endpoint"), .bulk(endpoint.host)),
                          RESPPair(.bulk("role"), .bulk(role)), RESPPair(.bulk("health"), .bulk("online"))])
                }
                return .reply(.array([
                    .map([RESPPair(.bulk("slots"), .array([.integer(0), .integer(5460)])), RESPPair(.bulk("nodes"), .array([node(nodes[0], "master"), node(replicas[0], "replica")]))]),
                    .map([RESPPair(.bulk("slots"), .array([.integer(5461), .integer(10922)])), RESPPair(.bulk("nodes"), .array([node(nodes[1], "master")]))]),
                    .map([RESPPair(.bulk("slots"), .array([.integer(10923), .integer(16383)])), RESPPair(.bulk("nodes"), .array([node(nodes[2], "master")]))]),
                ]))
            }
            return .reply(.err("ERR unknown subcommand"))
        case "ASKING": return .reply(.ok)
        case "DBSIZE": return .reply(.integer(Int64(lock.withLock { data[request.endpoint]?.count ?? 0 })))
        case "SCAN":
            let keys = lock.withLock { (data[request.endpoint] ?? [:]).keys.sorted() }
            return .reply(.array([.bulk("0"), .array(keys.map { .bulk($0) })]))
        default:
            break
        }
        // Key commands: check slot ownership.
        guard args.count > 1 else { return .reply(.err("ERR wrong number of arguments")) }
        let keys: [String]
        switch request.name {
        case "MSET": keys = stride(from: 1, to: args.count, by: 2).map { args[$0] }
        case "GET", "SET", "TYPE", "PTTL": keys = [args[1]]
        default: keys = Array(args.dropFirst())
        }
        let slots = Set(keys.map { HashSlot.slot(for: RedisKey($0)) })
        guard slots.count == 1, let slot = slots.first else { return .reply(.err("CROSSSLOT Keys in request don't hash to the same slot")) }
        if slot == movedSlot, request.endpoint == nodes[0] {
            return .reply(.err("MOVED \(slot) \(nodes[1].host):\(nodes[1].port)"))
        }
        if slot == askSlot, request.endpoint != nodes[2] {
            return .reply(.err("ASK \(slot) \(nodes[2].host):\(nodes[2].port)"))
        }
        let expected = slot == movedSlot ? nodes[1] : (slot == askSlot ? nodes[2] : owner(of: slot))
        guard request.endpoint == expected else {
            return .reply(.err("MOVED \(slot) \(expected.host):\(expected.port)"))
        }
        return lock.withLock { () -> FakeAction in
            var bucket = data[request.endpoint] ?? [:]
            defer { data[request.endpoint] = bucket }
            switch request.name {
            case "GET": return .reply(bucket[args[1]].map { .bulk($0) } ?? .null)
            case "SET":
                bucket[args[1]] = args[2]
                return .reply(.ok)
            case "MSET":
                for index in stride(from: 1, to: args.count - 1, by: 2) { bucket[args[index]] = args[index + 1] }
                return .reply(.ok)
            case "MGET": return .reply(.array(keys.map { bucket[$0].map { .bulk($0) } ?? .null }))
            case "DEL", "UNLINK", "EXISTS":
                var count: Int64 = 0
                for key in keys where bucket[key] != nil {
                    count += 1
                    if request.name != "EXISTS" { bucket[key] = nil }
                }
                return .reply(.integer(count))
            case "TYPE": return .reply(.simpleString(bucket[args[1]] == nil ? "none" : "string"))
            case "PTTL": return .reply(.integer(bucket[args[1]] == nil ? -2 : -1))
            default: return .reply(.err("ERR unknown command"))
            }
        }
    }
}

@Suite("Client: cluster")
struct ClusterClientTests {
    private func connect(_ cluster: FakeCluster, scanReplicas: Bool = false) async throws -> RedisClient {
        try await RedisClient.connect(ClientConfiguration(mode: .cluster(seeds: [cluster.nodes[0]]), scanReplicas: scanReplicas),
                                      connector: cluster.backend.connector)
    }

    @Test func loadsSlotMapAndRoutesByKey() async throws {
        let cluster = FakeCluster()
        let client = try await connect(cluster)
        #expect(client.deployment == .cluster)
        #expect(client.masterEndpoints.count == 3)
        #expect(client.slotMap.isFullyCovered)
        for key in ["foo", "bar", "user:1", "{tag}a"] {
            try await client.execute(RedisCommand("SET", [RedisArgument(key), "v"]))
            #expect(try await client.execute(RedisCommand("GET", [RedisArgument(key)])).string == "v")
        }
        await client.close()
    }

    @Test func standaloneProfileAutoDetectsCluster() async throws {
        let cluster = FakeCluster()
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(cluster.nodes[0])), connector: cluster.backend.connector)
        #expect(client.deployment == .cluster)
        #expect(client.notes.contains { $0.contains("Cluster") })
        await client.close()
    }

    @Test func followsMovedAndUpdatesTheSlotMap() async throws {
        let cluster = FakeCluster()
        let slot = HashSlot.slot(for: RedisKey("bar")) // 5061, owned by node 1
        cluster.movedSlot = slot
        let client = try await connect(cluster)
        try await client.execute(RedisCommand("SET", ["bar", "1"]))
        #expect(try await client.execute(RedisCommand("GET", ["bar"])).string == "1")
        #expect(client.slotMap.master(forSlot: slot)?.endpoint == cluster.nodes[1])
        await client.close()
    }

    @Test func followsAskWithAsking() async throws {
        let cluster = FakeCluster()
        let slot = HashSlot.slot(for: RedisKey("bar")) // owned by node 1, migrating to node 3
        cluster.askSlot = slot
        let client = try await connect(cluster)
        try await client.execute(RedisCommand("SET", ["bar", "x"]))
        #expect(try await client.execute(RedisCommand("GET", ["bar"])).string == "x")
        let onTarget = cluster.backend.commands(on: cluster.nodes[2]).map { $0.first ?? "" }
        #expect(onTarget.contains("ASKING"))
        // ASK does not change the slot map.
        #expect(client.slotMap.master(forSlot: slot)?.endpoint == cluster.owner(of: slot))
        await client.close()
    }

    @Test func multiKeyCommandsAreSplitBySlot() async throws {
        let cluster = FakeCluster()
        let client = try await connect(cluster)
        let keys = ["foo", "bar", "user:1", "user:2", "zap"]
        try await client.execute(RedisCommand("MSET", keys.flatMap { [RedisArgument($0), RedisArgument("v-" + $0)] }))
        let arguments: [RedisArgument] = keys.map { RedisArgument($0) }
        let values = try await client.execute(RedisCommand("MGET", arguments))
        #expect(values.array?.map { $0.string } == keys.map { "v-" + $0 })
        #expect(try await client.execute(RedisCommand("EXISTS", arguments + [RedisArgument("missing")])).int == 5)
        #expect(try await client.delete(keys.map(RedisKey.init)) == 5)
        #expect(try await client.execute(RedisCommand("DBSIZE")).int == 0)
        await client.close()
    }

    @Test func dbsizeSumsMastersAndScannerVisitsEveryMaster() async throws {
        let cluster = FakeCluster()
        for key in ["foo", "bar", "user:1", "user:2", "zap", "a", "b", "c"] { cluster.store(key, "1") }
        let client = try await connect(cluster)
        #expect(try await client.dbSize() == 8)
        let scanner = KeyScanner(client: client, pattern: nil, type: nil)
        var seen: [String] = []
        var nodes = Set<Endpoint>()
        while let batch = try await scanner.next() {
            seen += batch.keys.map(\.string)
            nodes.insert(batch.node)
        }
        #expect(seen.sorted() == ["a", "b", "bar", "c", "foo", "user:1", "user:2", "zap"])
        #expect(nodes.count == 3)
        await client.close()
    }

    @Test func pipelinesAreGroupedPerNode() async throws {
        let cluster = FakeCluster()
        for key in ["foo", "bar", "zap"] { cluster.store(key, key.uppercased()) }
        let client = try await connect(cluster)
        let metadata = try await client.metadata(for: ["foo", "bar", "zap", "nope"].map(RedisKey.init))
        #expect(metadata.map(\.type) == [.string, .string, .string, .none])
        await client.close()
    }

    @Test func renameAcrossSlotsIsRefusedWithExplanation() async throws {
        let cluster = FakeCluster()
        let client = try await connect(cluster)
        do {
            try await client.rename(RedisKey("foo"), to: RedisKey("bar"), overwrite: false)
            Issue.record("expected failure")
        } catch let error as RedisError {
            #expect(error.message.contains("hashtag"))
        }
        await client.close()
    }
}

@Suite("Client: sentinel")
struct SentinelClientTests {
    final class Group: @unchecked Sendable {
        let sentinel = Endpoint(host: "127.0.0.1", port: 26379)
        let first = Endpoint(host: "127.0.0.1", port: 6380)
        let second = Endpoint(host: "127.0.0.1", port: 6381)
        private let lock = OSAllocatedUnfairLock()
        private var masterValue: Endpoint
        init() { masterValue = Endpoint(host: "127.0.0.1", port: 6380) }
        var master: Endpoint {
            get { lock.withLock { masterValue } }
            set { lock.withLock { masterValue = newValue } }
        }

        lazy var backend = FakeRedisBackend { request in // test-only retain cycle
            if request.endpoint == self.sentinel {
                switch request.name {
                case "SENTINEL":
                    switch request.argument(1)?.lowercased() {
                    case "get-master-addr-by-name":
                        return request.argument(2) == "mymaster" ? .reply(.array([.bulk(self.master.host), .bulk(String(self.master.port))])) : .reply(.null)
                    case "replicas":
                        let replica = self.master == self.first ? self.second : self.first
                        return .reply(.array([.array([.bulk("ip"), .bulk(replica.host), .bulk("port"), .bulk(String(replica.port)), .bulk("flags"), .bulk("slave")])]))
                    default: return .reply(.err("ERR unknown"))
                    }
                default: return .reply(.ok)
                }
            }
            let isMaster = request.endpoint == self.master
            switch request.name {
            case "HELLO": return .reply(helloReply(role: isMaster ? "master" : "replica"))
            case "INFO": return .reply(.bulk("# Server\nredis_version:7.2.4\nredis_mode:standalone\n# Replication\nrole:\(isMaster ? "master" : "slave")\n"))
            case "SET": return isMaster ? .reply(.ok) : .reply(.err("READONLY You can't write against a read only replica."))
            case "GET": return .reply(.bulk("from-\(request.endpoint.port)"))
            default: return .reply(.array([]))
            }
        }
    }

    @Test func resolvesMasterAndFollowsFailover() async throws {
        let group = Group()
        let configuration = ClientConfiguration(mode: .sentinel(sentinels: [group.sentinel], masterName: "mymaster", role: .master))
        let client = try await RedisClient.connect(configuration, connector: group.backend.connector)
        #expect(client.primaryEndpoint == group.first)
        #expect(client.deployment == .sentinel(masterName: "mymaster"))
        try await client.execute(RedisCommand("SET", ["k", "v"]))

        // Failover: the old master becomes a replica.
        group.master = group.second
        try await client.execute(RedisCommand("SET", ["k", "v2"]))
        #expect(client.primaryEndpoint == group.second)
        await client.close()
    }

    @Test func replicaRoleConnectsToAReplicaReadOnly() async throws {
        let group = Group()
        let configuration = ClientConfiguration(mode: .sentinel(sentinels: [group.sentinel], masterName: "mymaster", role: .replica))
        let client = try await RedisClient.connect(configuration, connector: group.backend.connector)
        #expect(client.primaryEndpoint == group.second)
        #expect(client.isReadOnly)
        #expect(try await client.execute(RedisCommand("GET", ["k"])).string == "from-6381")
        await client.close()
    }

    @Test func unknownMasterNameIsReported() async {
        let group = Group()
        let configuration = ClientConfiguration(mode: .sentinel(sentinels: [group.sentinel], masterName: "nope", role: .master))
        do {
            _ = try await RedisClient.connect(configuration, connector: group.backend.connector)
            Issue.record("expected failure")
        } catch let error as RedisError {
            #expect(error.message.contains("nope"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("Pub/Sub parsing")
struct PubSubParsingTests {
    @Test func framesAreClassified() {
        #expect(PubSubEvent.parse(.array([.bulk("message"), .bulk("ch"), .bulk("hi")])) == .message(channel: Array("ch".utf8), payload: Array("hi".utf8), pattern: nil))
        #expect(PubSubEvent.parse(.push([.bulk("pmessage"), .bulk("n.*"), .bulk("n.a"), .bulk("x")]))
            == .message(channel: Array("n.a".utf8), payload: Array("x".utf8), pattern: Array("n.*".utf8)))
        #expect(PubSubEvent.parse(.array([.bulk("subscribe"), .bulk("ch"), .integer(1)])) == .subscribed(kind: "subscribe", channel: "ch", count: 1))
        #expect(PubSubEvent.parse(.array([.bulk("pong"), .bulk("")])) == .pong)
    }
}
