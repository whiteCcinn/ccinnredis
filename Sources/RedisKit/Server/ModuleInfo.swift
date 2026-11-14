import Foundation
import RESPWire

/// A loaded module (`MODULE LIST`).
public struct ModuleInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var version: Int64
    public var id: String { name }

    public init(name: String, version: Int64) {
        self.name = name
        self.version = version
    }

    public static func parse(_ reply: RESPValue) -> [ModuleInfo] {
        (reply.array ?? []).compactMap { entry in
            guard let name = entry["name"]?.string else { return nil }
            return ModuleInfo(name: name, version: entry["ver"]?.int ?? 0)
        }
    }

    /// Human name of well-known modules.
    public var displayName: String {
        switch name.lowercased() {
        case "rejson", "json", "redisjson": "RedisJSON"
        case "search", "ft", "redisearch": "RediSearch"
        case "timeseries": "RedisTimeSeries"
        case "bf", "bloom": "RedisBloom"
        case "graph": "RedisGraph"
        case "vectorset": "Vector sets"
        case let other where other.hasPrefix("redisgears"): "RedisGears"
        default: name
        }
    }

    /// Dotted module version (10203 → 1.2.3).
    public var versionString: String {
        guard version > 0 else { return "" }
        return "\(version / 10_000).\(version / 100 % 100).\(version % 100)"
    }

    public var isJSON: Bool { ["rejson", "json", "redisjson"].contains(name.lowercased()) }
}

extension CommandSpec {
    /// Parses one `COMMAND` entry: `[name, arity, flags, first, last, step, …]`.
    static func fromCommandReply(_ entry: RESPValue) -> CommandSpec? {
        guard let fields = entry.array, fields.count >= 6, let name = fields[0].string,
              let arity = fields[1].int.flatMap({ Int(exactly: $0) }) else { return nil }
        let words = Set((fields[2].array ?? []).compactMap { $0.string?.lowercased() })
        let categories = fields.count > 6 ? Set((fields[6].array ?? []).compactMap { $0.string?.lowercased() }) : []
        // Blank or whitespace names would break lookups and completion.
        let normalized = name.replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, !normalized.split(separator: " ").isEmpty,
              normalized.split(separator: " ").count <= 2, !normalized.contains("  ") else { return nil }
        var flags: Flags = []
        if words.contains("write") || categories.contains("@write") { flags.insert(.write) }
        if categories.contains("@dangerous") { flags.insert(.dangerous) }
        if words.contains("readonly") { flags.insert(.readonly) }
        if words.contains("admin") { flags.insert(.admin) }
        if words.contains("pubsub") { flags.insert(.pubsub) }
        if words.contains("blocking") { flags.insert(.blocking) }
        let first = fields[3].int.flatMap { Int(exactly: $0) } ?? 0
        let last = fields[4].int.flatMap { Int(exactly: $0) } ?? 0
        let step = fields[5].int.flatMap { Int(exactly: $0) } ?? 0
        let keys: KeyRule = first > 0 ? .range(first: first, last: last, step: step) : .none
        return CommandSpec(name: normalized.uppercased(), arity: arity, flags: flags, keys: keys,
                           since: ServerVersion(1, 0, 0), group: words.contains("module") ? "module" : "server")
    }

    /// All specs (including 7.0+ subcommands at index 9) of a `COMMAND` reply.
    static func parseCommandReply(_ reply: RESPValue) -> [CommandSpec] {
        var specs: [CommandSpec] = []
        for entry in reply.array ?? [] {
            if let spec = fromCommandReply(entry) { specs.append(spec) }
            if let fields = entry.array, fields.count > 9, let subcommands = fields[9].array {
                specs += subcommands.compactMap(fromCommandReply)
            }
        }
        return specs
    }
}
