import Foundation

/// redis-cli compatible argument splitting (`sdssplitargs`): whitespace separated, double quotes with
/// `\n \r \t \b \a \\ \" \xHH` escapes, single quotes with `\'` only.
public enum CLITokenizer {
    public struct TokenizeError: Error, LocalizedError, Sendable, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func tokenize(_ line: String) throws -> [[UInt8]] {
        let bytes = Array(line.utf8)
        var tokens: [[UInt8]] = []
        var index = 0
        while true {
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { return tokens }
            var current: [UInt8] = []
            var inDouble = false
            var inSingle = false
            var done = false
            while !done {
                if inDouble {
                    guard index < bytes.count else { throw TokenizeError(message: "Unbalanced double quotes") }
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "\\"), index + 3 < bytes.count, bytes[index + 1] == UInt8(ascii: "x"),
                       let high = hexValue(bytes[index + 2]), let low = hexValue(bytes[index + 3]) {
                        current.append(high << 4 | low)
                        index += 3
                    } else if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                        index += 1
                        switch bytes[index] {
                        case UInt8(ascii: "n"): current.append(0x0A)
                        case UInt8(ascii: "r"): current.append(0x0D)
                        case UInt8(ascii: "t"): current.append(0x09)
                        case UInt8(ascii: "b"): current.append(0x08)
                        case UInt8(ascii: "a"): current.append(0x07)
                        default: current.append(bytes[index])
                        }
                    } else if byte == UInt8(ascii: "\"") {
                        guard index + 1 >= bytes.count || isSpace(bytes[index + 1]) else {
                            throw TokenizeError(message: "A closing quote must be followed by a space")
                        }
                        done = true
                    } else {
                        current.append(byte)
                    }
                } else if inSingle {
                    guard index < bytes.count else { throw TokenizeError(message: "Unbalanced single quotes") }
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "'") {
                        current.append(UInt8(ascii: "'"))
                        index += 1
                    } else if byte == UInt8(ascii: "'") {
                        guard index + 1 >= bytes.count || isSpace(bytes[index + 1]) else {
                            throw TokenizeError(message: "A closing quote must be followed by a space")
                        }
                        done = true
                    } else {
                        current.append(byte)
                    }
                } else {
                    guard index < bytes.count else { break }
                    let byte = bytes[index]
                    if isSpace(byte) {
                        done = true
                    } else if byte == UInt8(ascii: "\"") {
                        inDouble = true
                    } else if byte == UInt8(ascii: "'") {
                        inSingle = true
                    } else {
                        current.append(byte)
                    }
                }
                if index < bytes.count { index += 1 }
            }
            tokens.append(current)
        }
    }

    /// Completed tokens before the cursor and the partial token being typed (for completion).
    public struct Partial: Sendable, Equatable {
        public var completed: [[UInt8]]
        public var current: String
        /// UTF-16 offset where the current token starts (its opening quote if quoted).
        public var currentStart: Int
        public var isQuoted: Bool
    }

    public static func partial(_ text: String) -> Partial {
        var completed: [[UInt8]] = []
        var current = ""
        var start = 0
        var quote: Character?
        var inToken = false
        var offset = 0
        var characters = Array(text)
        if characters.count > 100_000 { characters = Array(characters.suffix(100_000)) }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let width = character.utf16.count
            if let open = quote {
                if character == "\\", index + 1 < characters.count {
                    current.append(characters[index + 1])
                    offset += width + characters[index + 1].utf16.count
                    index += 2
                    continue
                }
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character.isWhitespace {
                if inToken {
                    completed.append(Array(current.utf8))
                    current = ""
                    inToken = false
                }
            } else if character == "\"" || character == "'" {
                if !inToken {
                    inToken = true
                    start = offset
                }
                quote = character
            } else {
                if !inToken {
                    inToken = true
                    start = offset
                }
                current.append(character)
            }
            offset += width
            index += 1
        }
        if !inToken { start = offset }
        return Partial(completed: completed, current: current, currentStart: start, isQuoted: quote != nil)
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    /// Quotes a token for display/insertion when it contains whitespace, quotes or non-printables.
    public static func quote(_ bytes: [UInt8]) -> String {
        let needsQuotes = bytes.isEmpty || bytes.contains { $0 <= 0x20 || $0 == 0x22 || $0 == 0x27 || $0 == 0x5C || $0 == 0x7F }
        let text = String(bytes: bytes, encoding: .utf8)
        if !needsQuotes, let text { return text }
        return "\"" + ReplyFormatter.escape(bytes) + "\""
    }
}
