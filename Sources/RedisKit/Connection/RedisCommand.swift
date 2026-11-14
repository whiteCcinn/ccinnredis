import Foundation

/// One argument of a command: raw bytes, built from strings, numbers or keys.
public struct RedisArgument: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(_ text: String) { bytes = Array(text.utf8) }
    public init(stringLiteral value: String) { bytes = Array(value.utf8) }
    public init(integerLiteral value: Int) { bytes = Array(String(value).utf8) }

    public static func key(_ key: RedisKey) -> RedisArgument { RedisArgument(bytes: key.bytes) }
    public static func int(_ value: Int) -> RedisArgument { RedisArgument(bytes: Array(String(value).utf8)) }
    public static func int64(_ value: Int64) -> RedisArgument { RedisArgument(bytes: Array(String(value).utf8)) }
    public static func string(_ value: String) -> RedisArgument { RedisArgument(value) }
    public static func raw(_ bytes: [UInt8]) -> RedisArgument { RedisArgument(bytes: bytes) }

    /// Redis score/double syntax (`inf`, `-inf`, shortest round-trip decimal).
    public static func double(_ value: Double) -> RedisArgument {
        if value == .infinity { return "+inf" }
        if value == -.infinity { return "-inf" }
        if value.rounded() == value, abs(value) < 1e15 { return RedisArgument(String(Int64(value))) }
        return RedisArgument(String(value))
    }
}

/// A command ready to encode. The name is the first argument, upper-cased for lookups.
public struct RedisCommand: Sendable, Hashable, CustomStringConvertible {
    public var arguments: [[UInt8]]

    public init(_ name: String, _ arguments: [RedisArgument] = []) {
        self.arguments = [Array(name.utf8)] + arguments.map(\.bytes)
    }

    public init(rawArguments: [[UInt8]]) {
        arguments = rawArguments
    }

    public var name: String { arguments.first.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? "" }

    /// `CONFIG GET` → "CONFIG GET"; single-word commands return their name.
    public var qualifiedName: String {
        guard arguments.count > 1, CommandSpecs.containerCommands.contains(name) else { return name }
        return name + " " + String(decoding: arguments[1], as: UTF8.self).uppercased()
    }

    public func argument(_ index: Int) -> [UInt8]? { arguments.indices.contains(index) ? arguments[index] : nil }

    public var description: String {
        arguments.prefix(8).map { String(decoding: $0.prefix(64), as: UTF8.self) }.joined(separator: " ")
            + (arguments.count > 8 ? " …" : "")
    }
}

/// A key (binary-safe).
public struct RedisKey: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(_ text: String) { bytes = Array(text.utf8) }
    public init(bytes: [UInt8]) { self.bytes = bytes }

    /// Lossy UTF-8 text.
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    /// `true` when the bytes are valid UTF-8 without control characters (safe to show verbatim).
    public var isPrintable: Bool {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return false }
        return !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Display text: verbatim when printable, otherwise redis-cli style escapes (`\xff`).
    public var display: String { isPrintable ? string : RedisKey.escape(bytes) }

    public var description: String { display }

    public static func < (lhs: RedisKey, rhs: RedisKey) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public static func escape(_ bytes: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\\"): result += "\\\\"
            case UInt8(ascii: "\""): result += "\\\""
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x07: result += "\\a"
            case 0x08: result += "\\b"
            case 0x20...0x7E: result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                let hex = String(byte, radix: 16)
                result += "\\x" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return result
    }
}
