import Foundation
import RedisKit

public enum AppVersion {
    public static let fallback = "1.0.0"

    public static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallback
    }
}

/// Saved profiles from the app's JSON file; secrets from the Keychain, or — for automated tests only —
/// from the JSON file named by `CCINNREDIS_TEST_INSECURE_SECRETS_FILE` (`{"<profile name or id>": {"password": "…"}}`).
public struct FileProfileSource: MCPProfileSource {
    let repository: ProfileRepository
    let testSecrets: [String: ProfileSecrets]?

    public init(directory: URL, testSecretsFile: URL?) {
        if let testSecretsFile {
            repository = ProfileRepository(directory: directory, secrets: InMemorySecretStore())
            testSecrets = Self.loadTestSecrets(testSecretsFile)
        } else {
            repository = ProfileRepository(directory: directory)
            testSecrets = nil
        }
    }

    public func profiles() -> [ConnectionProfile] { (try? repository.load()) ?? [] }

    public func secrets(for profile: ConnectionProfile) -> ProfileSecrets {
        if let testSecrets {
            return testSecrets[profile.id.uuidString] ?? testSecrets[profile.displayName] ?? ProfileSecrets()
        }
        return repository.secrets(for: profile)
    }

    static func loadTestSecrets(_ url: URL) -> [String: ProfileSecrets] {
        guard let data = try? Data(contentsOf: url), let object = (try? JSONValue.decode(data))?.object else { return [:] }
        var result: [String: ProfileSecrets] = [:]
        for (name, value) in object {
            result[name] = ProfileSecrets(password: value["password"]?.string, sentinelPassword: value["sentinelPassword"]?.string,
                                          sshSecret: value["sshSecret"]?.string, tlsCertificatePassword: value["tlsCertificatePassword"]?.string)
        }
        return result
    }
}

/// `CcinnRedis mcp [--profile <name|id>] [--read-only]`: MCP over stdio until stdin closes.
public enum MCPStdioRunner {
    public static let usage = """
    Usage: CcinnRedis mcp [--profile <name|id>] [--read-only]

    Runs the CcinnRedis MCP server on stdin/stdout (JSON-RPC 2.0, one message per line).
    Only connections whose “AI access via MCP” setting is enabled in CcinnRedis are usable.
      --profile <name|id>   default connection when a tool call does not name one
      --read-only           cap every connection at read-only access
    Environment:
      CCINNREDIS_PROFILE_DIR                 directory with connections.json (default: ~/Library/Application Support/CcinnRedis)
      CCINNREDIS_TEST_INSECURE_SECRETS_FILE  TEST ONLY: read passwords from a JSON file instead of the Keychain
    """

    /// Runs until stdin reaches EOF; returns the process exit code.
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        var defaultProfile: String?
        var readOnly = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--profile":
                guard index + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("--profile needs a value\n\(usage)\n".utf8))
                    return 64
                }
                defaultProfile = arguments[index + 1]
                index += 1
            case "--read-only":
                readOnly = true
            case "--help", "-h":
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return 0
            default:
                FileHandle.standardError.write(Data("Unknown option \(arguments[index])\n\(usage)\n".utf8))
                return 64
            }
            index += 1
        }

        let directory = environment["CCINNREDIS_PROFILE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProfileRepository.defaultDirectory
        let testSecrets = environment["CCINNREDIS_TEST_INSECURE_SECRETS_FILE"].map { URL(fileURLWithPath: $0) }
        if testSecrets != nil {
            FileHandle.standardError.write(Data("ccinnredis mcp: WARNING — using CCINNREDIS_TEST_INSECURE_SECRETS_FILE (test only), not the Keychain\n".utf8))
        }
        let source = FileProfileSource(directory: directory, testSecretsFile: testSecrets)
        let audit = MCPAuditLog(directory: directory)
        let toolbox = RedisMCPToolbox(profiles: source, defaultProfile: defaultProfile, forceReadOnly: readOnly, audit: audit)
        let stdout = FileHandle.standardOutput
        let server = MCPServer(name: "ccinnredis", title: "CcinnRedis", version: AppVersion.current, instructions: instructions(readOnly: readOnly),
                               toolbox: toolbox) { data in
            stdout.write(data + Data([0x0A]))
        }
        let enabled = source.profiles().filter { $0.mcpAccess != .disabled }.count
        FileHandle.standardError.write(Data("ccinnredis mcp: ready (\(enabled) connection\(enabled == 1 ? "" : "s") enabled for AI access)\n".utf8))

        let (lines, continuation) = AsyncStream.makeStream(of: MCPLineFramer.Event.self, bufferingPolicy: .unbounded)
        let reader = Thread {
            var framer = MCPLineFramer()
            let input = FileHandle.standardInput
            while true {
                let data = input.availableData
                if data.isEmpty { break }
                for event in framer.append(data) { continuation.yield(event) }
            }
            continuation.finish()
        }
        reader.stackSize = 1 << 20
        reader.start()

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for await event in lines {
                switch event {
                case let .line(data): await server.receive(line: data)
                case .oversized: await server.receiveOversizedLine()
                }
            }
            await server.waitForIdle()
            await toolbox.shutdown()
            SSHTunnel.terminateAll()
            done.signal()
        }
        done.wait()
        return 0
    }

    static func instructions(readOnly: Bool) -> String {
        """
        CcinnRedis gives read access to the user's saved Redis/Valkey connections (standalone, replica, Sentinel, Cluster, proxies) \
        that were explicitly enabled for AI access. Start with list_connections, then server_info, scan_keys (SCAN-based, never KEYS), \
        get_key and key_info. Results are bounded (default 200 items, max 1000; ≈256 KB per result, flagged truncated: true). \
        run_command accepts one read-only command; writes and dangerous commands are refused. \
        \(readOnly ? "This server runs with --read-only: no write tools." : "Write tools exist only for connections with read & write access.")
        """
    }
}
