import Foundation
import os
import RedisKit
import RESPWire
import Testing
@testable import CcinnRedisKit

// MARK: - Helpers

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// Collects server output lines.
private final class OutputSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
    var lines: [String] { lock.withLock { $0 } }
    var writer: MCPServer.Output { { [self] data in lock.withLock { $0.append(String(decoding: data, as: UTF8.self)) } } }

    func messages() throws -> [JSONValue] { try lines.map { try json($0) } }

    func waitForLines(_ count: Int) async {
        for _ in 0..<200 where lines.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Toolbox stub: an echo tool, a failing tool and a slow, cancellable tool.
private final class StubToolbox: MCPToolbox, @unchecked Sendable {
    let cancelled = OSAllocatedUnfairLock(initialState: false)

    func tools() async -> [MCPToolDefinition] {
        [
            MCPToolDefinition(name: "echo", title: "Echo", description: "Echoes text",
                              inputSchema: MCPSchema.object(properties: ["text": MCPSchema.string("Text to echo")], required: ["text"]),
                              readOnly: true),
            MCPToolDefinition(name: "fail", title: "Fail", description: "Always fails", inputSchema: MCPSchema.object(properties: [:]), readOnly: true),
            MCPToolDefinition(name: "slow", title: "Slow", description: "Sleeps", inputSchema: MCPSchema.object(properties: [:]), readOnly: true),
        ]
    }

    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        switch name {
        case "echo": return MCPToolResult(payload: .object(["text": arguments["text"] ?? .null]))
        case "fail": return .error("Connection refused by 127.0.0.1:1")
        default:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
            }
            return MCPToolResult(payload: .object(["done": .bool(true)]))
        }
    }
}

private func makeServer(_ toolbox: any MCPToolbox = StubToolbox(), sink: OutputSink) -> MCPServer {
    MCPServer(name: "ccinnredis", title: "CcinnRedis", version: "1.0.0", instructions: "test", toolbox: toolbox, output: sink.writer)
}

// MARK: - Framing and JSON

@Suite("MCP framing")
struct MCPFramingTests {
    @Test func splitsLinesAcrossChunks() {
        var framer = MCPLineFramer(maxLineBytes: 100)
        #expect(framer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [.line(Data("{\"a\":1}".utf8))])
        #expect(framer.append(Data(":2}\r\n\n".utf8)) == [.line(Data("{\"b\":2}".utf8))])
    }

    @Test func oversizedLinesAreRejectedOnceAndSkipped() {
        var framer = MCPLineFramer(maxLineBytes: 10)
        #expect(framer.append(Data(String(repeating: "x", count: 25).utf8)) == [.oversized])
        #expect(framer.append(Data("yyyy\n{}\n".utf8)) == [.line(Data("{}".utf8))])
    }

    @Test func jsonValueRoundTrips() throws {
        let value = try json(#"{"a":[1,2.5,true,null,"x"],"b":{"c":-3}}"#)
        #expect(value["a"]?.array?.count == 5)
        #expect(value["a"]?.array?[0] == .int(1))
        #expect(value["a"]?.array?[1] == .double(2.5))
        #expect(value["a"]?.array?[2] == .bool(true))
        #expect(value["b"]?["c"]?.int == -3)
        let encoded = value.compactString
        #expect(!encoded.contains("\n"))
        #expect(try json(encoded) == value)
        #expect(JSONValue.string("line\nbreak").compactString == #""line\nbreak""#)
    }
}

// MARK: - Protocol

@Suite("MCP protocol")
struct MCPProtocolTests {
    @Test func initializeNegotiatesVersions() async throws {
        for (requested, expected) in [("2025-03-26", "2025-03-26"), ("2024-11-05", "2024-11-05"), ("1999-01-01", "2025-06-18")] {
            let sink = OutputSink()
            let server = makeServer(sink: sink)
            await server.receive(line: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8))
            let reply = try #require(try sink.messages().first)
            #expect(reply["id"] == .int(1))
            #expect(reply["result"]?["protocolVersion"]?.string == expected)
            #expect(reply["result"]?["serverInfo"]?["name"]?.string == "ccinnredis")
            #expect(reply["result"]?["capabilities"]?["tools"] != nil)
            #expect(reply["result"]?["capabilities"]?["resources"] == nil)
        }
    }

    @Test func listsToolsWithSchemasAndAnnotations() async throws {
        let sink = OutputSink()
        let server = makeServer(sink: sink)
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#.utf8))
        let tools = try #require(try sink.messages().first?["result"]?["tools"]?.array)
        #expect(tools.count == 3)
        let echo = try #require(tools.first)
        #expect(echo["inputSchema"]?["type"]?.string == "object")
        #expect(echo["inputSchema"]?["additionalProperties"] == .bool(false))
        #expect(echo["inputSchema"]?["required"]?.array == [.string("text")])
        #expect(echo["annotations"]?["readOnlyHint"] == .bool(true))
        #expect(echo["annotations"]?["openWorldHint"] == .bool(false))
    }

    @Test func callsToolsAndMapsFailuresToIsError() async throws {
        let sink = OutputSink()
        let server = makeServer(sink: sink)
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fail","arguments":{}}}"#.utf8))
        await sink.waitForLines(3)
        let messages = try sink.messages()
        let echo = try #require(messages.first { $0["id"] == .int(2) })
        #expect(echo["result"]?["isError"] == .bool(false))
        #expect(echo["result"]?["structuredContent"]?["text"]?.string == "hi")
        let text = try #require(echo["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(try json(text)["text"]?.string == "hi")
        let failure = try #require(messages.first { $0["id"] == .int(3) })
        #expect(failure["result"]?["isError"] == .bool(true))
        #expect(failure["result"]?["content"]?.array?.first?["text"]?.string?.contains("Connection refused") == true)
        #expect(failure["error"] == nil)
    }

    @Test func olderProtocolVersionsGetNoStructuredContent() async throws {
        let sink = OutputSink()
        let server = makeServer(sink: sink)
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#.utf8))
        await sink.waitForLines(2)
        let reply = try #require(try sink.messages().first { $0["id"] == .int(2) })
        #expect(reply["result"]?["structuredContent"] == nil)
    }

    @Test func protocolErrors() async throws {
        let sink = OutputSink()
        let server = makeServer(sink: sink)
        await server.receive(line: Data("{not json".utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":5,"method":"nope"}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"missing"}}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"arguments":{}}}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#.utf8))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":10,"method":"prompts/list"}"#.utf8))
        await server.receiveOversizedLine()
        await sink.waitForLines(8)
        let messages = try sink.messages()
        #expect(messages.contains { $0["error"]?["code"] == .int(-32700) })
        #expect(messages.first { $0["id"] == .int(5) }?["error"]?["code"] == .int(-32601))
        #expect(messages.first { $0["id"] == .int(6) }?["error"]?["code"] == .int(-32602))
        #expect(messages.first { $0["id"] == .int(7) }?["error"]?["code"] == .int(-32602))
        #expect(messages.first { $0["id"] == .int(8) }?["result"] == .object([:]))
        #expect(messages.first { $0["id"] == .int(9) }?["result"]?["resources"] == .array([]))
        #expect(messages.first { $0["id"] == .int(10) }?["result"]?["prompts"] == .array([]))
        #expect(messages.filter { $0["error"]?["code"] == .int(-32700) }.count == 2) // bad JSON + oversized
        // Notifications get no reply.
        #expect(messages.count == 8)
    }

    @Test func cancellationStopsTheToolAndSuppressesTheReply() async throws {
        let sink = OutputSink()
        let toolbox = StubToolbox()
        let server = makeServer(toolbox, sink: sink)
        await server.receive(line: Data(#"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#.utf8))
        try await Task.sleep(for: .milliseconds(50))
        await server.receive(line: Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"user"}}"#.utf8))
        for _ in 0..<100 where !toolbox.cancelled.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(toolbox.cancelled.withLock { $0 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(try sink.messages().contains { $0["id"] == .int(42) } == false)
        await server.waitForIdle()
    }
}

// MARK: - Read-only policy

@Suite("MCP read-only command policy")
struct MCPPolicyTests {
    private func verdict(_ line: String) throws -> Bool {
        let command = RedisCommand(rawArguments: try CLITokenizer.tokenize(line))
        if case .allowed = MCPCommandPolicy.check(command, spec: CommandSpecs.spec(for: command)) { return true }
        return false
    }

    @Test func readsAreAllowed() throws {
        for line in ["GET a", "get a", "HGETALL h", "TYPE k", "TTL k", "SCAN 0 MATCH x* COUNT 10", "ZRANGE z 0 10 WITHSCORES", "XRANGE s - + COUNT 5",
                     "INFO memory", "DBSIZE", "MEMORY USAGE k", "OBJECT ENCODING k", "SLOWLOG GET 10", "CLIENT LIST", "CONFIG GET maxmemory",
                     "CLUSTER NODES", "CLUSTER SLOTS", "PING", "JSON.GET doc", "PUBSUB CHANNELS", "COMMAND COUNT", "ROLE", "SORT_RO l", "XREAD COUNT 1 STREAMS s 0"] {
            #expect(try verdict(line), "\(line) should be allowed")
        }
    }

    @Test func writesAndDangerousCommandsAreDenied() throws {
        for line in ["SET a 1", "DEL a", "FLUSHALL", "FLUSHDB ASYNC", "CONFIG SET maxmemory 1", "CONFIG REWRITE", "DEBUG SLEEP 0", "SHUTDOWN",
                     "MONITOR", "SUBSCRIBE c", "PSUBSCRIBE *", "KEYS *", "EVAL \"return 1\" 0", "EVAL_RO \"return 1\" 0", "SCRIPT FLUSH",
                     "CLIENT KILL ID 1", "CLIENT PAUSE 100", "SLOWLOG RESET", "ACL LIST", "ACL GETUSER default", "AUTH pw", "SELECT 1",
                     "MULTI", "WATCH k", "SORT l STORE x", "BLPOP q 0", "XREAD BLOCK 0 STREAMS s $", "PUBLISH c m", "MIGRATE h 1 k 0 1",
                     "SWAPDB 0 1", "CLUSTER RESET", "REPLICAOF NO ONE", "UNKNOWNCMD x", "JSON.SET k . 1", "FT.CREATE idx SCHEMA a TEXT", "WAIT 1 0"] {
            #expect(try verdict(line) == false, "\(line) should be denied")
        }
    }

    @Test func configGetRepliesAreRedacted() {
        let reply = RESPValue.array([.bulkString(Array("requirepass".utf8)), .bulkString(Array("hunter2".utf8)),
                                     .bulkString(Array("maxmemory".utf8)), .bulkString(Array("0".utf8)),
                                     .bulkString(Array("masterauth".utf8)), .bulkString(Array("x".utf8))])
        let redacted = MCPCommandPolicy.redact(reply, for: RedisCommand("CONFIG", ["GET", "*"]))
        let text = ReplyFormatter.format(redacted)
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("\"x\""))
        #expect(text.contains("\"0\""))
    }
}

// MARK: - Limits and values

@Suite("MCP limits")
struct MCPLimitTests {
    @Test func respValuesBecomeBoundedJSON() {
        let value = RESPValue.array([.bulkString(Array("text".utf8)), .bulkString([0xFF, 0x00]), .integer(3), .null, .double(1.5),
                                     .map([RESPPair(.bulkString(Array("k".utf8)), .boolean(true))])])
        let converted = MCPValueEncoder.json(value, limits: MCPLimits(maxItems: 100, maxStringBytes: 100))
        #expect(converted.value.array?[0] == .string("text"))
        #expect(converted.value.array?[1]["base64"]?.string == Data([0xFF, 0x00]).base64EncodedString())
        #expect(converted.value.array?[2] == .int(3))
        #expect(converted.value.array?[3] == .null)
        #expect(converted.value.array?[5]["k"] == .bool(true))
        #expect(!converted.truncated)

        let big = RESPValue.array((0..<500).map { .integer(Int64($0)) })
        let clipped = MCPValueEncoder.json(big, limits: MCPLimits(maxItems: 10, maxStringBytes: 100))
        #expect(clipped.value.array?.count == 10)
        #expect(clipped.truncated)
        let long = MCPValueEncoder.json(.bulkString(Array(repeating: 0x61, count: 1000)), limits: MCPLimits(maxItems: 10, maxStringBytes: 100))
        #expect(long.value.string?.count == 100)
        #expect(long.truncated)
    }

    @Test func oversizedResultsAreTrimmedAndFlagged() {
        let items = (0..<5000).map { JSONValue.string("item-\($0)-" + String(repeating: "x", count: 100)) }
        let fitted = MCPResultFitter.fit(.object(["keys": .array(items), "complete": .bool(true)]), maxBytes: 16 * 1024)
        #expect(fitted.compactString.utf8.count <= 16 * 1024)
        #expect(fitted["truncated"] == .bool(true))
        #expect((fitted["keys"]?.array?.count ?? 0) > 0)
        let small = MCPResultFitter.fit(.object(["a": .int(1)]), maxBytes: 1024)
        #expect(small["truncated"] == nil)
    }

    @Test func limitArgumentIsClamped() {
        #expect(MCPLimits.itemLimit(nil) == 200)
        #expect(MCPLimits.itemLimit(.int(5)) == 5)
        #expect(MCPLimits.itemLimit(.int(1_000_000)) == 1000)
        #expect(MCPLimits.itemLimit(.int(-3)) == 1)
        #expect(MCPLimits.timeout(nil) == 30)
        #expect(MCPLimits.timeout(.int(500)) == 120)
    }
}

// MARK: - Profiles and the Redis toolbox

private final class StaticProfiles: MCPProfileSource, @unchecked Sendable {
    let all: [ConnectionProfile]
    init(_ all: [ConnectionProfile]) { self.all = all }
    func profiles() -> [ConnectionProfile] { all }
    func secrets(for profile: ConnectionProfile) -> ProfileSecrets { ProfileSecrets() }
}

private func profile(_ name: String, _ access: MCPAccess, port: Int = 6379) -> ConnectionProfile {
    var profile = ConnectionProfile(name: name, port: port)
    profile.mcpAccess = access
    return profile
}

@Suite("MCP Redis tools")
struct RedisMCPToolTests {
    private func keyspaceBackend() -> FakeRedisBackend {
        FakeRedisBackend { request in
            switch request.name {
            case "HELLO": return .reply(.map([RESPPair(.bulkString(Array("server".utf8)), .bulkString(Array("redis".utf8))),
                                              RESPPair(.bulkString(Array("version".utf8)), .bulkString(Array("7.2.4".utf8))),
                                              RESPPair(.bulkString(Array("proto".utf8)), .integer(3)),
                                              RESPPair(.bulkString(Array("mode".utf8)), .bulkString(Array("standalone".utf8))),
                                              RESPPair(.bulkString(Array("role".utf8)), .bulkString(Array("master".utf8)))]))
            case "INFO": return .reply(.bulkString(Array("# Server\r\nredis_version:7.2.4\r\nredis_mode:standalone\r\n# Keyspace\r\ndb0:keys=3,expires=0,avg_ttl=0\r\n".utf8)))
            case "COMMAND", "MODULE": return .reply(.array([]))
            case "SCAN": return .reply(.array([.bulkString(Array("0".utf8)), .array(["user:1", "user:2", "cfg"].map { .bulkString(Array($0.utf8)) })]))
            case "TYPE": return .reply(.simpleString(request.argument(1) == "cfg" ? "string" : "hash"))
            case "PTTL": return .reply(.integer(-1))
            case "GET", "STRLEN": return request.name == "GET" ? .reply(.bulkString(Array("v1".utf8))) : .reply(.integer(2))
            case "HGETALL": return .reply(.map([RESPPair(.bulkString(Array("name".utf8)), .bulkString(Array("ada".utf8)))]))
            case "HLEN": return .reply(.integer(1))
            case "HSCAN": return .reply(.array([.bulkString(Array("0".utf8)), .array([.bulkString(Array("name".utf8)), .bulkString(Array("ada".utf8))])]))
            case "OBJECT": return .reply(.bulkString(Array("listpack".utf8)))
            case "MEMORY": return .reply(.integer(72))
            case "SET": return .reply(.simpleString("OK"))
            case "DEL", "UNLINK", "EXPIRE": return .reply(.integer(1))
            case "SLOWLOG": return .reply(.array([]))
            default: return .reply(.error("ERR unknown command '\(request.name)'"))
            }
        }
    }

    private func toolbox(_ profiles: [ConnectionProfile], defaultProfile: String? = nil, forceReadOnly: Bool = false,
                         backend: FakeRedisBackend? = nil, audit: MCPAuditLog? = nil) -> RedisMCPToolbox {
        let backend = backend ?? keyspaceBackend()
        return RedisMCPToolbox(profiles: StaticProfiles(profiles), defaultProfile: defaultProfile, forceReadOnly: forceReadOnly,
                               clientFactory: { configuration in try await RedisClient.connect(configuration, connector: backend.connector) },
                               audit: audit)
    }

    @Test func listConnectionsShowsOnlyEnabledProfiles() async {
        let tools = toolbox([profile("prod", .readOnly), profile("dev", .readWrite), profile("secret", .disabled)])
        let result = await tools.call(name: "list_connections", arguments: [:])
        let names = result.payload["connections"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(Set(names) == ["prod", "dev"])
        #expect(!result.payload.compactString.contains("secret"))
        await tools.shutdown()
    }

    @Test func profileSelectionRules() async {
        let one = toolbox([profile("only", .readOnly), profile("off", .disabled)])
        #expect(await one.call(name: "scan_keys", arguments: [:]).isError == false)
        let disabled = await one.call(name: "scan_keys", arguments: ["connection": .string("off")])
        #expect(disabled.isError)
        #expect(disabled.payload.compactString.contains("not enabled"))
        await one.shutdown()

        let two = toolbox([profile("a", .readOnly), profile("b", .readOnly)])
        let ambiguous = await two.call(name: "scan_keys", arguments: [:])
        #expect(ambiguous.isError)
        #expect(ambiguous.payload.compactString.contains("a") && ambiguous.payload.compactString.contains("b"))
        #expect(await two.call(name: "scan_keys", arguments: ["connection": .string("B")]).isError == false)
        await two.shutdown()

        let defaulted = toolbox([profile("a", .readOnly), profile("b", .readOnly)], defaultProfile: "b")
        #expect(await defaulted.call(name: "scan_keys", arguments: [:]).isError == false)
        await defaulted.shutdown()
    }

    @Test func writeToolsOnlyForReadWriteProfiles() async {
        let readOnly = toolbox([profile("ro", .readOnly)])
        #expect(!(await readOnly.tools()).contains { $0.name == "set_string" })
        await readOnly.shutdown()
        let readWrite = toolbox([profile("rw", .readWrite)])
        let definitions = await readWrite.tools()
        let set = definitions.first { $0.name == "set_string" }
        #expect(set?.destructive == true)
        #expect(await readWrite.call(name: "set_string", arguments: ["key": .string("k"), "value": .string("v")]).isError == false)
        await readWrite.shutdown()
        // --read-only caps every profile.
        let capped = toolbox([profile("rw", .readWrite)], forceReadOnly: true)
        #expect(!(await capped.tools()).contains { $0.name == "set_string" })
        #expect(await capped.call(name: "set_string", arguments: ["key": .string("k"), "value": .string("v")]).isError)
        await capped.shutdown()
        // A read-only profile cannot call write tools even if the model tries.
        let sneaky = toolbox([profile("ro", .readOnly), profile("rw", .readWrite)])
        #expect(await sneaky.call(name: "delete_keys", arguments: ["connection": .string("ro"), "keys": .array([.string("k")])]).isError)
        await sneaky.shutdown()
    }

    @Test func toolsReturnBoundedData() async throws {
        let tools = toolbox([profile("p", .readOnly)])
        let scan = await tools.call(name: "scan_keys", arguments: ["limit": .int(2)])
        #expect(scan.isError == false)
        // SCAN batches are never split (that would lose keys), so the limit is approximate but hard-capped.
        #expect((scan.payload["keys"]?.array?.count ?? 0) >= 2)
        #expect((scan.payload["keys"]?.array?.count ?? 0) <= MCPLimits.maximumItems)
        #expect(scan.payload["complete"] == .bool(true))
        #expect(scan.payload["keys"]?.array?.first?["type"]?.string == "hash")
        let key = await tools.call(name: "get_key", arguments: ["key": .string("user:1")])
        #expect(key.payload["type"]?.string == "hash")
        #expect(key.payload.compactString.contains("ada"))
        let info = await tools.call(name: "key_info", arguments: ["key": .string("user:1")])
        #expect(info.payload["encoding"]?.string == "listpack")
        let server = await tools.call(name: "server_info", arguments: [:])
        #expect(server.payload["server"]?["version"]?.string == "7.2.4")
        let command = await tools.call(name: "run_command", arguments: ["command": .string("GET cfg")])
        #expect(command.payload["reply"]?.string == "v1")
        let denied = await tools.call(name: "run_command", arguments: ["command": .string("FLUSHALL")])
        #expect(denied.isError)
        let multiple = await tools.call(name: "run_command", arguments: ["command": .string("GET a\nDEL a")])
        #expect(multiple.isError)
        let badArgs = await tools.call(name: "get_key", arguments: ["key": .int(3)])
        #expect(badArgs.isError)
        let extra = await tools.call(name: "key_info", arguments: ["key": .string("k"), "bogus": .bool(true)])
        #expect(extra.isError)
        await tools.shutdown()
    }

    @Test func callsAreAuditedWithoutValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = MCPAuditLog(directory: directory)
        let tools = toolbox([profile("rw", .readWrite)], audit: audit)
        _ = await tools.call(name: "run_command", arguments: ["command": .string("GET cfg")])
        _ = await tools.call(name: "set_string", arguments: ["key": .string("k"), "value": .string("top-secret-value")])
        _ = await tools.call(name: "run_command", arguments: ["command": .string("AUTH hunter2")])
        await tools.shutdown()
        await audit.flush()
        let text = try String(contentsOf: directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(text.contains("\"source\":\"mcp\""))
        #expect(text.contains("GET cfg"))
        #expect(!text.contains("top-secret-value"))
        #expect(!text.contains("hunter2"))
    }
}
