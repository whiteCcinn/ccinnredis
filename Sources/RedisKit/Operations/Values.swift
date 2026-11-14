import Foundation
import RESPWire

/// A string value, possibly only its first part.
public struct StringValue: Sendable, Hashable {
    public var bytes: [UInt8]
    public var totalLength: Int64
    public var isTruncated: Bool { Int64(bytes.count) < totalLength }
}

public struct FieldValue: Sendable, Hashable {
    public var field: [UInt8]
    public var value: [UInt8]
    public init(field: [UInt8], value: [UInt8]) {
        self.field = field
        self.value = value
    }
}

public struct ScoredMember: Sendable, Hashable {
    public var member: [UInt8]
    public var score: Double
    public init(member: [UInt8], score: Double) {
        self.member = member
        self.score = score
    }
}

/// One page of an HSCAN/SSCAN/ZSCAN iteration.
public struct ScanPage<Element: Sendable>: Sendable {
    public var cursor: String
    public var elements: [Element]
    public var isComplete: Bool { cursor == "0" }
}

public struct StreamEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var fields: [FieldValue]
}

public struct StreamInfo: Sendable, Hashable {
    public var length: Int64
    public var lastGeneratedID: String?
    public var groups: Int64
    public var firstEntryID: String?
    public var lastEntryID: String?
    public var radixTreeKeys: Int64?
    public var entriesAdded: Int64?
}

public struct StreamGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var consumers: Int64
    public var pending: Int64
    public var lastDeliveredID: String
    /// 7.0+
    public var entriesRead: Int64?
    /// 7.0+
    public var lag: Int64?
    public var id: String { name }
}

public struct StreamConsumer: Sendable, Hashable, Identifiable {
    public var name: String
    public var pending: Int64
    public var idleMilliseconds: Int64
    /// 7.2+
    public var inactiveMilliseconds: Int64?
    public var id: String { name }
}

public struct PendingEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var consumer: String
    public var idleMilliseconds: Int64
    public var deliveries: Int64
}

extension RedisClient {
    // MARK: Strings

    /// Reads a string; values longer than `maxBytes` are fetched partially with GETRANGE.
    public func stringValue(_ key: RedisKey, maxBytes: Int = 1 << 20) async throws -> StringValue {
        let length = try await execute(RedisCommand("STRLEN", [.key(key)])).int ?? 0
        if length > Int64(maxBytes) {
            let part = try await execute(RedisCommand("GETRANGE", [.key(key), "0", .int(max(0, maxBytes - 1))]))
            return StringValue(bytes: part.bytes ?? [], totalLength: length)
        }
        let value = try await execute(RedisCommand("GET", [.key(key)]))
        let bytes = value.bytes ?? []
        return StringValue(bytes: bytes, totalLength: Int64(bytes.count))
    }

    /// Writes a string, keeping the current TTL when asked (KEEPTTL on 6.0+, PX remaining otherwise).
    public func setString(_ key: RedisKey, _ value: [UInt8], keepTTL: Bool) async throws {
        var arguments: [RedisArgument] = [.key(key), .raw(value)]
        if keepTTL {
            if capabilities.supports(.setKeepTTL) {
                arguments.append("KEEPTTL")
            } else if let ttl = Self.ttl(from: try await execute(RedisCommand("PTTL", [.key(key)]))), ttl > 0 {
                arguments += ["PX", .int64(ttl)]
            }
        }
        try await execute(RedisCommand("SET", arguments))
    }

    // MARK: Generic element scans

    private func scanElements(_ command: String, key: RedisKey, cursor: String, match: String?, count: Int) async throws -> ScanPage<RESPValue> {
        var arguments: [RedisArgument] = [.key(key), .string(cursor)]
        if let match, !match.isEmpty, match != "*" { arguments += ["MATCH", .string(match)] }
        arguments += ["COUNT", .int(max(1, count))]
        let reply = try await execute(RedisCommand(command, arguments))
        guard let parts = reply.array, parts.count == 2, let next = parts[0].string else {
            throw RedisError(.protocolViolation, "Unexpected \(command) reply")
        }
        return ScanPage(cursor: next, elements: parts[1].array ?? [])
    }

    // MARK: Hashes

    public func hashScan(_ key: RedisKey, cursor: String = "0", match: String? = nil, count: Int = 500) async throws -> ScanPage<FieldValue> {
        let page = try await scanElements("HSCAN", key: key, cursor: cursor, match: match, count: count)
        return ScanPage(cursor: page.cursor, elements: Self.fieldValues(.array(page.elements)))
    }

    public func hashGetAll(_ key: RedisKey) async throws -> [FieldValue] {
        Self.fieldValues(try await execute(RedisCommand("HGETALL", [.key(key)])))
    }

    public func hashSet(_ key: RedisKey, field: [UInt8], value: [UInt8]) async throws {
        try await execute(RedisCommand("HSET", [.key(key), .raw(field), .raw(value)]))
    }

    public func hashDelete(_ key: RedisKey, fields: [[UInt8]]) async throws {
        guard !fields.isEmpty else { return }
        try await execute(RedisCommand("HDEL", [.key(key)] + fields.map(RedisArgument.raw)))
    }

    static func fieldValues(_ reply: RESPValue) -> [FieldValue] {
        (reply.pairs ?? []).compactMap { pair in
            guard let field = pair.key.bytes, let value = pair.value.bytes else { return nil }
            return FieldValue(field: field, value: value)
        }
    }

    // MARK: Lists

    public func listRange(_ key: RedisKey, start: Int, stop: Int) async throws -> [[UInt8]] {
        (try await execute(RedisCommand("LRANGE", [.key(key), .int(start), .int(stop)])).array ?? []).map { $0.bytes ?? [] }
    }

    /// LSET at `index`. With `expected`, the element must still be that value (another client may have
    /// pushed or popped since the page was read), otherwise `.conflict` is thrown and nothing changes.
    public func listSet(_ key: RedisKey, index: Int, value: [UInt8], expected: [UInt8]? = nil) async throws {
        let set = RedisCommand("LSET", [.key(key), .int(index), .raw(value)])
        guard let expected else {
            try await execute(set)
            return
        }
        try await verifiedListEdit(key, index: index, expected: expected, commands: [set])
    }

    public func listPush(_ key: RedisKey, values: [[UInt8]], atHead: Bool) async throws {
        guard !values.isEmpty else { return }
        try await execute(RedisCommand(atHead ? "LPUSH" : "RPUSH", [.key(key)] + values.map(RedisArgument.raw)))
    }

    /// Removes the element at `index` (LSET to a unique marker, then LREM — atomically with MULTI when possible).
    /// With `expected`, the element must still be that value, otherwise `.conflict` is thrown.
    public func listRemove(_ key: RedisKey, index: Int, expected: [UInt8]? = nil) async throws {
        let marker = RedisArgument("__ccinnredis_deleted_\(UUID().uuidString)__")
        let set = RedisCommand("LSET", [.key(key), .int(index), marker])
        let remove = RedisCommand("LREM", [.key(key), "1", marker])
        if let expected {
            try await verifiedListEdit(key, index: index, expected: expected, commands: [set, remove])
            return
        }
        if deployment.isProxy {
            try await execute(set)
            try await execute(remove)
            return
        }
        let replies = try await executeTransaction([set, remove], key: key)
        if let failure = replies.first(where: \.isError)?.errorMessage { throw RedisError.server(failure) }
    }

    static func listConflict(_ key: RedisKey, index: Int) -> RedisError {
        RedisError(.conflict, "Item \(index) of \(key.display) changed since it was loaded (another client modified the list). Nothing was changed; reload and try again.")
    }

    /// WATCH + LINDEX + MULTI/EXEC on one leased connection, so the check and the edit are atomic.
    /// Proxies have no WATCH/MULTI: there the check is best-effort (LINDEX, then the commands).
    private func verifiedListEdit(_ key: RedisKey, index: Int, expected: [UInt8], commands: [RedisCommand]) async throws {
        try enforceReadOnly(commands)
        let lindex = RedisCommand("LINDEX", [.key(key), .int(index)])
        if deployment.isProxy {
            guard try await execute(lindex).bytes == expected else { throw Self.listConflict(key, index: index) }
            for command in commands { try await execute(command) }
            return
        }
        let target = try endpoint(for: lindex, route: .key(key))
        let node = try await self.node(target)
        let timeout = configuration.commandTimeout
        try await node.withConnection { connection in
            let checked = try await connection.pipeline([RedisCommand("WATCH", [.key(key)]), lindex], timeout: timeout)
            if let failure = checked.first(where: \.isError)?.errorMessage {
                _ = try? await connection.pipeline([RedisCommand("UNWATCH")], timeout: timeout)
                throw RedisError.server(failure)
            }
            guard checked[1].bytes == expected else {
                _ = try await connection.pipeline([RedisCommand("UNWATCH")], timeout: timeout)
                throw Self.listConflict(key, index: index)
            }
            let replies = try await connection.pipeline([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")], timeout: timeout)
            guard let exec = replies.last else { throw RedisError(.protocolViolation, "No EXEC reply") }
            if let message = exec.errorMessage { throw RedisError.server(message) }
            if let failure = replies.dropLast().first(where: \.isError)?.errorMessage {
                throw RedisError.server(failure)
            }
            guard let results = exec.array else { throw Self.listConflict(key, index: index) } // WATCH fired
            if let failure = results.first(where: \.isError)?.errorMessage { throw RedisError.server(failure) }
        }
    }

    /// MULTI … EXEC on the node owning `key`; returns the EXEC results.
    public func executeTransaction(_ commands: [RedisCommand], key: RedisKey) async throws -> [RESPValue] {
        try enforceReadOnly(commands)
        let target = try endpoint(for: RedisCommand("GET", [.key(key)]), route: .key(key))
        let node = try await self.node(target)
        let replies = try await node.pipeline([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")])
        guard let exec = replies.last else { return [] }
        if let message = exec.errorMessage { throw RedisError.server(message) }
        if let failure = replies.dropLast().first(where: \.isError)?.errorMessage { throw RedisError.server(failure) }
        return exec.array ?? []
    }

    // MARK: Sets

    public func setScan(_ key: RedisKey, cursor: String = "0", match: String? = nil, count: Int = 500) async throws -> ScanPage<[UInt8]> {
        let page = try await scanElements("SSCAN", key: key, cursor: cursor, match: match, count: count)
        return ScanPage(cursor: page.cursor, elements: page.elements.compactMap(\.bytes))
    }

    public func setAdd(_ key: RedisKey, members: [[UInt8]]) async throws {
        guard !members.isEmpty else { return }
        try await execute(RedisCommand("SADD", [.key(key)] + members.map(RedisArgument.raw)))
    }

    public func setRemove(_ key: RedisKey, members: [[UInt8]]) async throws {
        guard !members.isEmpty else { return }
        try await execute(RedisCommand("SREM", [.key(key)] + members.map(RedisArgument.raw)))
    }

    // MARK: Sorted sets

    /// Members by rank with scores (RESP2 flat pairs or RESP3 `[member, score]` arrays).
    public func zsetRange(_ key: RedisKey, start: Int, stop: Int, descending: Bool = false) async throws -> [ScoredMember] {
        let command = RedisCommand(descending ? "ZREVRANGE" : "ZRANGE", [.key(key), .int(start), .int(stop), "WITHSCORES"])
        return Self.scoredMembers(try await execute(command))
    }

    public func zsetScan(_ key: RedisKey, cursor: String = "0", match: String? = nil, count: Int = 500) async throws -> ScanPage<ScoredMember> {
        let page = try await scanElements("ZSCAN", key: key, cursor: cursor, match: match, count: count)
        return ScanPage(cursor: page.cursor, elements: Self.scoredMembers(.array(page.elements)))
    }

    public func zsetAdd(_ key: RedisKey, member: [UInt8], score: Double) async throws {
        guard !score.isNaN else { throw RedisError(.invalidArgument, "Score must be a number") }
        try await execute(RedisCommand("ZADD", [.key(key), .double(score), .raw(member)]))
    }

    public func zsetRemove(_ key: RedisKey, members: [[UInt8]]) async throws {
        guard !members.isEmpty else { return }
        try await execute(RedisCommand("ZREM", [.key(key)] + members.map(RedisArgument.raw)))
    }

    static func scoredMembers(_ reply: RESPValue) -> [ScoredMember] {
        guard let items = reply.array else { return [] }
        if items.allSatisfy({ $0.array?.count == 2 }) {
            return items.compactMap { item in
                guard let pair = item.array, let member = pair[0].bytes, let score = pair[1].double else { return nil }
                return ScoredMember(member: member, score: score)
            }
        }
        var result: [ScoredMember] = []
        result.reserveCapacity(items.count / 2)
        var index = 0
        while index + 1 < items.count {
            if let member = items[index].bytes, let score = items[index + 1].double { result.append(ScoredMember(member: member, score: score)) }
            index += 2
        }
        return result
    }

    // MARK: Streams

    /// Entries between `start` and `end` (`-`/`+`, exclusive starts as `(id` on 6.2+).
    public func streamRange(_ key: RedisKey, start: String = "-", end: String = "+", count: Int = 200, descending: Bool = false) async throws -> [StreamEntry] {
        let command = descending
            ? RedisCommand("XREVRANGE", [.key(key), .string(end), .string(start), "COUNT", .int(count)])
            : RedisCommand("XRANGE", [.key(key), .string(start), .string(end), "COUNT", .int(count)])
        return Self.streamEntries(try await execute(command))
    }

    static func streamEntries(_ reply: RESPValue) -> [StreamEntry] {
        (reply.array ?? []).compactMap { item in
            guard let parts = item.array, parts.count == 2, let id = parts[0].string else { return nil }
            return StreamEntry(id: id, fields: fieldValues(parts[1]))
        }
    }

    public func streamInfo(_ key: RedisKey) async throws -> StreamInfo {
        let reply = try await execute(RedisCommand("XINFO", ["STREAM", .key(key)]))
        func entryID(_ value: RESPValue?) -> String? { value?.array?.first?.string }
        return StreamInfo(length: reply["length"]?.int ?? 0, lastGeneratedID: reply["last-generated-id"]?.string,
                          groups: reply["groups"]?.int ?? 0, firstEntryID: entryID(reply["first-entry"]),
                          lastEntryID: entryID(reply["last-entry"]), radixTreeKeys: reply["radix-tree-keys"]?.int,
                          entriesAdded: reply["entries-added"]?.int)
    }

    public func streamGroups(_ key: RedisKey) async throws -> [StreamGroup] {
        let reply = try await execute(RedisCommand("XINFO", ["GROUPS", .key(key)]))
        return (reply.array ?? []).compactMap { item in
            guard let name = item["name"]?.string else { return nil }
            return StreamGroup(name: name, consumers: item["consumers"]?.int ?? 0, pending: item["pending"]?.int ?? 0,
                               lastDeliveredID: item["last-delivered-id"]?.string ?? "", entriesRead: item["entries-read"]?.int,
                               lag: item["lag"]?.int)
        }
    }

    public func streamConsumers(_ key: RedisKey, group: String) async throws -> [StreamConsumer] {
        let reply = try await execute(RedisCommand("XINFO", ["CONSUMERS", .key(key), .string(group)]))
        return (reply.array ?? []).compactMap { item in
            guard let name = item["name"]?.string else { return nil }
            return StreamConsumer(name: name, pending: item["pending"]?.int ?? 0, idleMilliseconds: item["idle"]?.int ?? 0,
                                  inactiveMilliseconds: item["inactive"]?.int)
        }
    }

    public func streamPending(_ key: RedisKey, group: String, count: Int = 100) async throws -> [PendingEntry] {
        let reply = try await execute(RedisCommand("XPENDING", [.key(key), .string(group), "-", "+", .int(count)]))
        return (reply.array ?? []).compactMap { item in
            guard let parts = item.array, parts.count >= 4, let id = parts[0].string else { return nil }
            return PendingEntry(id: id, consumer: parts[1].string ?? "", idleMilliseconds: parts[2].int ?? 0, deliveries: parts[3].int ?? 0)
        }
    }

    @discardableResult
    public func streamAdd(_ key: RedisKey, id: String = "*", fields: [FieldValue]) async throws -> String {
        guard !fields.isEmpty else { throw RedisError(.invalidArgument, "A stream entry needs at least one field") }
        var arguments: [RedisArgument] = [.key(key), .string(id.isEmpty ? "*" : id)]
        for pair in fields { arguments += [.raw(pair.field), .raw(pair.value)] }
        return try await execute(RedisCommand("XADD", arguments)).string ?? ""
    }

    public func streamDelete(_ key: RedisKey, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await execute(RedisCommand("XDEL", [.key(key)] + ids.map(RedisArgument.string)))
    }

    public func groupCreate(_ key: RedisKey, group: String, startID: String = "$", createStream: Bool = false) async throws {
        var arguments: [RedisArgument] = ["CREATE", .key(key), .string(group), .string(startID)]
        if createStream { arguments.append("MKSTREAM") }
        try await execute(RedisCommand("XGROUP", arguments))
    }

    public func groupDestroy(_ key: RedisKey, group: String) async throws {
        try await execute(RedisCommand("XGROUP", ["DESTROY", .key(key), .string(group)]))
    }

    public func groupSetID(_ key: RedisKey, group: String, id: String) async throws {
        try await execute(RedisCommand("XGROUP", ["SETID", .key(key), .string(group), .string(id)]))
    }

    public func consumerDelete(_ key: RedisKey, group: String, consumer: String) async throws {
        try await execute(RedisCommand("XGROUP", ["DELCONSUMER", .key(key), .string(group), .string(consumer)]))
    }

    public func streamAcknowledge(_ key: RedisKey, group: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await execute(RedisCommand("XACK", [.key(key), .string(group)] + ids.map(RedisArgument.string)))
    }

    // MARK: RedisJSON

    /// Whole document as JSON text (`JSON.GET key`).
    public func jsonGet(_ key: RedisKey) async throws -> String {
        let reply = try await execute(RedisCommand("JSON.GET", [.key(key)]))
        return reply.string ?? reply.text ?? "null"
    }

    public func jsonSet(_ key: RedisKey, json: String, path: String = ".") async throws {
        try await execute(RedisCommand("JSON.SET", [.key(key), .string(path), .string(json)]))
    }
}
