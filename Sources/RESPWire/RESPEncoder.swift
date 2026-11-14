/// Encodes commands (arrays of bulk strings) and, for tests and fakes, arbitrary values.
public enum RESPEncoder {
    private static let crlf: [UInt8] = [13, 10]

    /// Encodes one command whose arguments are UTF-8 strings.
    public static func command(_ arguments: [String]) -> [UInt8] {
        command(arguments: arguments.map { Array($0.utf8) })
    }

    /// Encodes one command with binary-safe arguments.
    public static func command(arguments: [[UInt8]]) -> [UInt8] {
        var buffer: [UInt8] = []
        appendCommand(arguments: arguments, to: &buffer)
        return buffer
    }

    /// Appends one command to `buffer` (used to build pipelines with a single write).
    public static func appendCommand(arguments: [[UInt8]], to buffer: inout [UInt8]) {
        var size = 16
        for argument in arguments { size += argument.count + 16 }
        buffer.reserveCapacity(buffer.count + size)
        appendHeader(UInt8(ascii: "*"), arguments.count, to: &buffer)
        for argument in arguments {
            appendHeader(UInt8(ascii: "$"), argument.count, to: &buffer)
            buffer.append(contentsOf: argument)
            buffer.append(contentsOf: crlf)
        }
    }

    /// Encodes any value (RESP3 syntax for RESP3-only types).
    public static func encode(_ value: RESPValue) -> [UInt8] {
        var buffer: [UInt8] = []
        append(value, to: &buffer)
        return buffer
    }

    public static func append(_ value: RESPValue, to buffer: inout [UInt8]) {
        switch value {
        case let .simpleString(text):
            appendLine(UInt8(ascii: "+"), sanitize(text), to: &buffer)
        case let .error(text):
            appendLine(UInt8(ascii: "-"), sanitize(text), to: &buffer)
        case let .integer(number):
            appendLine(UInt8(ascii: ":"), String(number), to: &buffer)
        case let .bulkString(bytes):
            appendBlob(UInt8(ascii: "$"), bytes, to: &buffer)
        case .null:
            buffer.append(contentsOf: Array("_\r\n".utf8))
        case let .array(values):
            appendHeader(UInt8(ascii: "*"), values.count, to: &buffer)
            for element in values { append(element, to: &buffer) }
        case let .double(number):
            appendLine(UInt8(ascii: ","), RESPValue.format(double: number), to: &buffer)
        case let .boolean(flag):
            appendLine(UInt8(ascii: "#"), flag ? "t" : "f", to: &buffer)
        case let .blobError(bytes):
            appendBlob(UInt8(ascii: "!"), bytes, to: &buffer)
        case let .verbatim(format, text):
            var prefix = Array(format.utf8.prefix(3))
            while prefix.count < 3 { prefix.append(UInt8(ascii: " ")) }
            prefix.append(UInt8(ascii: ":"))
            appendBlob(UInt8(ascii: "="), prefix + text, to: &buffer)
        case let .bigNumber(text):
            appendLine(UInt8(ascii: "("), text, to: &buffer)
        case let .map(entries):
            appendHeader(UInt8(ascii: "%"), entries.count, to: &buffer)
            for entry in entries {
                append(entry.key, to: &buffer)
                append(entry.value, to: &buffer)
            }
        case let .set(values):
            appendHeader(UInt8(ascii: "~"), values.count, to: &buffer)
            for element in values { append(element, to: &buffer) }
        case let .push(values):
            appendHeader(UInt8(ascii: ">"), values.count, to: &buffer)
            for element in values { append(element, to: &buffer) }
        }
    }

    private static func appendHeader(_ marker: UInt8, _ count: Int, to buffer: inout [UInt8]) {
        buffer.append(marker)
        buffer.append(contentsOf: String(count).utf8)
        buffer.append(contentsOf: crlf)
    }

    private static func appendLine(_ marker: UInt8, _ text: String, to buffer: inout [UInt8]) {
        buffer.append(marker)
        buffer.append(contentsOf: text.utf8)
        buffer.append(contentsOf: crlf)
    }

    private static func appendBlob(_ marker: UInt8, _ bytes: [UInt8], to buffer: inout [UInt8]) {
        appendHeader(marker, bytes.count, to: &buffer)
        buffer.append(contentsOf: bytes)
        buffer.append(contentsOf: crlf)
    }

    /// Simple strings and errors cannot contain CR or LF.
    private static func sanitize(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else { return text }
        return String(text.map { $0 == "\r" || $0 == "\n" || $0 == "\r\n" ? " " : $0 })
    }
}
