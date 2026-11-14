import Foundation
import RESPWire

/// Redis data type as reported by `TYPE` (module types keep their raw name, e.g. `ReJSON-RL`).
public struct KeyType: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let string = KeyType(rawValue: "string")
    public static let hash = KeyType(rawValue: "hash")
    public static let list = KeyType(rawValue: "list")
    public static let set = KeyType(rawValue: "set")
    public static let zset = KeyType(rawValue: "zset")
    public static let stream = KeyType(rawValue: "stream")
    public static let json = KeyType(rawValue: "ReJSON-RL")
    public static let none = KeyType(rawValue: "none")

    /// Types the browser can filter on.
    public static let filterable: [KeyType] = [.string, .hash, .list, .set, .zset, .stream, .json]

    public var isJSON: Bool { rawValue == "ReJSON-RL" || rawValue.lowercased() == "json" }
    public var exists: Bool { rawValue != "none" }

    public var displayName: String {
        switch rawValue {
        case "string": "String"
        case "hash": "Hash"
        case "list": "List"
        case "set": "Set"
        case "zset": "Sorted Set"
        case "stream": "Stream"
        case "none": "Missing"
        default: isJSON ? "JSON" : rawValue
        }
    }

    /// One- or two-letter badge.
    public var badge: String {
        switch rawValue {
        case "string": "STR"
        case "hash": "HASH"
        case "list": "LIST"
        case "set": "SET"
        case "zset": "ZSET"
        case "stream": "XADD"
        default: isJSON ? "JSON" : String(rawValue.prefix(4)).uppercased()
        }
    }

    /// Argument for `SCAN … TYPE`.
    public var scanArgument: String { isJSON ? "ReJSON-RL" : rawValue }
    public var description: String { rawValue }
}

/// Type and TTL of one key (browser rows).
public struct KeyMetadata: Sendable, Hashable {
    public var key: RedisKey
    public var type: KeyType
    /// Remaining time to live in milliseconds; `nil` = persistent; key missing when `type == .none`.
    public var ttlMilliseconds: Int64?
}

/// Everything shown in a key editor header.
public struct KeyDetails: Sendable, Hashable {
    public var key: RedisKey
    public var type: KeyType
    public var ttlMilliseconds: Int64?
    public var encoding: String?
    public var memoryBytes: Int64?
    /// Element count (or byte length for strings).
    public var length: Int64?
    public var idleSeconds: Int64?
    public var frequency: Int64?
}

extension RedisClient {
    /// `PTTL` → milliseconds, `nil` for persistent keys, `-2` mapped to `nil` with `exists == false` by callers.
    static func ttl(from reply: RESPValue) -> Int64? {
        guard let value = reply.int, value >= 0 else { return nil }
        return value
    }

    /// Number of keys (all masters in a cluster).
    public func dbSize() async throws -> Int64 {
        guard capabilities.supports(.dbsize) else {
            throw RedisError(.unsupported, capabilities[.dbsize].reason ?? "DBSIZE is not available")
        }
        return try await execute(RedisCommand("DBSIZE")).int ?? 0
    }

    /// TYPE + PTTL for many keys in pipelines (grouped per node in a cluster).
    public func metadata(for keys: [RedisKey]) async throws -> [KeyMetadata] {
        guard !keys.isEmpty else { return [] }
        var commands: [RedisCommand] = []
        commands.reserveCapacity(keys.count * 2)
        for key in keys {
            commands.append(RedisCommand("TYPE", [.key(key)]))
            commands.append(RedisCommand("PTTL", [.key(key)]))
        }
        let replies = try await pipeline(commands)
        return keys.enumerated().map { index, key in
            let type = replies[index * 2].string.map(KeyType.init(rawValue:)) ?? .none
            return KeyMetadata(key: key, type: type, ttlMilliseconds: Self.ttl(from: replies[index * 2 + 1]))
        }
    }

    public func details(for key: RedisKey) async throws -> KeyDetails {
        var commands = [RedisCommand("TYPE", [.key(key)]), RedisCommand("PTTL", [.key(key)])]
        let caps = capabilities
        let wantsEncoding = caps.supports(.objectEncoding)
        let wantsMemory = caps.supports(.memoryUsage)
        if wantsEncoding { commands.append(RedisCommand("OBJECT", ["ENCODING", .key(key)])) }
        if wantsMemory { commands.append(RedisCommand("MEMORY", ["USAGE", .key(key), "SAMPLES", "5"])) }
        commands.append(RedisCommand("OBJECT", ["IDLETIME", .key(key)]))
        let replies = try await pipeline(commands)
        let type = replies[0].string.map(KeyType.init(rawValue:)) ?? .none
        var details = KeyDetails(key: key, type: type, ttlMilliseconds: Self.ttl(from: replies[1]))
        var index = 2
        if wantsEncoding {
            details.encoding = replies[index].string
            index += 1
        }
        if wantsMemory {
            details.memoryBytes = replies[index].int
            if replies[index].errorMessage.map(RedisError.looksLikeUnavailableCommand) == true {
                markUnavailable(.memoryUsage, reason: "MEMORY USAGE is not available: \(replies[index].errorMessage ?? "")")
            }
            index += 1
        }
        details.idleSeconds = replies[index].int
        if type.exists, let lengthCommand = Self.lengthCommand(for: type, key: key) {
            details.length = try? await executeAllowingErrors(lengthCommand).int
        }
        return details
    }

    /// STRLEN/HLEN/LLEN/SCARD/ZCARD/XLEN for a type.
    public static func lengthCommand(for type: KeyType, key: RedisKey) -> RedisCommand? {
        switch type {
        case .string: RedisCommand("STRLEN", [.key(key)])
        case .hash: RedisCommand("HLEN", [.key(key)])
        case .list: RedisCommand("LLEN", [.key(key)])
        case .set: RedisCommand("SCARD", [.key(key)])
        case .zset: RedisCommand("ZCARD", [.key(key)])
        case .stream: RedisCommand("XLEN", [.key(key)])
        default: nil
        }
    }

    public func exists(_ key: RedisKey) async throws -> Bool {
        (try await execute(RedisCommand("EXISTS", [.key(key)])).int ?? 0) > 0
    }

    public func type(of key: RedisKey) async throws -> KeyType {
        try await execute(RedisCommand("TYPE", [.key(key)])).string.map(KeyType.init(rawValue:)) ?? .none
    }

    /// Deletes keys with UNLINK when available (falls back to DEL on `unknown command`). Returns the count.
    @discardableResult
    public func delete(_ keys: [RedisKey]) async throws -> Int64 {
        guard !keys.isEmpty else { return 0 }
        var total: Int64 = 0
        for chunk in stride(from: 0, to: keys.count, by: 500).map({ Array(keys[$0..<min($0 + 500, keys.count)]) }) {
            let arguments = chunk.map(RedisArgument.key)
            if capabilities.supports(.unlink) {
                let reply = try await executeAllowingErrors(RedisCommand("UNLINK", arguments))
                if let message = reply.errorMessage {
                    guard RedisError.looksLikeUnavailableCommand(message) else { throw RedisError.server(message) }
                    markUnavailable(.unlink, reason: "UNLINK is not available (\(message)); DEL is used instead.")
                } else {
                    total += reply.int ?? 0
                    continue
                }
            }
            total += try await execute(RedisCommand("DEL", arguments)).int ?? 0
        }
        return total
    }

    /// Renames a key. In a cluster both names must hash to the same slot.
    public func rename(_ key: RedisKey, to newKey: RedisKey, overwrite: Bool) async throws {
        if deployment.isCluster, HashSlot.slot(for: key) != HashSlot.slot(for: newKey) {
            throw RedisError(.unsupported, "In a cluster both names must hash to the same slot. Use a {hashtag}, e.g. keep the part in braces identical.")
        }
        let reply = try await execute(RedisCommand(overwrite ? "RENAME" : "RENAMENX", [.key(key), .key(newKey)]))
        if !overwrite, reply.int == 0 {
            throw RedisError(.invalidArgument, "A key named “\(newKey.display)” already exists")
        }
    }

    /// Sets a TTL in seconds, or removes it when `seconds` is nil.
    public func setTTL(_ key: RedisKey, seconds: Int64?) async throws {
        if let seconds {
            guard seconds > 0 else { throw RedisError(.invalidArgument, "TTL must be positive") }
            let reply = try await execute(RedisCommand("EXPIRE", [.key(key), .int64(seconds)]))
            if reply.int == 0 { throw RedisError(.invalidArgument, "The key no longer exists") }
        } else {
            _ = try await execute(RedisCommand("PERSIST", [.key(key)]))
        }
    }

    /// MEMORY USAGE for many keys (nil entries where unavailable).
    public func memoryUsage(of keys: [RedisKey], samples: Int = 5) async throws -> [Int64?] {
        guard capabilities.supports(.memoryUsage) else { return keys.map { _ in nil } }
        let replies = try await pipeline(keys.map { RedisCommand("MEMORY", ["USAGE", .key($0), "SAMPLES", .int(samples)]) })
        return replies.map(\.int)
    }
}

/// Iterates the keyspace with SCAN — every master (or replica) in a cluster, one node otherwise.
public actor KeyScanner {
    public struct Batch: Sendable {
        public let keys: [RedisKey]
        public let node: Endpoint
        public let completedNodes: Int
        public let totalNodes: Int
    }

    private let client: RedisClient
    private let pattern: String?
    private let type: KeyType?
    private let count: Int
    private let nodes: [(endpoint: Endpoint, isReplica: Bool)]
    private let serverSideType: Bool
    private var nodeIndex = 0
    private var cursor = "0"
    public private(set) var isFinished = false

    public init(client: RedisClient, pattern: String?, type: KeyType?, count: Int = 1000) {
        self.client = client
        let trimmed = pattern?.trimmingCharacters(in: .whitespaces)
        self.pattern = (trimmed?.isEmpty ?? true) || trimmed == "*" ? nil : trimmed
        self.type = type
        self.count = max(10, min(count, 100_000))
        nodes = client.scanEndpoints
        serverSideType = client.capabilities.supports(.scanType)
        isFinished = nodes.isEmpty
    }

    public func next() async throws -> Batch? {
        guard !isFinished else { return nil }
        guard client.capabilities.supports(.scan) else {
            throw RedisError(.unsupported, client.capabilities[.scan].reason ?? "SCAN is not available on this server")
        }
        let target = nodes[nodeIndex]
        var arguments: [RedisArgument] = [.string(cursor)]
        if let pattern { arguments += ["MATCH", .string(pattern)] }
        arguments += ["COUNT", .int(count)]
        if let type, serverSideType { arguments += ["TYPE", .string(type.scanArgument)] }
        let node = try await client.node(target.endpoint)
        let reply = try await node.send(RedisCommand("SCAN", arguments))
        guard let parts = reply.array, parts.count == 2, let next = parts[0].string, let items = parts[1].array else {
            throw RedisError(.protocolViolation, "Unexpected SCAN reply from \(target.endpoint)")
        }
        var keys = items.compactMap { $0.bytes.map(RedisKey.init(bytes:)) }
        if let type, !serverSideType, !keys.isEmpty {
            let types = try await node.pipeline(keys.map { RedisCommand("TYPE", [.key($0)]) })
            keys = zip(keys, types).filter { KeyType(rawValue: $1.string ?? "none") == type || ($1.string.map { KeyType(rawValue: $0).isJSON } == true && type.isJSON) }.map(\.0)
        }
        if next == "0" {
            nodeIndex += 1
            cursor = "0"
            if nodeIndex >= nodes.count { isFinished = true }
        } else {
            cursor = next
        }
        return Batch(keys: keys, node: target.endpoint, completedNodes: nodeIndex, totalNodes: nodes.count)
    }
}
