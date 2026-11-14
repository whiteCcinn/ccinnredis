import Foundation
import RESPWire

/// A replica as reported by Sentinel.
public struct SentinelReplica: Sendable, Hashable {
    public var endpoint: Endpoint
    public var flags: [String]
    public var isHealthy: Bool { !flags.contains { ["s_down", "o_down", "disconnected"].contains($0) } }
}

/// Asks sentinels where the master (or a replica) of a group is (design D9).
struct SentinelResolver: Sendable {
    let sentinels: [Endpoint]
    let masterName: String
    let credentials: Credentials
    let connector: EndpointConnector
    let timeout: Double

    private func withSentinel<T: Sendable>(_ body: @Sendable (RedisConnection) async throws -> T?) async throws -> (T, Endpoint) {
        guard !sentinels.isEmpty else { throw RedisError(.invalidArgument, "Add at least one sentinel address") }
        var failures: [String] = []
        let plan = HandshakePlan(credentials: credentials, protocolPreference: .resp2, clientName: nil)
        for sentinel in sentinels {
            try Task.checkCancellation()
            do {
                let (connection, _) = try await Handshaker.open(endpoint: sentinel, plan: plan, connector: connector, timeout: timeout)
                defer { Task { await connection.close() } }
                if let value = try await body(connection) { return (value, sentinel) }
                failures.append("\(sentinel): does not know master '\(masterName)'")
            } catch let error as RedisError {
                if error.kind == .cancelled { throw error }
                failures.append("\(sentinel): \(error.message)")
            }
        }
        throw RedisError(.topology, "No sentinel could resolve '\(masterName)'. " + failures.joined(separator: "; "))
    }

    func resolveMaster() async throws -> (master: Endpoint, sentinel: Endpoint) {
        let name = masterName
        let timeout = timeout
        let (endpoint, sentinel) = try await withSentinel { connection -> Endpoint? in
            let reply = try await connection.send(RedisCommand("SENTINEL", ["get-master-addr-by-name", .string(name)]), timeout: timeout)
            guard let fields = reply.array, fields.count >= 2, let host = fields[0].string, let port = fields[1].int.flatMap({ Int(exactly: $0) }) else {
                return nil
            }
            return Endpoint.announced(host: host, port: port)
        }
        return (endpoint, sentinel)
    }

    func replicas() async throws -> [SentinelReplica] {
        let name = masterName
        let timeout = timeout
        let (list, _) = try await withSentinel { connection -> [SentinelReplica]? in
            var reply = try await connection.pipeline([RedisCommand("SENTINEL", ["replicas", .string(name)])], timeout: timeout)[0]
            if reply.isError {
                reply = try await connection.send(RedisCommand("SENTINEL", ["slaves", .string(name)]), timeout: timeout)
            }
            guard let entries = reply.array else { return nil }
            return entries.compactMap { entry in
                guard let host = entry["ip"]?.string, let port = entry["port"]?.int.flatMap({ Int(exactly: $0) }),
                      let endpoint = Endpoint.announced(host: host, port: port) else { return nil }
                let flags = (entry["flags"]?.string ?? "").split(separator: ",").map(String.init)
                return SentinelReplica(endpoint: endpoint, flags: flags)
            }
        }
        return list
    }

    /// Names of the groups monitored by the first reachable sentinel.
    static func masterNames(at sentinel: Endpoint, credentials: Credentials, connector: EndpointConnector, timeout: Double) async throws -> [String] {
        let plan = HandshakePlan(credentials: credentials, protocolPreference: .resp2, clientName: nil)
        let (connection, _) = try await Handshaker.open(endpoint: sentinel, plan: plan, connector: connector, timeout: timeout)
        defer { Task { await connection.close() } }
        let reply = try await connection.send(RedisCommand("SENTINEL", ["masters"]), timeout: timeout)
        return (reply.array ?? []).compactMap { $0["name"]?.string }
    }
}
