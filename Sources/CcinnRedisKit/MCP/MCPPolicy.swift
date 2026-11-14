import Foundation
import RedisKit
import RESPWire

/// Hard limits applied to every MCP tool call (design §3).
public struct MCPLimits: Sendable {
    public var maxItems: Int
    public var maxStringBytes: Int

    public init(maxItems: Int = 200, maxStringBytes: Int = 64 * 1024) {
        self.maxItems = max(1, maxItems)
        self.maxStringBytes = max(16, maxStringBytes)
    }

    public static let defaultItems = 200
    public static let maximumItems = 1000
    public static let maxResultBytes = 256 * 1024
    public static let defaultTimeout = 30
    public static let maximumTimeout = 120

    public static func itemLimit(_ value: JSONValue?) -> Int {
        guard let requested = value?.int else { return defaultItems }
        return Int(min(max(requested, 1), Int64(maximumItems)))
    }

    public static func timeout(_ value: JSONValue?) -> Int {
        guard let requested = value?.int else { return defaultTimeout }
        return Int(min(max(requested, 1), Int64(maximumTimeout)))
    }
}

/// App-enforced read-only command policy for `run_command` (design §3, §6): the model is never trusted.
public enum MCPCommandPolicy {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case denied(String)
    }

    /// Commands denied even though some are flagged read-only (stateful, blocking, streaming, unbounded or secret-revealing).
    static let denied: Set<String> = [
        "KEYS", "MONITOR", "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE",
        "SELECT", "AUTH", "HELLO", "RESET", "QUIT", "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH", "WAIT", "WAITAOF",
        "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO", "DEBUG", "SHUTDOWN", "FLUSHALL", "FLUSHDB",
        "SAVE", "BGSAVE", "BGREWRITEAOF", "REPLICAOF", "SLAVEOF", "FAILOVER", "SWAPDB", "MIGRATE", "PUBLISH", "SPUBLISH",
        "ASKING", "READONLY", "READWRITE", "SORT", "DUMP", "LOLWUT",
    ]

    /// Admin/introspection subcommands that only read.
    static let allowedAdmin: Set<String> = [
        "INFO", "DBSIZE", "TIME", "LASTSAVE", "ROLE", "PING", "ECHO",
        "CLIENT LIST", "CLIENT INFO", "CLIENT GETNAME", "CLIENT ID",
        "SLOWLOG GET", "SLOWLOG LEN", "CONFIG GET",
        "MEMORY USAGE", "MEMORY STATS", "MEMORY DOCTOR",
        "LATENCY LATEST", "LATENCY DOCTOR", "LATENCY HISTORY",
        "CLUSTER INFO", "CLUSTER NODES", "CLUSTER SLOTS", "CLUSTER SHARDS", "CLUSTER KEYSLOT", "CLUSTER COUNTKEYSINSLOT",
        "CLUSTER MYID", "CLUSTER REPLICAS",
        "COMMAND", "COMMAND COUNT", "COMMAND INFO", "COMMAND DOCS", "COMMAND LIST", "COMMAND GETKEYS",
        "MODULE LIST", "ACL WHOAMI", "ACL CAT", "FUNCTION LIST", "FUNCTION STATS",
        "PUBSUB CHANNELS", "PUBSUB NUMSUB", "PUBSUB NUMPAT", "PUBSUB SHARDCHANNELS", "PUBSUB SHARDNUMSUB",
        "OBJECT ENCODING", "OBJECT FREQ", "OBJECT IDLETIME", "OBJECT REFCOUNT", "OBJECT HELP",
        "XINFO STREAM", "XINFO GROUPS", "XINFO CONSUMERS",
    ]

    public static func check(_ command: RedisCommand, spec: CommandSpec?) -> Verdict {
        let name = command.name
        let qualified = command.qualifiedName
        if denied.contains(name) {
            let hint = name == "KEYS" ? " Use the scan_keys tool instead." : ""
            return .denied("\(name) is not allowed over MCP (stateful, blocking, unbounded or modifying).\(hint)")
        }
        if allowedAdmin.contains(qualified) { return BoundedReads.problem(command).map(Verdict.denied) ?? .allowed }
        guard let spec else {
            return .denied("\(qualified) is not a known read-only command; MCP only runs commands it can classify as reads.")
        }
        if spec.isWrite || spec.flags.contains(.dangerous) {
            return .denied("\(spec.name) modifies data or the server. This connection is read-only over MCP.")
        }
        if spec.flags.contains(.admin) || spec.flags.contains(.connectionState) || spec.flags.contains(.streaming) {
            return .denied("\(spec.name) is an administrative or connection-state command and is not allowed over MCP.")
        }
        let blocks = name == "XREAD"
            ? command.arguments.contains { String(decoding: $0, as: UTF8.self).uppercased() == "BLOCK" }
            : spec.flags.contains(.blocking)
        if blocks { return .denied("Blocking reads are not allowed over MCP.") }
        guard spec.flags.contains(.readonly) else {
            return .denied("\(spec.name) is not flagged read-only.")
        }
        if let problem = BoundedReads.problem(command) { return .denied(problem) }
        return .allowed
    }

    /// Hides secrets in replies: CONFIG GET values (`requirepass`, `masterauth`, TLS key passwords…) and
    /// the logged arguments of SLOWLOG GET entries (AUTH, CONFIG SET …pass, ACL SETUSER, SENTINEL SET auth-pass…).
    public static func redact(_ reply: RESPValue, for command: RedisCommand) -> RESPValue {
        switch command.qualifiedName {
        case "CONFIG GET":
            guard let pairs = reply.pairs else { return reply }
            let redacted = pairs.map { pair -> RESPPair in
                SecretConfig.isSecret(pair.key.string ?? "") ? RESPPair(pair.key, .bulkString(Array("<redacted>".utf8))) : pair
            }
            if case .map = reply { return .map(redacted) }
            return .array(redacted.flatMap { [$0.key, $0.value] })
        case "SLOWLOG GET":
            guard case let .array(entries) = reply else { return reply }
            return .array(entries.map { entry in
                guard case var .array(fields) = entry, fields.count > 3, let arguments = fields[3].array else { return entry }
                let raw = arguments.map { $0.bytes ?? Array(($0.text ?? "").utf8) }
                fields[3] = .array(ConsoleHistory.redact(arguments: raw).map(RESPValue.bulkString))
                return .array(fields)
            })
        default:
            return reply
        }
    }
}

/// Reads must be bounded: whole-collection replies are refused and ranges/counts are capped (design §3),
/// so one tool call can never make the server serialise millions of elements.
enum BoundedReads {
    static let maxCount: Int64 = Int64(MCPLimits.maximumItems)

    static let wholeCollection: Set<String> = [
        "HGETALL", "HKEYS", "HVALS", "SMEMBERS", "SUNION", "SINTER", "SDIFF", "ZUNION", "ZINTER", "ZDIFF",
    ]

    static func problem(_ command: RedisCommand) -> String? {
        let words = command.arguments.map { String(decoding: $0, as: UTF8.self) }
        let name = command.name
        if wholeCollection.contains(name) {
            return "\(name) returns the whole collection. Use get_key (paged), or HSCAN/SSCAN/ZSCAN with COUNT ≤ \(maxCount)."
        }
        switch name {
        case "SCAN": return scanCount(words, optionsFrom: 2)
        case "HSCAN", "SSCAN", "ZSCAN": return scanCount(words, optionsFrom: 3)
        case "LRANGE", "ZREVRANGE": return indexSpan(words, name: name)
        case "ZRANGE":
            let options = Set(words.dropFirst(4).map { $0.uppercased() })
            if options.contains("BYSCORE") || options.contains("BYLEX") { return limitCount(words, optionsFrom: 4, name: name) }
            return indexSpan(words, name: name)
        case "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX", "SORT_RO":
            return limitCount(words, optionsFrom: name == "SORT_RO" ? 2 : 4, name: name)
        case "XRANGE", "XREVRANGE":
            return requiredCount(option(words, "COUNT", from: 4), name: name, option: "COUNT")
        case "XREAD":
            let end = words.firstIndex { $0.uppercased() == "STREAMS" } ?? words.count
            return requiredCount(option(Array(words.prefix(end)), "COUNT", from: 1), name: name, option: "COUNT")
        case "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO":
            return requiredCount(option(words, "COUNT", from: 2), name: name, option: "COUNT")
        case "SRANDMEMBER", "HRANDFIELD", "ZRANDMEMBER":
            guard words.count > 2 else { return nil }
            guard let count = Int64(words[2]), count >= -maxCount, count <= maxCount else {
                return "\(name) count must be between -\(maxCount) and \(maxCount)."
            }
            return nil
        case "LPOS":
            guard let count = option(words, "COUNT", from: 3) else { return nil }
            return (1...maxCount).contains(count ?? 0) ? nil : "LPOS COUNT must be between 1 and \(maxCount) (0 returns every match)."
        case "XINFO":
            guard words.count > 1, words[1].uppercased() == "STREAM", words.dropFirst(3).contains(where: { $0.uppercased() == "FULL" }) else { return nil }
            guard let count = option(words, "COUNT", from: 3) else { return nil } // FULL defaults to 10 entries
            return (1...maxCount).contains(count ?? 0) ? nil : "XINFO STREAM FULL COUNT must be between 1 and \(maxCount) (0 means all)."
        case "XPENDING":
            guard words.count > 3 else { return nil } // summary form
            let countIndex = words[3].uppercased() == "IDLE" ? 7 : 5
            guard countIndex < words.count, let count = Int64(words[countIndex]), (1...maxCount).contains(count) else {
                return "XPENDING count must be between 1 and \(maxCount)."
            }
            return nil
        case "MEMORY":
            guard command.qualifiedName == "MEMORY USAGE", let samples = option(words, "SAMPLES", from: 3) else { return nil }
            return (1...maxCount).contains(samples ?? 0) ? nil : "MEMORY USAGE SAMPLES must be between 1 and \(maxCount) (0 walks every element)."
        default:
            return nil
        }
    }

    /// The integer after `name` (case-insensitive), searching option positions from `start`.
    /// `nil` when the option is absent, `.some(nil)` when its value is missing or not an integer.
    private static func option(_ words: [String], _ name: String, from start: Int) -> Int64?? {
        var index = start
        while index < words.count {
            if words[index].uppercased() == name {
                return index + 1 < words.count ? .some(Int64(words[index + 1])) : .some(nil)
            }
            index += 1
        }
        return nil
    }

    private static func scanCount(_ words: [String], optionsFrom start: Int) -> String? {
        guard let count = option(words, "COUNT", from: start) else { return nil }
        return (1...maxCount).contains(count ?? 0) ? nil : "SCAN COUNT must be between 1 and \(maxCount)."
    }

    private static func requiredCount(_ count: Int64??, name: String, option: String) -> String? {
        guard let count, let value = count, (1...maxCount).contains(value) else {
            return "\(name) needs \(option) between 1 and \(maxCount) over MCP."
        }
        return nil
    }

    private static func limitCount(_ words: [String], optionsFrom start: Int, name: String) -> String? {
        var index = start
        while index < words.count {
            if words[index].uppercased() == "LIMIT", index + 2 < words.count, let count = Int64(words[index + 2]), (1...maxCount).contains(count) {
                return nil
            }
            index += 1
        }
        return "\(name) needs LIMIT <offset> <count> with count between 1 and \(maxCount) over MCP."
    }

    /// Index ranges must have the same sign and span at most `maxCount` elements (0 -1 means everything).
    private static func indexSpan(_ words: [String], name: String) -> String? {
        guard words.count >= 4, let start = Int64(words[2]), let stop = Int64(words[3]) else {
            return "\(name) needs integer start and stop indexes."
        }
        guard (start >= 0) == (stop >= 0) else {
            return "\(name) \(start) \(stop) may return the whole collection; use non-negative (or both negative) indexes spanning at most \(maxCount) elements."
        }
        let (span, overflow) = stop.subtractingReportingOverflow(start)
        guard !overflow, span < maxCount else {
            return "\(name) may return at most \(maxCount) elements over MCP; narrow the range."
        }
        return nil
    }
}

/// Converts replies to bounded JSON (binary strings as base64, long strings and aggregates clipped).
public enum MCPValueEncoder {
    public static func json(_ value: RESPValue, limits: MCPLimits) -> (value: JSONValue, truncated: Bool) {
        var truncated = false
        var budget = limits.maxItems
        let result = convert(value, limits: limits, budget: &budget, truncated: &truncated, depth: 0)
        return (result, truncated)
    }

    public static func text(_ bytes: [UInt8], limit: Int, truncated: inout Bool) -> JSONValue {
        var clipped = bytes
        if bytes.count > limit {
            clipped = Array(bytes.prefix(limit))
            truncated = true
        }
        if let text = String(bytes: clipped, encoding: .utf8) { return .string(text) }
        if bytes.count > limit, let text = String(bytes: clipped.dropLast(3), encoding: .utf8) ?? String(bytes: clipped.dropLast(2), encoding: .utf8)
            ?? String(bytes: clipped.dropLast(1), encoding: .utf8) {
            return .string(text) // cut inside a multi-byte character
        }
        return .object(["base64": .string(Data(clipped).base64EncodedString())])
    }

    private static func convert(_ value: RESPValue, limits: MCPLimits, budget: inout Int, truncated: inout Bool, depth: Int) -> JSONValue {
        guard depth < 16 else {
            truncated = true
            return .string("…")
        }
        switch value {
        case let .simpleString(text): return .string(text)
        case let .error(message): return .object(["error": .string(message)])
        case let .blobError(bytes): return .object(["error": .string(String(decoding: bytes, as: UTF8.self))])
        case let .integer(number): return .int(number)
        case let .bulkString(bytes): return text(bytes, limit: limits.maxStringBytes, truncated: &truncated)
        case let .verbatim(_, bytes): return text(bytes, limit: limits.maxStringBytes, truncated: &truncated)
        case .null: return .null
        case let .double(number): return .double(number)
        case let .boolean(flag): return .bool(flag)
        case let .bigNumber(text): return .string(text)
        case let .array(elements), let .set(elements), let .push(elements):
            var items: [JSONValue] = []
            for element in elements {
                guard budget > 0 else {
                    truncated = true
                    break
                }
                budget -= 1
                items.append(convert(element, limits: limits, budget: &budget, truncated: &truncated, depth: depth + 1))
            }
            return .array(items)
        case let .map(entries):
            var object: [String: JSONValue] = [:]
            for entry in entries {
                guard budget > 0 else {
                    truncated = true
                    break
                }
                budget -= 1
                let key = entry.key.string ?? entry.key.text ?? ReplyFormatter.format(entry.key)
                object[key] = convert(entry.value, limits: limits, budget: &budget, truncated: &truncated, depth: depth + 1)
            }
            return .object(object)
        }
    }
}

/// Shrinks a result object until its encoding fits, halving its largest array/string (design §3: ≈256 KB).
public enum MCPResultFitter {
    public static func fit(_ payload: JSONValue, maxBytes: Int = MCPLimits.maxResultBytes) -> JSONValue {
        guard payload.compactData.count > maxBytes, case var .object(fields) = payload else { return payload }
        fields["truncated"] = .bool(true)
        for _ in 0..<40 {
            let current = JSONValue.object(fields)
            if current.compactData.count <= maxBytes { return current }
            // Largest field by encoded size.
            guard let (key, value) = fields.max(by: { $0.value.compactData.count < $1.value.compactData.count }) else { break }
            switch value {
            case let .array(items) where items.count > 1:
                fields[key] = .array(Array(items.prefix(items.count / 2)))
            case let .string(text) where text.count > 64:
                fields[key] = .string(String(text.prefix(text.count / 2)))
            case let .object(inner) where !inner.isEmpty:
                fields[key] = fit(.object(inner), maxBytes: maxBytes / 2)
                if fields[key]?.compactData.count ?? 0 > maxBytes / 2 { fields[key] = .string("(omitted: too large)") }
            default:
                fields[key] = .string("(omitted: too large)")
            }
        }
        let final = JSONValue.object(fields)
        return final.compactData.count <= maxBytes ? final : .object(["truncated": .bool(true), "error": .string("The result was too large to return.")])
    }
}
