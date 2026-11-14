import Foundation

public enum ValueFormat: String, CaseIterable, Identifiable, Sendable {
    case text = "Text"
    case json = "JSON"
    case hex = "Hex"
    public var id: String { rawValue }
}

public struct ValueFormatError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Detection, rendering and parsing of binary-safe values for the editors.
public enum ValueFormatter {
    /// JSON when it parses as an object/array, text when valid UTF-8 with few control characters, else hex.
    public static func detect(_ bytes: [UInt8]) -> ValueFormat {
        guard let text = String(bytes: bytes.prefix(1 << 20), encoding: .utf8) else { return .hex }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "{" || first == "[", bytes.count <= 8 << 20, JSONPrettyPrinter.format(trimmed) != nil {
            return .json
        }
        let controls = text.unicodeScalars.prefix(4096).filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        return controls > 0 ? .hex : .text
    }

    /// Display text, truncated to roughly `limit` bytes of input.
    public static func render(_ bytes: [UInt8], as format: ValueFormat, limit: Int = 1 << 20) -> String {
        let clipped = bytes.count > limit ? Array(bytes.prefix(limit)) : bytes
        let suffix = bytes.count > limit ? "\n… (\(bytes.count - limit) more bytes not shown)" : ""
        switch format {
        case .text:
            return String(decoding: clipped, as: UTF8.self) + suffix
        case .json:
            let text = String(decoding: clipped, as: UTF8.self)
            return (JSONPrettyPrinter.format(text) ?? text) + suffix
        case .hex:
            return hexDump(clipped) + suffix
        }
    }

    /// `00000000  48 65 6c 6c 6f 2c 20 43  63 69 6e 6e 52 65 64 69  |Hello, CcinnRedi|`
    public static func hexDump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        let digits = Array("0123456789abcdef")
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var line = String(format: "%08x  ", offset)
            for (index, byte) in row.enumerated() {
                line.append(digits[Int(byte >> 4)])
                line.append(digits[Int(byte & 0x0F)])
                line.append(" ")
                if index == 7 { line.append(" ") }
            }
            if row.count < 16 {
                line += String(repeating: "   ", count: 16 - row.count) + (row.count <= 8 ? " " : "")
            }
            line += " |"
            for byte in row { line.append(byte >= 0x20 && byte < 0x7F ? Character(UnicodeScalar(byte)) : ".") }
            line += "|"
            lines.append(line)
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    /// Bytes to store for edited text in a format.
    public static func parse(_ text: String, as format: ValueFormat) throws -> [UInt8] {
        switch format {
        case .text:
            return Array(text.utf8)
        case .json:
            guard JSONPrettyPrinter.format(text) != nil else { throw ValueFormatError(message: "The text is not valid JSON") }
            return Array(text.utf8)
        case .hex:
            var result: [UInt8] = []
            for rawLine in text.split(whereSeparator: \.isNewline) {
                var line = Substring(rawLine)
                if let bar = line.firstIndex(of: "|") { line = line[..<bar] } // drop the ASCII column
                var tokens = line.split(whereSeparator: \.isWhitespace)
                if let first = tokens.first, first.count == 8, tokens.count > 1, first.allSatisfy(\.isHexDigit) { tokens.removeFirst() } // offset
                for token in tokens {
                    let characters = Array(token)
                    guard characters.count % 2 == 0 else { throw ValueFormatError(message: "'\(token)' is not a sequence of hex byte pairs") }
                    var index = 0
                    while index < characters.count {
                        guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                            throw ValueFormatError(message: "'\(token)' is not valid hex")
                        }
                        result.append(byte)
                        index += 2
                    }
                }
            }
            return result
        }
    }
}

/// Re-indents JSON without reordering keys or rewriting numbers; validates structure with an explicit
/// stack (no recursion), so hostile nesting cannot overflow the call stack.
public enum JSONPrettyPrinter {
    static let maxDepth = 512

    public static func format(_ text: String, indent: String = "  ") -> String? {
        reformat(text, indent: indent, pretty: true)
    }

    public static func minify(_ text: String) -> String? {
        reformat(text, indent: "", pretty: false)
    }

    private enum Container { case object, array }

    private static func reformat(_ text: String, indent: String, pretty: Bool) -> String? {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 4)
        var stack: [Container] = []
        var index = 0
        // Expectation flags for validation.
        var expectValue = true
        var expectKey = false
        var afterValue = false
        var sawRoot = false
        let indentBytes = Array(indent.utf8)

        func newline() {
            guard pretty else { return }
            output.append(0x0A)
            for _ in 0..<stack.count { output += indentBytes }
        }
        func skipSpace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }
        func scanString() -> Bool {
            guard index < bytes.count, bytes[index] == 0x22 else { return false }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x5C {
                    index += 2
                    continue
                }
                if byte == 0x22 {
                    index += 1
                    output += bytes[start..<index]
                    return true
                }
                if byte < 0x20 { return false }
                index += 1
            }
            return false
        }
        func scanLiteral() -> Bool {
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                let isLiteral = (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x65 || byte == 0x45
                    || (byte >= 0x61 && byte <= 0x7A)
                if !isLiteral { break }
                index += 1
            }
            guard index > start else { return false }
            let literal = bytes[start..<index]
            let word = String(decoding: literal, as: UTF8.self)
            if word == "true" || word == "false" || word == "null" || Double(word) != nil && !word.contains(where: { $0.isLetter && $0 != "e" && $0 != "E" }) {
                output += literal
                return true
            }
            return false
        }

        while true {
            skipSpace()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            switch byte {
            case 0x7B, 0x5B: // { [
                guard expectValue, !(sawRoot && stack.isEmpty), stack.count < maxDepth else { return nil }
                output.append(byte)
                index += 1
                stack.append(byte == 0x7B ? .object : .array)
                sawRoot = true
                skipSpace()
                let closer: UInt8 = byte == 0x7B ? 0x7D : 0x5D
                if index < bytes.count, bytes[index] == closer {
                    output.append(closer)
                    index += 1
                    stack.removeLast()
                    expectValue = false
                    expectKey = false
                    afterValue = true
                } else {
                    newline()
                    expectKey = byte == 0x7B
                    expectValue = byte == 0x5B
                    afterValue = false
                }
            case 0x7D, 0x5D: // } ]
                guard afterValue, let top = stack.last, (byte == 0x7D) == (top == .object) else { return nil }
                stack.removeLast()
                newline()
                output.append(byte)
                index += 1
                afterValue = true
                expectValue = false
                expectKey = false
            case 0x2C: // ,
                guard afterValue, let top = stack.last else { return nil }
                output.append(byte)
                index += 1
                newline()
                afterValue = false
                expectKey = top == .object
                expectValue = top == .array
            case 0x3A: // :
                guard !expectKey, !expectValue, !afterValue, stack.last == .object else { return nil }
                output.append(byte)
                if pretty { output.append(0x20) }
                index += 1
                expectValue = true
            case 0x22:
                if expectKey {
                    guard scanString() else { return nil }
                    expectKey = false
                    expectValue = false
                    afterValue = false
                    skipSpace()
                    guard index < bytes.count, bytes[index] == 0x3A else { return nil }
                } else {
                    guard expectValue, !(sawRoot && stack.isEmpty), scanString() else { return nil }
                    sawRoot = true
                    expectValue = false
                    afterValue = true
                }
            default:
                guard expectValue, !(sawRoot && stack.isEmpty), scanLiteral() else { return nil }
                sawRoot = true
                expectValue = false
                afterValue = true
            }
        }
        guard stack.isEmpty, sawRoot, afterValue else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
