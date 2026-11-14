import Foundation
import RESPWire
import Testing
@testable import RedisKit

/// Regression tests for findings of the adversarial review.
@Suite("Review regressions: RedisKit")
struct RedisKitReviewRegressionTests {
    // Finding 2: read-only mode is an allowlist; admin/topology commands that are not reads are refused.
    @Test func readOnlyModeIsAnAllowlist() async throws {
        let backend = standaloneBackend()
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h")), readOnly: true), connector: backend.connector)
        for line in ["SAVE", "BGSAVE", "BGREWRITEAOF", "PUBLISH ch msg", "CLUSTER SETSLOT 1 STABLE", "CLUSTER MEET 1.2.3.4 7000", "ACL LOAD",
                     "PSYNC ? -1", "SYNC", "FUNCTION KILL", "MEMORY PURGE", "SCRIPT KILL", "CONFIG RESETSTAT", "LATENCY RESET", "CLIENT UNPAUSE",
                     "MODULE LOADEX /x.so", "SET a 1", "FLUSHALL", "SOMETHINGNEW x"] {
            let command = RedisCommand(rawArguments: line.split(separator: " ").map { Array($0.utf8) })
            #expect(throws: RedisError.self, "\(line) must be refused") { try client.enforceReadOnly([command]) }
        }
        for line in ["GET a", "INFO", "CLIENT LIST", "SLOWLOG GET 10", "CONFIG GET maxmemory", "SCAN 0", "SELECT 1", "PING", "SUBSCRIBE c",
                     "CLUSTER NODES", "MEMORY USAGE k", "OBJECT ENCODING k", "COMMAND COUNT", "MULTI", "EXEC", "WATCH k", "TYPE k", "DBSIZE"] {
            let command = RedisCommand(rawArguments: line.split(separator: " ").map { Array($0.utf8) })
            #expect(throws: Never.self, "\(line) must be allowed") { try client.enforceReadOnly([command]) }
        }
        await client.close()
    }

    @Test func dangerousCategoryFromCommandReplyIsHonoured() {
        // [name, arity, flags, first, last, step, acl-categories]
        let entry = RESPValue.array([.bulkString(Array("newadmin".utf8)), .integer(-1), .array([.simpleString("admin")]),
                                     .integer(0), .integer(0), .integer(0), .array([.simpleString("@admin"), .simpleString("@dangerous")])])
        let spec = CommandSpec.fromCommandReply(entry)
        #expect(spec?.flags.contains(.dangerous) == true)
    }

    // Finding 7: blank command names from COMMAND are rejected.
    @Test func blankCommandNamesAreRejected() {
        for name in ["", " ", "|", " | "] {
            let entry = RESPValue.array([.bulkString(Array(name.utf8)), .integer(1), .array([]), .integer(0), .integer(0), .integer(0)])
            #expect(CommandSpec.fromCommandReply(entry) == nil, "'\(name)'")
        }
    }

    // Finding 6: absurd slot ranges are clamped instead of overflowing.
    @Test func hugeSlotRangesAreClamped() throws {
        let line = "abc 127.0.0.1:7000@17000 myself,master - 0 0 1 connected 0-9223372036854775807 16000-99999999999"
        let nodes = ClusterNodeInfo.parse(clusterNodes: line, queriedNode: Endpoint(host: "127.0.0.1", port: 7000))
        let node = try #require(nodes.first)
        #expect(node.slotCount <= 16384)
        #expect(node.slotRanges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 16383 })
        let slots: RESPValue = .array([.array([.integer(0), .integer(Int64.max), .array([.bulkString(Array("127.0.0.1".utf8)), .integer(7000)])])])
        let map = try ClusterSlotMap(clusterSlots: slots, queriedNode: Endpoint(host: "127.0.0.1", port: 7000))
        #expect(map.shards.first.map { $0.slotCount <= 16384 } == true)
    }

    // Finding 23: topology-provided hosts never become Unix socket paths.
    @Test func topologyHostsCannotBeSocketPaths() throws {
        let slots: RESPValue = .array([.array([.integer(0), .integer(16383), .array([.bulkString(Array("/var/run/docker.sock".utf8)), .integer(1)])])])
        let map = try ClusterSlotMap(clusterSlots: slots, queriedNode: Endpoint(host: "127.0.0.1", port: 7000))
        #expect(map.shards.isEmpty)
        #expect(Redirect(message: "MOVED 1 /tmp/redis.sock:6379") == nil)
        #expect(Redirect(message: "ASK 1 ~/x:1") == nil)
        let nodes = ClusterNodeInfo.parse(clusterNodes: "abc /tmp/x:7000@17000 master - 0 0 1 connected 0-16383", queriedNode: Endpoint(host: "h", port: 1))
        #expect(nodes.first?.endpoint == nil)
    }

    // Finding 11: key and agent authentication never fall back to password prompts.
    @Test func sshKeyAuthDisablesPasswordFallback() throws {
        for authentication in [SSHTunnelConfiguration.Authentication.agent, .privateKey] {
            let configuration = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: authentication, privateKeyPath: "/tmp/key")
            let arguments = try SSHTunnel.arguments(for: configuration, localPort: 5000, remote: Endpoint(host: "10.0.0.1", port: 6379))
            let joined = arguments.joined(separator: " ")
            #expect(joined.contains("PasswordAuthentication=no"))
            #expect(joined.contains("KbdInteractiveAuthentication=no"))
            #expect(joined.contains("PreferredAuthentications=publickey"))
        }
        #expect(SSHTunnel.askPassSecret(for: .agent, secret: "pw") == "")
        #expect(SSHTunnel.askPassSecret(for: .privateKey, secret: "pp") == "pp")
    }
}
