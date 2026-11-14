import Foundation
import RESPWire

/// redis-cli style rendering of replies (RESP2 and RESP3), bounded for huge replies.
public enum ReplyFormatter {
    public enum Style: Sendable {
        /// Like redis-cli in a terminal: quoted strings, `(integer)`, numbered aggregates.
        case readable
        /// Like `redis-cli --raw`: payloads verbatim, one element per line.
        case raw
    }

    public struct Limits: Sendable {
        public var maxElements: Int
        public var maxStringBytes: Int
        public init(maxElements: Int = 10_000, maxStringBytes: Int = 64 * 1024) {
            self.maxElements = max(1, maxElements)
            self.maxStringBytes = max(16, maxStringBytes)
        }
    }

    public static func format(_ value: RESPValue, style: Style = .readable, limits: Limits = Limits()) -> String {
        var budget = limits.maxElements
        var output = ""
        switch style {
        case .readable: appendReadable(value, indent: 0, into: &output, budget: &budget, limits: limits, depth: 0)
        case .raw: appendRaw(value, into: &output, budget: &budget, limits: limits, depth: 0)
        }
        return output
    }

    private static func appendReadable(_ value: RESPValue, indent: Int, into output: inout String, budget: inout Int,
                                       limits: Limits, depth: Int) {
        switch value {
        case let .simpleString(text): output += text
        case let .error(message): output += "(error) " + message
        case let .blobError(bytes): output += "(error) " + String(decoding: bytes.prefix(limits.maxStringBytes), as: UTF8.self)
        case let .integer(number): output += "(integer) \(number)"
        case .null: output += "(nil)"
        case let .double(number): output += "(double) " + (RESPValue.double(number).text ?? "\(number)")
        case let .boolean(flag): output += flag ? "(true)" : "(false)"
        case let .bigNumber(text): output += "(big number) " + text
        case let .bulkString(bytes): output += quoted(bytes, limit: limits.maxStringBytes)
        case let .verbatim(_, text): output += truncatedText(text, limit: limits.maxStringBytes)
        case let .array(elements), let .push(elements):
            appendAggregate(elements.map { ($0, nil) }, marker: ")", empty: "(empty array)", indent: indent, into: &output,
                            budget: &budget, limits: limits, depth: depth)
        case let .set(elements):
            appendAggregate(elements.map { ($0, nil) }, marker: "~", empty: "(empty set)", indent: indent, into: &output,
                            budget: &budget, limits: limits, depth: depth)
        case let .map(entries):
            appendAggregate(entries.map { ($0.key, $0.value) }, marker: "#", empty: "(empty hash)", indent: indent, into: &output,
                            budget: &budget, limits: limits, depth: depth)
        }
    }

    private static func appendAggregate(_ items: [(RESPValue, RESPValue?)], marker: String, empty: String, indent: Int,
                                        into output: inout String, budget: inout Int, limits: Limits, depth: Int) {
        guard !items.isEmpty else {
            output += empty
            return
        }
        guard depth < 32 else {
            output += "(… nested \(items.count) elements)"
            return
        }
        let width = String(items.count).count
        for (index, item) in items.enumerated() {
            if budget <= 0 {
                output += "\n" + String(repeating: " ", count: indent) + "… (\(items.count - index) more)"
                return
            }
            budget -= 1
            let number = String(index + 1)
            let label = String(repeating: " ", count: width - number.count) + number + marker + " "
            if index > 0 { output += "\n" + String(repeating: " ", count: indent) }
            output += label
            appendReadable(item.0, indent: indent + label.count, into: &output, budget: &budget, limits: limits, depth: depth + 1)
            if let value = item.1 {
                output += " => "
                appendReadable(value, indent: indent + label.count, into: &output, budget: &budget, limits: limits, depth: depth + 1)
            }
        }
    }

    private static func appendRaw(_ value: RESPValue, into output: inout String, budget: inout Int, limits: Limits, depth: Int) {
        switch value {
        case let .array(elements), let .set(elements), let .push(elements):
            guard depth < 32 else { return }
            for (index, element) in elements.enumerated() {
                if budget <= 0 {
                    output += "\n… (\(elements.count - index) more)"
                    return
                }
                budget -= 1
                if index > 0 { output += "\n" }
                appendRaw(element, into: &output, budget: &budget, limits: limits, depth: depth + 1)
            }
        case let .map(entries):
            guard depth < 32 else { return }
            for (index, entry) in entries.enumerated() {
                if budget <= 0 {
                    output += "\n… (\(entries.count - index) more)"
                    return
                }
                budget -= 1
                if index > 0 { output += "\n" }
                appendRaw(entry.key, into: &output, budget: &budget, limits: limits, depth: depth + 1)
                output += "\n"
                appendRaw(entry.value, into: &output, budget: &budget, limits: limits, depth: depth + 1)
            }
        case let .bulkString(bytes): output += truncatedText(bytes, limit: limits.maxStringBytes)
        case let .verbatim(_, text): output += truncatedText(text, limit: limits.maxStringBytes)
        case .null: output += ""
        default: output += value.text ?? ""
        }
    }

    private static func truncatedText(_ bytes: [UInt8], limit: Int) -> String {
        if bytes.count <= limit { return String(decoding: bytes, as: UTF8.self) }
        return String(decoding: bytes.prefix(limit), as: UTF8.self) + "…(\(bytes.count - limit) more bytes)"
    }

    private static func quoted(_ bytes: [UInt8], limit: Int) -> String {
        if bytes.count <= limit { return "\"" + escape(bytes) + "\"" }
        return "\"" + escape(Array(bytes.prefix(limit))) + "\"…(\(bytes.count - limit) more bytes)"
    }

    /// Escapes like redis-cli but keeps valid non-ASCII UTF-8 readable.
    public static func escape(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) {
            var result = ""
            result.reserveCapacity(text.utf8.count)
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\\": result += "\\\\"
                case "\"": result += "\\\""
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                case "\u{07}": result += "\\a"
                case "\u{08}": result += "\\b"
                default:
                    if scalar.value < 0x20 || scalar.value == 0x7F {
                        result += String(format: "\\x%02x", scalar.value)
                    } else {
                        result.unicodeScalars.append(scalar)
                    }
                }
            }
            return result
        }
        var result = ""
        for byte in bytes {
            switch byte {
            case 0x5C: result += "\\\\"
            case 0x22: result += "\\\""
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x07: result += "\\a"
            case 0x08: result += "\\b"
            case 0x20...0x7E: result.unicodeScalars.append(UnicodeScalar(byte))
            default: result += String(format: "\\x%02x", byte)
            }
        }
        return result
    }
}
