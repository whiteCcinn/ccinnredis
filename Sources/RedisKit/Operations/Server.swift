import Foundation
import RESPWire

public struct SlowlogEntry: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var durationMicroseconds: Int64
    public var arguments: [String]
    /// 4.0+
    public var clientAddress: String?
    /// 4.0+
    public var clientName: String?
    public var node: Endpoint?

    public var commandLine: String { arguments.joined(separator: " ") }
}

/// One line of `CLIENT LIST` (fields vary by version; all kept in `fields`).
public struct ClientInfo: Sendable, Hashable, Identifiable {
    public var fields: [String: String]
    public var order: [String]
    public var node: Endpoint?

    public var id: String { "\(node?.description ?? "")#\(fields["id"] ?? fields["addr"] ?? UUID().uuidString)" }
    public var clientID: String? { fields["id"] }
    public var address: String { fields["addr"] ?? "" }
    public var name: String { fields["name"] ?? "" }
    public var ageSeconds: Int64 { Int64(fields["age"] ?? "") ?? 0 }
    public var idleSeconds: Int64 { Int64(fields["idle"] ?? "") ?? 0 }
    public var database: Int { Int(fields["db"] ?? "") ?? 0 }
    public var lastCommand: String { fields["cmd"] ?? "" }
    public var flags: String { fields["flags"] ?? "" }
    public var user: String? { fields["user"] }
    public var libraryName: String? { fields["lib-name"] }

    /// Parses `CLIENT LIST` output: one client per line, `key=value` separated by spaces.
    public static func parse(_ text: String, node: Endpoint? = nil) -> [ClientInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var fields: [String: String] = [:]
            var order: [String] = []
            for token in line.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let key = String(pair[0])
                fields[key] = String(pair[1])
                order.append(key)
            }
            return fields.isEmpty ? nil : ClientInfo(fields: fields, order: order, node: node)
        }
    }
}

public struct ConfigEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var value: String
    public var id: String { name }
}

extension RedisClient {
    /// `INFO [section]` from one node (the primary by default).
    public func info(section: String? = nil, node endpoint: Endpoint? = nil) async throws -> InfoSnapshot {
        guard capabilities.supports(.info) else {
            throw RedisError(.unsupported, capabilities[.info].reason ?? "INFO is not available")
        }
        let command = RedisCommand("INFO", section.map { [.string($0)] } ?? [])
        let reply: RESPValue
        if let endpoint {
            reply = try await node(endpoint).send(command)
        } else {
            reply = try await execute(command, route: .node(primaryEndpoint))
        }
        return InfoSnapshot.parse(reply.string ?? reply.text ?? "")
    }

    public func slowlog(count: Int = 128, node endpoint: Endpoint? = nil) async throws -> [SlowlogEntry] {
        let target = endpoint ?? primaryEndpoint
        let reply = try await node(target).send(RedisCommand("SLOWLOG", ["GET", .int(count)]))
        return (reply.array ?? []).compactMap { item in
            guard let parts = item.array, parts.count >= 4, let id = parts[0].int, let time = parts[1].int, let duration = parts[2].int else { return nil }
            let arguments = (parts[3].array ?? []).map { value -> String in
                guard let bytes = value.bytes else { return value.text ?? "" }
                return RedisKey(bytes: bytes).display
            }
            return SlowlogEntry(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(time)), durationMicroseconds: duration,
                                arguments: arguments, clientAddress: parts.count > 4 ? parts[4].string : nil,
                                clientName: parts.count > 5 ? parts[5].string : nil, node: target)
        }
    }

    public func slowlogReset(node endpoint: Endpoint? = nil) async throws {
        try enforceReadOnly([RedisCommand("SLOWLOG", ["RESET"])])
        try await node(endpoint ?? primaryEndpoint).send(RedisCommand("SLOWLOG", ["RESET"]))
    }

    public func clients(node endpoint: Endpoint? = nil) async throws -> [ClientInfo] {
        let target = endpoint ?? primaryEndpoint
        let reply = try await node(target).send(RedisCommand("CLIENT", ["LIST"]))
        return ClientInfo.parse(reply.string ?? "", node: target)
    }

    /// `CLIENT KILL ID` (2.8.12+) or `CLIENT KILL addr` on older servers.
    public func kill(_ client: ClientInfo) async throws {
        let command: RedisCommand
        if let id = client.clientID, capabilities.supports(.clientKillByID) {
            command = RedisCommand("CLIENT", ["KILL", "ID", .string(id)])
        } else {
            command = RedisCommand("CLIENT", ["KILL", .string(client.address)])
        }
        try enforceReadOnly([command])
        try await node(client.node ?? primaryEndpoint).send(command)
    }

    public func config(pattern: String = "*", node endpoint: Endpoint? = nil) async throws -> [ConfigEntry] {
        let reply = try await node(endpoint ?? primaryEndpoint).send(RedisCommand("CONFIG", ["GET", .string(pattern)]))
        return (reply.pairs ?? []).compactMap { pair in
            guard let name = pair.key.string else { return nil }
            return ConfigEntry(name: name, value: pair.value.text ?? "")
        }.sorted { $0.name < $1.name }
    }

    public func setConfig(_ name: String, value: String, node endpoint: Endpoint? = nil) async throws {
        let command = RedisCommand("CONFIG", ["SET", .string(name), .string(value)])
        try enforceReadOnly([command])
        try await node(endpoint ?? primaryEndpoint).send(command)
    }

    public func clusterNodes() async throws -> [ClusterNodeInfo] {
        let target = primaryEndpoint
        let reply = try await node(target).send(RedisCommand("CLUSTER", ["NODES"]))
        return ClusterNodeInfo.parse(clusterNodes: reply.string ?? "", queriedNode: target)
    }

    public func clusterInfo() async throws -> [String: String] {
        let reply = try await node(primaryEndpoint).send(RedisCommand("CLUSTER", ["INFO"]))
        var result: [String: String] = [:]
        for line in (reply.string ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    /// Active channels (matching `pattern`) with subscriber counts, merged over masters in a cluster.
    public func pubsubChannels(pattern: String? = nil) async throws -> [(channel: String, subscribers: Int64)] {
        let channelsCommand = RedisCommand("PUBSUB", ["CHANNELS"] + (pattern.map { [.string($0)] } ?? []))
        var channels = Set<String>()
        for reply in try await fanOut(channelsCommand, nodes: .masters) {
            if case let .success(value) = reply.result { channels.formUnion((value.array ?? []).compactMap(\.string)) }
        }
        guard !channels.isEmpty else { return [] }
        let names = channels.sorted()
        var counts: [String: Int64] = [:]
        for reply in try await fanOut(RedisCommand("PUBSUB", ["NUMSUB"] + names.map(RedisArgument.string)), nodes: .masters) {
            guard case let .success(value) = reply.result else { continue }
            for pair in value.pairs ?? [] {
                if let name = pair.key.string { counts[name, default: 0] += pair.value.int ?? 0 }
            }
        }
        return names.map { ($0, counts[$0] ?? 0) }
    }

    @discardableResult
    public func publish(channel: String, message: [UInt8]) async throws -> Int64 {
        try await execute(RedisCommand("PUBLISH", [.string(channel), .raw(message)]), route: .auto).int ?? 0
    }
}
