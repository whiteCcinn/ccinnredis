import Foundation

/// A JSON value for the MCP protocol (hand-written, no dependencies). Encodes to compact,
/// single-line JSON with sorted keys, so one message is always exactly one line.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value):
            if value.isFinite { try container.encode(value) } else { try container.encode(value.isNaN ? "nan" : value > 0 ? "inf" : "-inf") }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public var string: String? { if case let .string(value) = self { value } else { nil } }
    public var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case let .array(value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case let .object(value) = self { value } else { nil } }

    public var int: Int64? {
        switch self {
        case let .int(value): value
        case let .double(value): value.isFinite && value.rounded() == value ? Int64(exactly: value) : nil
        default: nil
        }
    }

    public var isNull: Bool { self == .null }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Single-line JSON text.
    public var compactString: String { String(decoding: compactData, as: UTF8.self) }

    public var compactData: Data { (try? Self.encoder.encode(self)) ?? Data("null".utf8) }

    public static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
}

/// Newline-delimited framing with a hard per-message limit. Oversized lines are reported once and
/// skipped up to the next newline, so a misbehaving client cannot exhaust memory.
public struct MCPLineFramer: Sendable {
    public enum Event: Sendable, Equatable {
        case line(Data)
        case oversized
    }

    public let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    public init(maxLineBytes: Int = 4 * 1024 * 1024) {
        self.maxLineBytes = max(16, maxLineBytes)
    }

    public mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            if byte == 0x0A {
                if discarding {
                    discarding = false
                } else {
                    var line = buffer
                    if line.last == 0x0D { line.removeLast() }
                    if !line.isEmpty { events.append(.line(line)) }
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if discarding { continue }
            buffer.append(byte)
            if buffer.count > maxLineBytes {
                buffer.removeAll()
                discarding = true
                events.append(.oversized)
            }
        }
        return events
    }
}
