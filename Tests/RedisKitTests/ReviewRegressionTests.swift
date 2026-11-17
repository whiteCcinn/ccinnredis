import Foundation
import os
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

    // With `ControlMaster auto` in ~/.ssh/config, an app tunnel used to become the shared master: closing its window
    // then cut every session multiplexed over it. Tunnels never become a master; existing masters stay usable, so
    // ControlPath is left to the user's configuration.
    @Test func sshTunnelsNeverBecomeASharedControlMaster() throws {
        let remotes = [Endpoint(host: "10.0.0.1", port: 6379), .unixSocket("/var/run/redis.sock")]
        for authentication in SSHTunnelConfiguration.Authentication.allCases {
            for remote in remotes {
                let configuration = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: authentication, privateKeyPath: "/tmp/key")
                let arguments = try SSHTunnel.arguments(for: configuration, localPort: 5000, remote: remote)
                let options = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
                #expect(options.filter { $0.hasPrefix("ControlMaster=") } == ["ControlMaster=no"])
                #expect(!options.contains { $0.hasPrefix("ControlPath=") }, "existing masters must keep working")
                // ssh reads everything after the destination as the remote command.
                #expect(arguments.last == "ops@bastion")
            }
        }
    }

    // Finding 3: list edits by index verify the element they were shown, atomically (WATCH + MULTI).
    @Test func listEditsVerifyTheExpectedElement() async throws {
        let list = WatchedList(["a", "b", "c"])
        let backend = standaloneBackend(extra: list.handle)
        let client = try await RedisClient.connect(ClientConfiguration(mode: .standalone(Endpoint(host: "h"))), connector: backend.connector)
        let key = RedisKey("l")
        try await client.listSet(key, index: 1, value: Array("B".utf8), expected: Array("b".utf8))
        #expect(list.items == ["a", "B", "c"])
        await #expect(throws: RedisError.self) {
            try await client.listSet(key, index: 1, value: Array("X".utf8), expected: Array("b".utf8))
        }
        #expect(list.items == ["a", "B", "c"])
        try await client.listRemove(key, index: 0, expected: Array("a".utf8))
        #expect(list.items == ["B", "c"])
        // Another client modifies the list between the check and EXEC: WATCH aborts the transaction.
        list.mutateAfterCheck()
        do {
            try await client.listRemove(key, index: 0, expected: Array("B".utf8))
            Issue.record("expected a conflict")
        } catch let error as RedisError {
            #expect(error.kind == .conflict)
        }
        #expect(list.items == ["B", "c", "pushed"])
        await client.close()
    }
}

/// A list with per-connection WATCH/MULTI semantics, enough to exercise optimistic edits.
final class WatchedList: @unchecked Sendable {
    private struct State {
        var items: [String]
        var watchers: Set<Int> = []
        var dirty: Set<Int> = []
        var queued: [Int: [[String]]] = [:]
        var mutateAfterCheck = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ items: [String]) { state = OSAllocatedUnfairLock(uncheckedState: State(items: items)) }

    var items: [String] { state.withLockUnchecked { $0.items } }
    func mutateAfterCheck() { state.withLockUnchecked { $0.mutateAfterCheck = true } }

    func handle(_ request: FakeRequest) -> FakeAction? {
        state.withLockUnchecked { state in
            let connection = request.connectionIndex
            let words = request.strings
            func touch() { state.dirty.formUnion(state.watchers) }
            func apply(_ words: [String]) -> RESPValue {
                switch words[0].uppercased() {
                case "LSET":
                    guard let index = Int(words[2]), state.items.indices.contains(index) else { return .err("ERR index out of range") }
                    state.items[index] = words[3]
                    touch()
                    return .ok
                case "LREM":
                    guard let index = state.items.firstIndex(of: words[3]) else { return .integer(0) }
                    state.items.remove(at: index)
                    touch()
                    return .integer(1)
                default:
                    return .err("ERR unsupported")
                }
            }
            switch request.name {
            case "WATCH":
                state.watchers.insert(connection)
                state.dirty.remove(connection)
                return .reply(.ok)
            case "UNWATCH":
                state.watchers.remove(connection)
                return .reply(.ok)
            case "LINDEX":
                let index = Int(words[2]) ?? -1
                let reply: RESPValue = state.items.indices.contains(index) ? .bulk(state.items[index]) : .null
                if state.mutateAfterCheck {
                    state.mutateAfterCheck = false
                    state.items.append("pushed")
                    touch()
                }
                return .reply(reply)
            case "MULTI":
                state.queued[connection] = []
                return .reply(.ok)
            case "LSET", "LREM":
                if state.queued[connection] != nil {
                    state.queued[connection]?.append(words)
                    return .reply(.simpleString("QUEUED"))
                }
                return .reply(apply(words))
            case "EXEC":
                let queued = state.queued.removeValue(forKey: connection) ?? []
                defer {
                    state.watchers.remove(connection)
                    state.dirty.remove(connection)
                }
                if state.dirty.contains(connection) { return .reply(.null) }
                return .reply(.array(queued.map(apply)))
            default:
                return nil
            }
        }
    }
}
