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
        if allowedAdmin.contains(qualified) { return .allowed }
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
        return .allowed
    }

    /// Hides secret configuration values (`requirepass`, `masterauth`, TLS key passwords…) in CONFIG GET replies.
    public static func redact(_ reply: RESPValue, for command: RedisCommand) -> RESPValue {
        guard command.qualifiedName == "CONFIG GET", let pairs = reply.pairs else { return reply }
        let redacted = pairs.map { pair -> RESPPair in
            let name = (pair.key.string ?? "").lowercased()
            if name.contains("pass") || name.contains("auth") || name.contains("secret") || name.contains("key-file") {
                return RESPPair(pair.key, .bulkString(Array("<redacted>".utf8)))
            }
            return pair
        }
        if case .map = reply { return .map(redacted) }
        return .array(redacted.flatMap { [$0.key, $0.value] })
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
