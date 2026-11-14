/// One RESP2 or RESP3 value. Payloads are kept as raw bytes (Redis strings are binary-safe);
/// text accessors decode lossily so invalid UTF-8 never fails.
public enum RESPValue: Sendable, Hashable {
    /// `+OK`
    case simpleString(String)
    /// `-ERR message` (simple error)
    case error(String)
    /// `:42`
    case integer(Int64)
    /// `$5 hello`
    case bulkString([UInt8])
    /// RESP2 null bulk string / null array, RESP3 `_`.
    case null
    /// `*N`
    case array([RESPValue])
    /// RESP3 `,1.5` (also `inf`, `-inf`, `nan`).
    case double(Double)
    /// RESP3 `#t` / `#f`.
    case boolean(Bool)
    /// RESP3 `!N` bulk error.
    case blobError([UInt8])
    /// RESP3 `=N fmt:text` verbatim string; `format` is the 3-character type (`txt`, `mkd`).
    case verbatim(format: String, text: [UInt8])
    /// RESP3 `(` arbitrary-precision integer, kept as its decimal text.
    case bigNumber(String)
    /// RESP3 `%N` map, order preserved.
    case map([RESPPair])
    /// RESP3 `~N` set.
    case set([RESPValue])
    /// RESP3 `>N` out-of-band push (Pub/Sub messages, invalidations).
    case push([RESPValue])
}

/// Key/value entry of a RESP3 map.
public struct RESPPair: Sendable, Hashable {
    public var key: RESPValue
    public var value: RESPValue

    public init(_ key: RESPValue, _ value: RESPValue) {
        self.key = key
        self.value = value
    }
}

extension RESPValue {
    /// Raw bytes of string-like values.
    public var bytes: [UInt8]? {
        switch self {
        case let .bulkString(bytes): bytes
        case let .simpleString(text): Array(text.utf8)
        case let .verbatim(_, text): text
        case let .blobError(bytes): bytes
        case let .error(text): Array(text.utf8)
        case let .bigNumber(text): Array(text.utf8)
        default: nil
        }
    }

    /// Text of string-like values (lossy UTF-8). `nil` for numbers, aggregates and null.
    public var string: String? {
        switch self {
        case let .bulkString(bytes): String(decoding: bytes, as: UTF8.self)
        case let .simpleString(text): text
        case let .verbatim(_, text): String(decoding: text, as: UTF8.self)
        default: nil
        }
    }

    /// Text of any scalar, including numbers and booleans.
    public var text: String? {
        switch self {
        case let .integer(value): String(value)
        case let .double(value): RESPValue.format(double: value)
        case let .boolean(value): value ? "true" : "false"
        case let .bigNumber(value): value
        case let .error(message): message
        case let .blobError(bytes): String(decoding: bytes, as: UTF8.self)
        default: string
        }
    }

    public var int: Int64? {
        switch self {
        case let .integer(value): value
        case let .bulkString(bytes): RESPNumber.parseInteger(bytes[...])
        case let .simpleString(text): RESPNumber.parseInteger(Array(text.utf8)[...])
        case let .bigNumber(text): Int64(text)
        case let .double(value): value.isFinite && value.rounded() == value ? Int64(exactly: value) : nil
        case let .boolean(value): value ? 1 : 0
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case let .double(value): value
        case let .integer(value): Double(value)
        case let .bulkString(bytes): RESPNumber.parseDouble(bytes[...])
        case let .simpleString(text): RESPNumber.parseDouble(Array(text.utf8)[...])
        case let .bigNumber(text): Double(text)
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case let .boolean(value): value
        case let .integer(value): value != 0
        default: nil
        }
    }

    /// Elements of arrays, sets and pushes.
    public var array: [RESPValue]? {
        switch self {
        case let .array(values), let .set(values), let .push(values): values
        default: nil
        }
    }

    /// Entries of a RESP3 map or of a RESP2 flat `[k1, v1, k2, v2]` array.
    public var pairs: [RESPPair]? {
        switch self {
        case let .map(entries):
            return entries
        case let .array(values):
            guard values.count % 2 == 0 else { return nil }
            var entries: [RESPPair] = []
            entries.reserveCapacity(values.count / 2)
            var index = 0
            while index + 1 < values.count {
                entries.append(RESPPair(values[index], values[index + 1]))
                index += 2
            }
            return entries
        default:
            return nil
        }
    }

    /// Looks up a field by name in a map or flat key/value array (case-sensitive).
    public subscript(field: String) -> RESPValue? {
        pairs?.first { $0.key.string == field }?.value
    }

    public var isNull: Bool { if case .null = self { true } else { false } }

    public var isError: Bool {
        switch self {
        case .error, .blobError: true
        default: false
        }
    }

    /// Message of simple and blob errors.
    public var errorMessage: String? {
        switch self {
        case let .error(message): message
        case let .blobError(bytes): String(decoding: bytes, as: UTF8.self)
        default: nil
        }
    }

    static func format(double value: Double) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        if value == -.infinity { return "-inf" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
