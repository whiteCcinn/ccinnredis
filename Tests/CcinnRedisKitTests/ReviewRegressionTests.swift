import Foundation
import os
import RedisKit
import RESPWire
import Testing
@testable import CcinnRedisKit

/// Regression tests for findings of the adversarial review (CcinnRedisKit layer).

private func command(_ line: String) throws -> RedisCommand {
    RedisCommand(rawArguments: try CLITokenizer.tokenize(line))
}

private final class MutableProfiles: MCPProfileSource, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(profiles: [ConnectionProfile], secrets: ProfileSecrets)>
    init(_ profiles: [ConnectionProfile]) { state = OSAllocatedUnfairLock(initialState: (profiles, ProfileSecrets())) }
    func profiles() -> [ConnectionProfile] { state.withLock { $0.profiles } }
    func secrets(for profile: ConnectionProfile) -> ProfileSecrets { state.withLock { $0.secrets } }
    func update(_ change: (inout [ConnectionProfile]) -> Void) { state.withLockUnchecked { change(&$0.profiles) } }
    func setSecrets(_ secrets: ProfileSecrets) { state.withLock { $0.secrets = secrets } }
}

private func backend(commands: OSAllocatedUnfairLock<[String]>? = nil) -> FakeRedisBackend {
    FakeRedisBackend { request in
        commands?.withLock { $0.append(request.arguments.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")) }
        switch request.name {
        case "HELLO": return .reply(.map([RESPPair(.bulkString(Array("server".utf8)), .bulkString(Array("redis".utf8))),
                                          RESPPair(.bulkString(Array("version".utf8)), .bulkString(Array("7.2.4".utf8))),
                                          RESPPair(.bulkString(Array("proto".utf8)), .integer(3)),
                                          RESPPair(.bulkString(Array("mode".utf8)), .bulkString(Array("standalone".utf8))),
                                          RESPPair(.bulkString(Array("role".utf8)), .bulkString(Array("master".utf8)))]))
        case "INFO": return .reply(.bulkString(Array("# Server\r\nredis_version:7.2.4\r\nredis_mode:standalone\r\n".utf8)))
        case "COMMAND", "MODULE": return .reply(.array([]))
        case "SCAN": return .reply(.array([.bulkString(Array("0".utf8)), .array([.bulkString(Array("l".utf8))])]))
        case "TYPE": return .reply(.simpleString("list"))
        case "PTTL": return .reply(.integer(-1))
        case "LRANGE": return .reply(.array([]))
        case "LLEN": return .reply(.integer(0))
        case "SLOWLOG":
            let entry: RESPValue = .array([.integer(1), .integer(1_700_000_000), .integer(20_000),
                                           .array(["CONFIG", "SET", "requirepass", "hunter2"].map { .bulkString(Array($0.utf8)) }),
                                           .bulkString(Array("127.0.0.1:5000".utf8)), .bulkString(Array("".utf8))])
            return .reply(.array([entry]))
        case "SET": return .reply(.simpleString("OK"))
        default: return .reply(.error("ERR unknown command '\(request.name)'"))
        }
    }
}

@Suite("Review regressions: MCP")
struct MCPReviewRegressionTests {
    // Finding 1: integer arguments are bounded by their schema; huge offsets never trap.
    @Test func integerArgumentsAreBounded() async {
        let schema = MCPSchema.object(properties: ["n": MCPSchema.integer("n", minimum: 0, maximum: 10)])
        #expect(MCPSchema.validate(["n": .int(11)], against: schema) != nil)
        #expect(MCPSchema.validate(["n": .int(-1)], against: schema) != nil)
        #expect(MCPSchema.validate(["n": .double(1e300)], against: schema) != nil)
        #expect(MCPSchema.validate(["n": .int(10)], against: schema) == nil)

        var profile = ConnectionProfile(name: "p")
        profile.mcpAccess = .readOnly
        let fake = backend()
        let tools = RedisMCPToolbox(profiles: MutableProfiles([profile]),
                                    clientFactory: { try await RedisClient.connect($0, connector: fake.connector) })
        let result = await tools.call(name: "get_key", arguments: ["key": .string("l"), "offset": .int(Int64.max)])
        #expect(result.isError)
        #expect(result.payload.compactString.contains("at most"))
        await tools.shutdown()
    }

    // Finding 9: reads must be bounded.
    @Test func unboundedReadsAreDenied() throws {
        func allowed(_ line: String) throws -> Bool {
            let parsed = try command(line)
            return MCPCommandPolicy.check(parsed, spec: CommandSpecs.spec(for: parsed)) == .allowed
        }
        for line in ["HGETALL h", "HKEYS h", "HVALS h", "SMEMBERS s", "SUNION a b", "SINTER a b", "SDIFF a b", "ZUNION 2 a b", "ZINTER 2 a b",
                     "ZDIFF 2 a b", "SCAN 0 COUNT 100000", "HSCAN h 0 COUNT 5000", "LRANGE l 0 -1", "LRANGE l 0 5000", "ZRANGE z 0 -1",
                     "ZRANGE z -inf +inf BYSCORE", "ZRANGE z 0 10 BYSCORE LIMIT 0 -1", "ZRANGEBYSCORE z -inf +inf", "ZREVRANGE z 0 -1",
                     "XRANGE s - +", "XRANGE s - + COUNT 100000", "XREVRANGE s + -", "XREAD STREAMS s 0", "XINFO STREAM s FULL COUNT 0",
                     "SRANDMEMBER s -100000", "HRANDFIELD h 9223372036854775807", "ZRANDMEMBER z -9223372036854775808", "LPOS l x COUNT 0",
                     "SORT_RO l", "MEMORY USAGE k SAMPLES 0", "XPENDING s g - + 100000", "LRANGE l -9223372036854775808 -1"] {
            #expect(try allowed(line) == false, "\(line) must be denied")
        }
        for line in ["LRANGE l 0 99", "LRANGE l -100 -1", "ZRANGE z 0 9 WITHSCORES", "ZRANGE z -inf +inf BYSCORE LIMIT 0 50",
                     "ZRANGEBYSCORE z -inf +inf LIMIT 0 10", "XRANGE s - + COUNT 10", "XREAD COUNT 5 STREAMS s 0", "XINFO STREAM s FULL",
                     "SRANDMEMBER s 5", "HSCAN h 0 COUNT 100", "SCAN 0 MATCH a* COUNT 1000", "SORT_RO l LIMIT 0 10", "MEMORY USAGE k",
                     "XPENDING s g", "XPENDING s g - + 10", "LPOS l x COUNT 3"] {
            #expect(try allowed(line), "\(line) must be allowed")
        }
    }

    // Finding 10: edited profiles/secrets replace the cached client; the write gate honours profile.readOnly.
    @Test func editedProfilesReplaceCachedClients() async {
        var profile = ConnectionProfile(name: "p")
        profile.mcpAccess = .readWrite
        let source = MutableProfiles([profile])
        let connects = OSAllocatedUnfairLock(initialState: 0)
        let fake = backend()
        let tools = RedisMCPToolbox(profiles: source, clientFactory: { configuration in
            connects.withLock { $0 += 1 }
            return try await RedisClient.connect(configuration, connector: fake.connector)
        })
        #expect(await tools.call(name: "scan_keys", arguments: [:]).isError == false)
        #expect(await tools.call(name: "scan_keys", arguments: [:]).isError == false)
        #expect(connects.withLock { $0 } == 1)

        source.setSecrets(ProfileSecrets(password: "new"))
        #expect(await tools.call(name: "scan_keys", arguments: [:]).isError == false)
        #expect(connects.withLock { $0 } == 2)
        #expect(await tools.cachedClientCount == 1)

        source.update { $0[0].readOnly = true }
        #expect(await tools.call(name: "set_string", arguments: ["key": .string("k"), "value": .string("v")]).isError)
        #expect(!(await tools.tools()).contains { $0.name == "set_string" })
        #expect(await tools.call(name: "scan_keys", arguments: [:]).isError == false)
        #expect(connects.withLock { $0 } == 3)
        await tools.shutdown()
    }

    // Finding 17: SLOWLOG GET arguments are redacted in run_command replies.
    @Test func slowlogArgumentsAreRedacted() async {
        var profile = ConnectionProfile(name: "p")
        profile.mcpAccess = .readOnly
        let fake = backend()
        let tools = RedisMCPToolbox(profiles: MutableProfiles([profile]),
                                    clientFactory: { try await RedisClient.connect($0, connector: fake.connector) })
        let result = await tools.call(name: "run_command", arguments: ["command": .string("SLOWLOG GET 10")])
        #expect(result.isError == false)
        #expect(!result.payload.compactString.contains("hunter2"))
        #expect(result.payload.compactString.contains("requirepass"))
        await tools.shutdown()
    }

    // Finding 19: concurrent writers (separate processes) share the audit log; rotation keeps every line intact.
    @Test func auditLogSurvivesConcurrentWritersAndRotation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = (0..<3).map { _ in MCPAuditLog(directory: directory) }
        await withTaskGroup(of: Void.self) { group in
            for (index, log) in logs.enumerated() {
                group.addTask {
                    for call in 0..<200 {
                        await log.record(connection: "c\(index)", tool: "run_command", command: "GET k\(call)", key: nil,
                                         duration: .milliseconds(1), items: nil, error: nil)
                    }
                }
            }
        }
        for log in logs { await log.close() }
        let text = try String(contentsOf: directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 600)
        #expect(lines.allSatisfy { (try? JSONValue.decode(Data($0.utf8))) != nil })
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("mcp-audit.jsonl").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite("Review regressions: console and values")
struct ConsoleReviewRegressionTests {
    // Finding 8: database tracking only trusts OK replies and understands transactions.
    @Test func databaseTrackingFollowsReplies() throws {
        var state = ConsoleSessionState(database: 0)
        state.apply(try command("SELECT 3"), reply: .error("ERR DB index is out of range"))
        #expect(state.database == 0)
        state.apply(try command("SELECT 3"), reply: .simpleString("OK"))
        #expect(state.database == 3)
        state.apply(try command("MULTI"), reply: .simpleString("OK"))
        state.apply(try command("SELECT 5"), reply: .simpleString("QUEUED"))
        state.apply(try command("SET a 1"), reply: .simpleString("QUEUED"))
        #expect(state.database == 3) // not yet executed
        state.apply(try command("EXEC"), reply: .array([.simpleString("OK"), .simpleString("OK")]))
        #expect(state.database == 5)
        #expect(!state.inTransaction)
        state.apply(try command("MULTI"), reply: .simpleString("OK"))
        state.apply(try command("SELECT 7"), reply: .simpleString("QUEUED"))
        state.apply(try command("DISCARD"), reply: .simpleString("OK"))
        #expect(state.database == 5)
        state.apply(try command("MULTI"), reply: .simpleString("OK"))
        state.apply(try command("SELECT 7"), reply: .simpleString("QUEUED"))
        state.apply(try command("EXEC"), reply: .null) // WATCH aborted
        #expect(state.database == 5)
        state.apply(try command("RESET"), reply: .simpleString("RESET"))
        #expect(state.database == 0)
        state.apply(try command("SELECT x"), reply: .simpleString("OK"))
        #expect(state.database == nil)
    }

    @Test func flushdbWithUnknownDatabaseNeedsTheConnectionName() throws {
        let assessment = CommandSafety.assess(try command("FLUSHDB"), database: nil, connectionName: "prod")
        guard case let .typedConfirmation(expected, _) = assessment else {
            Issue.record("expected typed confirmation")
            return
        }
        #expect(expected == "prod")
        // The client's spec (e.g. a module command marked @dangerous) is honoured.
        let spec = CommandSpec(name: "MOD.WIPE", arity: -1, flags: [.write, .dangerous], keys: .none, since: ServerVersion(1), group: "module")
        guard case .confirmation = CommandSafety.assess(try command("MOD.WIPE all"), database: 0, connectionName: "x", spec: spec) else {
            Issue.record("expected confirmation")
            return
        }
    }

    // Finding 17: Sentinel secrets are redacted in history.
    @Test func sentinelSecretsAreRedacted() {
        let set = ConsoleHistory.redact("SENTINEL SET mymaster auth-pass hunter2 quorum 2")
        #expect(!set.contains("hunter2"))
        #expect(set.contains("quorum"))
        #expect(!ConsoleHistory.redact("SENTINEL SET mymaster auth-user admin").contains("admin"))
        #expect(!ConsoleHistory.redact("SENTINEL CONFIG SET sentinel-pass s3cret").contains("s3cret"))
        #expect(ConsoleHistory.redact("SENTINEL MASTERS") == "SENTINEL MASTERS")
        let arguments = ConsoleHistory.redact(arguments: ["AUTH", "user", "pw"].map { Array($0.utf8) })
        #expect(arguments.map { String(decoding: $0, as: UTF8.self) } == ["AUTH", "user", "••••"])
        #expect(SecretConfig.isSecret("masterauth") && SecretConfig.isSecret("tls-key-file-pass") && !SecretConfig.isSecret("maxmemory"))
    }

    // Finding 7: blank names never crash the catalogue.
    @Test func catalogIgnoresBlankNames() {
        let blank = CommandSpec(name: "", arity: 1, flags: [], keys: .none, since: ServerVersion(1), group: "module")
        let catalog = CommandCatalog(serverVersion: ServerVersion(7, 2, 0), family: .redis, extra: [blank])
        #expect(!catalog.commandNames.contains(""))
    }

    // Finding 16: compact hex keeps its first 8-digit token; hexdump offsets are still dropped.
    @Test func hexParsingOnlyDropsHexdumpOffsets() throws {
        #expect(try ValueFormatter.parse("deadbeef cafe", as: .hex) == [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        #expect(try ValueFormatter.parse("00000000  48 69  |Hi|", as: .hex) == [0x48, 0x69])
        let dump = ValueFormatter.hexDump(Array("Hello, CcinnRedis!".utf8))
        #expect(try ValueFormatter.parse(dump, as: .hex) == Array("Hello, CcinnRedis!".utf8))
    }

    @Test func compactJSONStaysCompact() throws {
        let original = Array(#"{"a":1,"b":[1,2]}"#.utf8)
        #expect(ValueFormatter.isCompactJSON(original))
        let pretty = try #require(JSONPrettyPrinter.format(String(decoding: original, as: UTF8.self)))
        #expect(try ValueFormatter.parse(pretty, as: .json, compactJSON: true) == original)
        #expect(try ValueFormatter.parse(pretty, as: .json, compactJSON: false) == Array(pretty.utf8))
    }

    // Finding 20: the raw formatter honours the element budget for maps.
    @Test func rawFormatterBudgetsMaps() {
        let map = RESPValue.map((0..<10_000).map { RESPPair(.bulkString(Array("k\($0)".utf8)), .integer(Int64($0))) })
        let text = ReplyFormatter.format(map, style: .raw, limits: ReplyFormatter.Limits(maxElements: 10))
        #expect(text.split(separator: "\n").count < 40)
        #expect(text.contains("more"))
    }

    // Finding 5: server numbers never trap.
    @Test func safeNumbersClamp() {
        #expect(SafeNumber.int(Double.nan) == nil)
        #expect(SafeNumber.int(Double.infinity) == Int.max)
        #expect(SafeNumber.int(-1e300) == Int.min)
        #expect(SafeNumber.int("nan") == nil)
        #expect(SafeNumber.int("12") == 12)
        #expect(SafeNumber.int("1e30") == Int.max)
        #expect(SafeNumber.sum([Int64.max, 1, 5]) == Int64.max)
        #expect(SafeNumber.finite(.infinity) == nil)
        #expect(SafeNumber.seconds(.nan) == 0)
    }

    // Finding 12: live output keeps a bounded ring.
    @Test func ringBufferKeepsTheNewest() {
        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1...7 { ring.append(value) }
        #expect(ring.elements == [5, 6, 7])
        #expect(ring.count == 3)
        ring.removeAll()
        #expect(ring.isEmpty)
    }
}

@Suite("Review regressions: analysis")
struct AnalysisReviewRegressionTests {
    // Finding 18: empty SCAN pages are paced too.
    @Test func rateLimiterPacesEmptyBatches() {
        var limiter = RateLimiter(perSecond: 100)
        let delay = limiter.delay(afterConsuming: 200, elapsed: 0)
        #expect(delay >= .seconds(1))
        var huge = RateLimiter(perSecond: 1)
        #expect(huge.delay(afterConsuming: Int.max, elapsed: 0) <= .seconds(60))
        #expect(huge.delay(afterConsuming: Int.max, elapsed: 0) <= .seconds(60))
    }
}
