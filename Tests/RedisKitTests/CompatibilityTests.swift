import Foundation
import RESPWire
import Testing
@testable import RedisKit

@Suite("Server info and versions")
struct ServerInfoTests {
    @Test func versionParsing() {
        #expect(ServerVersion(parsing: "7.2.4") == ServerVersion(7, 2, 4))
        #expect(ServerVersion(parsing: "2.8.24") == ServerVersion(2, 8, 24))
        #expect(ServerVersion(parsing: "8.0-m02") == ServerVersion(8, 0, 0))
        #expect(ServerVersion(parsing: "6") == ServerVersion(6, 0, 0))
        #expect(ServerVersion(parsing: "abc") == nil)
        #expect(ServerVersion(parsing: "") == nil)
        #expect(ServerVersion(4, 0, 0) < ServerVersion(4, 0, 1))
        #expect(ServerVersion(10, 0, 0) > ServerVersion(9, 9, 9))
    }

    @Test func infoParsingWithSectionsAndKeyspace() {
        let text = "# Server\r\nredis_version:7.2.4\r\nredis_mode:standalone\r\nos:Linux 6.10 aarch64\r\nprocess_id:1\r\ntcp_port:6379\r\nuptime_in_seconds:100\r\n\r\n# Replication\r\nrole:master\r\nconnected_slaves:0\r\n\r\n# Keyspace\r\ndb0:keys=200000,expires=12,avg_ttl=3000\r\ndb3:keys=5,expires=0,avg_ttl=0\r\n"
        let info = InfoSnapshot.parse(text)
        #expect(info.sections.map(\.name) == ["Server", "Replication", "Keyspace"])
        #expect(info["redis_version"] == "7.2.4")
        #expect(info.int("uptime_in_seconds") == 100)
        #expect(info.keyspace == [KeyspaceEntry(database: 0, keys: 200_000, expires: 12, averageTTL: 3000), KeyspaceEntry(database: 3, keys: 5)])
        let server = ServerInfo(info: info)
        #expect(server.family == .redis)
        #expect(server.version == ServerVersion(7, 2, 4))
        #expect(server.mode == "standalone")
        #expect(server.role == .master)
        #expect(server.displayName == "Redis 7.2.4")
    }

    @Test func valkeyIsRecognisedByItsOwnVersion() {
        let info = InfoSnapshot.parse("# Server\nredis_version:7.2.4\nserver_name:valkey\nvalkey_version:8.0.2\nredis_mode:cluster\n# Replication\nrole:slave\nmaster_host:10.0.0.1\nmaster_port:6379\n")
        let server = ServerInfo(info: info)
        #expect(server.family == .valkey)
        #expect(server.version == ServerVersion(8, 0, 2))
        #expect(server.role == .replica)
        #expect(server.masterEndpoint == Endpoint(host: "10.0.0.1", port: 6379))
        #expect(server.mode == "cluster")
    }

    @Test func helloMapGivesServerInfo() {
        let server = ServerInfo(hello: helloReply(version: "7.4.1", mode: "cluster", role: "replica"))
        #expect(server.version == ServerVersion(7, 4, 1))
        #expect(server.mode == "cluster")
        #expect(server.role == .replica)
    }
}

@Suite("Capabilities")
struct CapabilityTests {
    @Test func redis28HasScanButNoUnlinkOrStreams() {
        let caps = Capabilities.derive(server: ServerInfo(family: .redis, version: ServerVersion(2, 8, 24), versionString: "2.8.24"))
        #expect(caps.supports(.scan))
        #expect(!caps.supports(.scanType))
        #expect(!caps.supports(.unlink))
        #expect(!caps.supports(.memoryUsage))
        #expect(!caps.supports(.streams))
        #expect(!caps.supports(.resp3))
        #expect(caps[.unlink].reason?.contains("4.0") == true)
    }

    @Test func redis72HasModernFeaturesButNoHashFieldTTL() {
        let caps = Capabilities.derive(server: ServerInfo(family: .redis, version: ServerVersion(7, 2, 4), versionString: "7.2.4"))
        for feature: Capabilities.Feature in [.scan, .scanType, .unlink, .memoryUsage, .streams, .streamGroupLag, .resp3, .acl, .clientTracking, .clusterShards, .functions, .commandDocs] {
            #expect(caps.supports(feature), "\(feature)")
        }
        #expect(!caps.supports(.hashFieldTTL))
        let redis74 = Capabilities.derive(server: ServerInfo(family: .redis, version: ServerVersion(7, 4, 0), versionString: "7.4.0"))
        #expect(redis74.supports(.hashFieldTTL))
    }

    @Test func valkeyEightCountsAsModernRedis() {
        let caps = Capabilities.derive(server: ServerInfo(family: .valkey, version: ServerVersion(8, 0, 2), versionString: "8.0.2"))
        #expect(caps.supports(.functions))
        #expect(caps.supports(.clusterShards))
        #expect(!caps.supports(.hashFieldTTL))
    }

    @Test func commandListOverridesVersionTable() {
        var caps = Capabilities.derive(server: ServerInfo(family: .redis, version: ServerVersion(7, 2, 0), versionString: "7.2.0"))
        caps.apply(commandNames: ["get", "set", "scan", "info"]) // CONFIG renamed away, UNLINK missing
        #expect(!caps.supports(.config))
        #expect(!caps.supports(.unlink))
        #expect(caps.supports(.scan))
        #expect(caps[.config].reason?.contains("renamed or disabled") == true)
    }

    @Test func unknownVersionIsOptimisticUntilProven() {
        var caps = Capabilities.derive(server: .unknown)
        #expect(caps.supports(.unlink))
        caps.markUnavailable(.unlink, reason: "unknown command")
        #expect(!caps.supports(.unlink))
    }

    @Test func proxyDisablesAdminFeatures() {
        let caps = Capabilities.derive(server: .unknown, deployment: .proxy(.twemproxy))
        #expect(!caps.supports(.scan))
        #expect(!caps.supports(.info))
        #expect(!caps.supports(.select))
        #expect(caps[.scan].reason?.contains("twemproxy") == true)
    }
}

@Suite("Proxy detection")
struct ProxyDetectionTests {
    @Test func classification() {
        #expect(ProxyDetector.classify(infoError: .dropped, helloDropped: true) == .twemproxy)
        #expect(ProxyDetector.classify(infoError: .message("ERR unsupported command 'INFO'"), helloDropped: false) == .envoy)
        #expect(ProxyDetector.classify(infoError: .message("ERR handle request, command 'INFO' is not allowed"), helloDropped: false) == .codis)
        #expect(ProxyDetector.classify(infoError: .message("ERR forbid command"), helloDropped: false) == .predixy)
        #expect(ProxyDetector.classify(infoError: .message("ERR command not support"), helloDropped: false) == .cloud)
        #expect(ProxyDetector.classify(infoError: .message("ERR unknown command 'INFO'"), helloDropped: false) == .unknown)
    }

    @Test func infoTextHints() {
        #expect(ProxyDetector.flavor(fromInfo: InfoSnapshot.parse("# Proxy\nVersion:1.0.5\nMultiThread:true\n")) == .predixy)
        #expect(ProxyDetector.flavor(fromInfo: InfoSnapshot.parse("# Server\nredis_version:7.0.0\n")) == nil)
        #expect(ProxyDetector.flavor(fromInfo: InfoSnapshot.parse("# Server\nproxy_version:5.0\nredis_version:5.0.5\n")) == .cloud)
    }
}

@Suite("Hash slots")
struct HashSlotTests {
    @Test func knownVectors() {
        #expect(HashSlot.crc16(Array("123456789".utf8)) == 0x31C3)
        #expect(HashSlot.slot(for: RedisKey("foo")) == 12182)
        #expect(HashSlot.slot(for: RedisKey("bar")) == 5061)
        #expect(HashSlot.slot(for: RedisKey("")) == 0)
    }

    @Test func hashTags() {
        #expect(HashSlot.slot(for: RedisKey("{user1000}.following")) == HashSlot.slot(for: RedisKey("{user1000}.followers")))
        #expect(HashSlot.slot(for: RedisKey("{user1000}.x")) == HashSlot.slot(for: RedisKey("user1000")))
        // Empty tag hashes the whole key; only the first {…} counts.
        #expect(HashSlot.slot(for: RedisKey("foo{}{bar}")) == HashSlot.slot(bytes: Array("foo{}{bar}".utf8)))
        #expect(HashSlot.slot(for: RedisKey("foo{{bar}}zap")) == HashSlot.slot(bytes: Array("{bar".utf8)))
        #expect(HashSlot.slot(for: RedisKey("foo{bar}{zap}")) == HashSlot.slot(bytes: Array("bar".utf8)))
    }
}

@Suite("Cluster slot maps")
struct ClusterSlotMapTests {
    private let seed = Endpoint(host: "127.0.0.1", port: 17101)

    @Test func parsesClusterSlots() throws {
        let reply: RESPValue = .array([
            .array([.integer(0), .integer(5460), .array([.bulk("127.0.0.1"), .integer(17101), .bulk("id1")]), .array([.bulk("127.0.0.1"), .integer(17104), .bulk("id4")])]),
            .array([.integer(5461), .integer(10922), .array([.bulk(""), .integer(17102), .bulk("id2")])]),
            .array([.integer(10923), .integer(16383), .array([.bulk("127.0.0.1"), .integer(17103), .bulk("id3")])]),
        ])
        let map = try ClusterSlotMap(clusterSlots: reply, queriedNode: seed)
        #expect(map.masters.count == 3)
        #expect(map.isFullyCovered)
        #expect(map.master(forSlot: 0)?.endpoint == Endpoint(host: "127.0.0.1", port: 17101))
        // An empty host means "the node you asked".
        #expect(map.master(forSlot: 6000)?.endpoint == Endpoint(host: "127.0.0.1", port: 17102))
        #expect(map.replicas(ofMasterAt: Endpoint(host: "127.0.0.1", port: 17101)).map(\.endpoint) == [Endpoint(host: "127.0.0.1", port: 17104)])
    }

    @Test func parsesClusterShardsInRESP2AndRESP3() throws {
        func node(_ id: String, _ port: Int64, _ role: String) -> [RESPPair] {
            [RESPPair(.bulk("id"), .bulk(id)), RESPPair(.bulk("port"), .integer(port)), RESPPair(.bulk("ip"), .bulk("127.0.0.1")),
             RESPPair(.bulk("endpoint"), .bulk("127.0.0.1")), RESPPair(.bulk("role"), .bulk(role)), RESPPair(.bulk("health"), .bulk("online"))]
        }
        let resp3: RESPValue = .array([
            .map([RESPPair(.bulk("slots"), .array([.integer(0), .integer(8191)])),
                  RESPPair(.bulk("nodes"), .array([.map(node("a", 1, "master")), .map(node("b", 2, "replica"))]))]),
            .map([RESPPair(.bulk("slots"), .array([.integer(8192), .integer(16383)])),
                  RESPPair(.bulk("nodes"), .array([.map(node("c", 3, "master"))]))]),
        ])
        let map3 = try ClusterSlotMap(clusterShards: resp3, queriedNode: seed)
        #expect(map3.masters.map(\.id) == ["a", "c"])
        #expect(map3.isFullyCovered)
        #expect(map3.replicas(ofMasterAt: Endpoint(host: "127.0.0.1", port: 1)).count == 1)

        func flat(_ pairs: [RESPPair]) -> RESPValue { .array(pairs.flatMap { [$0.key, $0.value] }) }
        let resp2: RESPValue = .array([
            flat([RESPPair(.bulk("slots"), .array([.integer(0), .integer(16383)])),
                  RESPPair(.bulk("nodes"), .array([flat(node("a", 1, "master"))]))]),
        ])
        let map2 = try ClusterSlotMap(clusterShards: resp2, queriedNode: seed)
        #expect(map2.master(forSlot: 16383)?.id == "a")
    }

    @Test func parsesClusterNodes() throws {
        let text = """
        07c37dfeb235213a872192d90877d0cd55635b91 127.0.0.1:17104@27104 slave e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca 0 1426238317239 4 connected
        67ed2db8d677e59ec4a4cefb06858cf2a1a89fa1 127.0.0.1:17102@27102 master - 0 1426238316232 2 connected 5461-10922
        292f8b365bb7edb5e285caf0b7e6ddc7265d2f4f 127.0.0.1:17103@27103 master - 0 1426238318243 3 connected 10923-16383 [16000->-e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca]
        e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca 127.0.0.1:17101@27101,node-1.example myself,master - 0 0 1 connected 0-5460
        6ec23923021cf3ffec47632106199cb7f496ce01 :0@0 slave,fail,noaddr 67ed2db8d677e59ec4a4cefb06858cf2a1a89fa1 1426238317741 1426238316232 5 disconnected
        """
        let nodes = ClusterNodeInfo.parse(clusterNodes: text, queriedNode: seed)
        #expect(nodes.count == 5)
        let myself = try #require(nodes.first { $0.isMyself })
        #expect(myself.endpoint == Endpoint(host: "127.0.0.1", port: 17101))
        #expect(myself.hostname == "node-1.example")
        #expect(myself.slotRanges == [0...5460])
        #expect(myself.role == .master)
        let replica = try #require(nodes.first { $0.id.hasPrefix("07c37") })
        #expect(replica.role == .replica)
        #expect(replica.masterID == "e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca")
        let migrating = try #require(nodes.first { $0.id.hasPrefix("292f") })
        #expect(migrating.slotRanges == [10923...16383])
        #expect(migrating.migratingSlots == [16000])
        let failed = try #require(nodes.first { $0.id.hasPrefix("6ec2") })
        #expect(failed.isFailing)
        #expect(failed.endpoint == nil)
        let map = try ClusterSlotMap(clusterNodes: nodes)
        #expect(map.isFullyCovered)
        #expect(map.master(forSlot: 100)?.id == "e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca")
        #expect(map.replicas(ofMasterAt: Endpoint(host: "127.0.0.1", port: 17101)).count == 1)
    }

    @Test func uncoveredSlotsAreReported() throws {
        let reply: RESPValue = .array([.array([.integer(0), .integer(100), .array([.bulk("127.0.0.1"), .integer(1)])])])
        let map = try ClusterSlotMap(clusterSlots: reply, queriedNode: seed)
        #expect(!map.isFullyCovered)
        #expect(map.uncoveredSlotCount == 16384 - 101)
        #expect(map.master(forSlot: 200) == nil)
    }

    @Test func redirectParsing() {
        #expect(Redirect(message: "MOVED 3999 127.0.0.1:6381") == .moved(slot: 3999, Endpoint(host: "127.0.0.1", port: 6381)))
        #expect(Redirect(message: "ASK 3999 10.0.0.2:6380") == .ask(slot: 3999, Endpoint(host: "10.0.0.2", port: 6380)))
        #expect(Redirect(message: "MOVED 1 [::1]:7000") == .moved(slot: 1, Endpoint(host: "::1", port: 7000)))
        #expect(Redirect(message: "MOVED 1 :7000", fallbackHost: "10.1.1.1") == .moved(slot: 1, Endpoint(host: "10.1.1.1", port: 7000)))
        #expect(Redirect(message: "ERR foo") == nil)
        #expect(Redirect(message: "MOVED x y") == nil)
    }
}

@Suite("Address mapping")
struct AddressMapTests {
    @Test func exactAndHostRules() throws {
        let map = try AddressMap(rules: "172.18.0.5:6379 => 127.0.0.1:17101\n10.0.0.0 => 127.0.0.1\n# comment\n")
        #expect(map.resolve(Endpoint(host: "172.18.0.5", port: 6379)) == Endpoint(host: "127.0.0.1", port: 17101))
        #expect(map.resolve(Endpoint(host: "10.0.0.0", port: 7001)) == Endpoint(host: "127.0.0.1", port: 7001))
        #expect(map.resolve(Endpoint(host: "192.168.1.1", port: 1)) == Endpoint(host: "192.168.1.1", port: 1))
        #expect(map.rules.count == 2)
    }

    @Test func invalidRulesAreRejected() {
        #expect(throws: RedisError.self) { try AddressMap(rules: "nonsense") }
        #expect(throws: RedisError.self) { try AddressMap(rules: "a:1 => b:notaport") }
    }

    @Test func endpointParsing() {
        #expect(Endpoint.parse("127.0.0.1:7000") == Endpoint(host: "127.0.0.1", port: 7000))
        #expect(Endpoint.parse("cache.example.com") == Endpoint(host: "cache.example.com", port: 6379))
        #expect(Endpoint.parse("[::1]:6380") == Endpoint(host: "::1", port: 6380))
        #expect(Endpoint.parse("::1") == Endpoint(host: "::1", port: 6379))
        #expect(Endpoint.parse("/tmp/redis.sock")?.isUnixSocket == true)
        #expect(Endpoint.parse("host:99999") == nil)
        #expect(Endpoint.parse("") == nil)
    }
}

@Suite("Command specs")
struct CommandSpecTests {
    @Test func keyPositions() {
        func keys(_ words: [String]) -> [String] {
            let command = RedisCommand(rawArguments: words.map { Array($0.utf8) })
            guard let spec = CommandSpecs.spec(for: command) else { return [] }
            return spec.keyIndices(in: command.arguments).map { words[$0] }
        }
        #expect(keys(["GET", "a"]) == ["a"])
        #expect(keys(["MSET", "a", "1", "b", "2"]) == ["a", "b"])
        #expect(keys(["DEL", "a", "b", "c"]) == ["a", "b", "c"])
        #expect(keys(["BLPOP", "a", "b", "0"]) == ["a", "b"])
        #expect(keys(["EVAL", "return 1", "2", "k1", "k2", "arg"]) == ["k1", "k2"])
        #expect(keys(["ZUNIONSTORE", "dest", "2", "z1", "z2", "WEIGHTS", "1", "2"]) == ["dest", "z1", "z2"])
        #expect(keys(["XREAD", "COUNT", "2", "STREAMS", "s1", "s2", "0", "0"]) == ["s1", "s2"])
        #expect(keys(["OBJECT", "ENCODING", "k"]) == ["k"])
        #expect(keys(["MEMORY", "USAGE", "k", "SAMPLES", "0"]) == ["k"])
        #expect(keys(["PING"]) == [])
        #expect(keys(["EVAL", "x", "999", "k"]) == ["k"]) // clamped to available arguments
    }

    @Test func flags() {
        #expect(CommandSpecs.spec(for: RedisCommand("SET", ["a", "1"]))?.isWrite == true)
        #expect(CommandSpecs.spec(for: RedisCommand("GET", ["a"]))?.isWrite == false)
        #expect(CommandSpecs.spec(for: RedisCommand("FLUSHALL"))?.flags.contains(.dangerous) == true)
        #expect(CommandSpecs.spec(for: RedisCommand("CONFIG", ["SET", "x", "y"]))?.flags.contains(.dangerous) == true)
        #expect(CommandSpecs.spec(for: RedisCommand("config", ["get", "x"]))?.flags.contains(.dangerous) == false)
        #expect(CommandSpecs.spec(for: RedisCommand("SUBSCRIBE", ["c"]))?.flags.contains(.streaming) == true)
        #expect(CommandSpecs.spec(for: RedisCommand("DBSIZE"))?.flags.contains(.allMasters) == true)
        #expect(CommandSpecs.table.count > 300)
    }
}
