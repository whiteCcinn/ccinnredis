import CcinnRedisKit
import Foundation
import os
import Testing

/// Drives the built `CcinnRedis mcp` binary over stdio against the Docker containers
/// (`scripts/redis-up.sh large auth`), with profiles in a temporary directory.
final class MCPProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    private var nextID = 1

    init(binary: URL, arguments: [String], environment: [String: String]) throws {
        process.executableURL = binary
        process.arguments = ["mcp"] + arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = lines
        let pending = OSAllocatedUnfairLock(initialState: Data())
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let complete = pending.withLock { buffer -> [String] in
                buffer.append(data)
                var found: [String] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    found.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                return found
            }
            lines.withLock { $0.append(contentsOf: complete) }
        }
        try process.run()
    }

    func send(_ message: JSONValue) {
        input.fileHandleForWriting.write(message.compactData + Data([0x0A]))
    }

    /// Sends a request and waits for the response with the same id.
    func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        send(.object(["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]))
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let found = lines.withLock { all -> JSONValue? in
                for line in all {
                    if let value = try? JSONValue.decode(Data(line.utf8)), value["id"] == .int(Int64(id)) { return value }
                }
                return nil
            }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MCPToolErrorForTests("No response to \(method) within \(timeout)")
    }

    func call(_ tool: String, _ arguments: [String: JSONValue] = [:]) async throws -> (payload: JSONValue, isError: Bool) {
        let response = try await request("tools/call", params: .object(["name": .string(tool), "arguments": .object(arguments)]))
        let result = response["result"] ?? .null
        return (result["structuredContent"] ?? .null, result["isError"]?.bool ?? false)
    }

    func close() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    var terminationStatus: Int32 { process.terminationStatus }
}

struct MCPToolErrorForTests: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum MCPBinary {
    static var url: URL? {
        if let explicit = ProcessInfo.processInfo.environment["CCINNREDIS_BINARY"] { return URL(fileURLWithPath: explicit) }
        let root = IT.packageRoot.appendingPathComponent(".build")
        for candidate in ["out/Products/Debug/CcinnRedis", "debug/CcinnRedis", "arm64-apple-macosx/debug/CcinnRedis", "x86_64-apple-macosx/debug/CcinnRedis"] {
            let url = root.appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

@Suite("Integration: MCP server subprocess", .enabled(if: IT.wants("large") && IT.wants("auth") && MCPBinary.url != nil), .serialized)
struct MCPIntegrationTests {
    private func writeProfiles(to directory: URL) throws {
        func profile(_ name: String, port: Int, access: MCPAccess) -> ConnectionProfile {
            var profile = ConnectionProfile(name: name, port: port)
            profile.mcpAccess = access
            return profile
        }
        var disabled = profile("hidden", port: 17072, access: .disabled)
        disabled.readOnly = false
        try ProfileRepository(directory: directory, secrets: InMemorySecretStore()).save([
            profile("local72", port: 17072, access: .readOnly),
            profile("writable72", port: 17072, access: .readWrite),
            profile("auth50", port: 17050, access: .readOnly),
            disabled,
        ])
        try Data(#"{"auth50":{"password":"ccinn-pass"}}"#.utf8).write(to: directory.appendingPathComponent("secrets.json"))
    }

    @Test func fullSessionOverStdio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnredis-mcp-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeProfiles(to: directory)
        let binary = try #require(MCPBinary.url)
        let server = try MCPProcess(binary: binary, arguments: [], environment: [
            "CCINNREDIS_PROFILE_DIR": directory.path,
            "CCINNREDIS_TEST_INSECURE_SECRETS_FILE": directory.appendingPathComponent("secrets.json").path,
        ])

        let initialize = try await server.request("initialize", params: .object(["protocolVersion": "2025-06-18", "capabilities": .object([:]),
                                                                                  "clientInfo": .object(["name": "it", "version": "1"])]))
        #expect(initialize["result"]?["serverInfo"]?["name"]?.string == "ccinnredis")
        server.send(.object(["jsonrpc": "2.0", "method": "notifications/initialized"]))

        let tools = try await server.request("tools/list")
        let names = Set((tools["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string })
        #expect(names.isSuperset(of: ["list_connections", "server_info", "scan_keys", "get_key", "key_info", "slowlog", "cluster_info", "run_command", "set_string"]))

        let connections = try await server.call("list_connections")
        #expect(Set((connections.payload["connections"]?.array ?? []).compactMap { $0["name"]?.string }) == ["local72", "writable72", "auth50"])

        let ambiguous = try await server.call("scan_keys")
        #expect(ambiguous.isError)

        let info = try await server.call("server_info", ["connection": "local72", "section": "server"])
        #expect(info.payload["server"]?["version"]?.string?.hasPrefix("7.2") == true)

        let scan = try await server.call("scan_keys", ["connection": "local72", "pattern": "demo:hash:*", "limit": 10])
        #expect(!scan.isError)
        #expect((scan.payload["keys"]?.array ?? []).contains { $0["key"]?.string == "demo:hash:user:1" } || scan.payload["complete"] == .bool(false))

        let value = try await server.call("get_key", ["connection": "local72", "key": "demo:hash:user:1"])
        #expect(value.payload["fields"]?["name"]?.string == "Ada Lovelace")
        let list = try await server.call("get_key", ["connection": "local72", "key": "demo:list:big", "offset": 10, "limit": 5])
        #expect(list.payload["items"]?.array?.first?.string == "item-10")
        #expect(list.payload["length"]?.int == 10_000)

        let command = try await server.call("run_command", ["connection": "local72", "command": "ZRANGE demo:zset:weights 0 99 WITHSCORES"])
        #expect(!command.isError)
        #expect(command.payload["text"]?.string?.contains("alpha") == true)
        // Unbounded reads are refused with a hint (review finding 9).
        let unbounded = try await server.call("run_command", ["connection": "local72", "command": "ZRANGE demo:zset:weights 0 -1"])
        #expect(unbounded.isError)
        let everything = try await server.call("run_command", ["connection": "local72", "command": "HGETALL demo:hash:user:1"])
        #expect(everything.isError)
        #expect(everything.payload.compactString.contains("get_key"))
        let denied = try await server.call("run_command", ["connection": "local72", "command": "SET x 1"])
        #expect(denied.isError)
        let flush = try await server.call("run_command", ["connection": "writable72", "command": "FLUSHALL"])
        #expect(flush.isError)

        let readOnlyWrite = try await server.call("set_string", ["connection": "local72", "key": "it:mcp", "value": "x"])
        #expect(readOnlyWrite.isError)
        let write = try await server.call("set_string", ["connection": "writable72", "key": "it:mcp", "value": "hello", "ttl_seconds": 60])
        #expect(!write.isError)
        let readBack = try await server.call("get_key", ["connection": "local72", "key": "it:mcp"])
        #expect(readBack.payload["value"]?.string == "hello")
        let deleted = try await server.call("delete_keys", ["connection": "writable72", "keys": .array(["it:mcp"])])
        #expect(deleted.payload["deleted"]?.int == 1)

        let hidden = try await server.call("key_info", ["connection": "hidden", "key": "demo:string:hello"])
        #expect(hidden.isError)

        let authenticated = try await server.call("key_info", ["connection": "auth50", "key": "demo:string:hello"])
        #expect(authenticated.payload["type"]?.string == "string")

        server.close()
        #expect(server.terminationStatus == 0)
        let audit = try String(contentsOf: directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        #expect(audit.split(separator: "\n").count >= 15)
        #expect(!audit.contains("ccinn-pass"))
        #expect(!audit.contains("\"hello\""))
    }

    @Test func readOnlyFlagCapsEveryProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnredis-mcp-ro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeProfiles(to: directory)
        let binary = try #require(MCPBinary.url)
        let server = try MCPProcess(binary: binary, arguments: ["--read-only", "--profile", "writable72"],
                                    environment: ["CCINNREDIS_PROFILE_DIR": directory.path])
        _ = try await server.request("initialize", params: .object(["protocolVersion": "2024-11-05"]))
        let tools = try await server.request("tools/list")
        #expect(!(tools["result"]?["tools"]?.array ?? []).contains { $0["name"]?.string == "set_string" })
        let response = try await server.request("tools/call", params: .object(["name": "key_info", "arguments": .object(["key": "demo:string:hello"])]))
        #expect(response["result"]?["isError"] == .bool(false))
        #expect(response["result"]?["structuredContent"] == nil) // 2024-11-05 has no structured content
        server.close()
    }
}
