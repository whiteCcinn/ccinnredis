/// Incremental, bounded RESP2/RESP3 decoder.
///
/// Feed bytes with `append(_:)` and pull complete values with `next()`. Partially received
/// aggregates are kept on an explicit stack of frames, so already decoded elements are never parsed
/// again: decoding a reply that arrives in many chunks costs O(total bytes). Only an incomplete
/// scalar (e.g. a bulk string whose payload is still arriving) is re-examined, and only its header.
///
/// Every declared size is checked against `RESPLimits` before it is trusted, capacity reservations
/// are clamped, and number parsing never traps. After an error the parser must be discarded.
public struct RESPParser: Sendable {
    public let limits: RESPLimits

    private enum AggregateKind: Sendable {
        case array, set, push, map, attribute
    }

    private struct Frame: Sendable {
        let kind: AggregateKind
        var remaining: Int
        var elements: [RESPValue]
    }

    private enum Token {
        case value(RESPValue)
        case aggregate(AggregateKind, count: Int)
    }

    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var stack: [Frame] = []
    /// Resume point for the CR search of a long line that is still arriving (avoids rescanning it).
    private var pendingLine: (start: Int, scanFrom: Int)?

    /// Header lines (`$123`, `*4`) are short; anything longer is garbage.
    private static let maxHeaderLength = 32

    public init(limits: RESPLimits = RESPLimits()) {
        self.limits = limits
    }

    /// Bytes received but not yet consumed by a completed token.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    /// `true` while an aggregate has been started but not completed.
    public var isInsideAggregate: Bool { !stack.isEmpty }

    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        compactIfNeeded()
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete top-level value, `nil` when more bytes are needed, or throws on a
    /// protocol violation.
    public mutating func next() throws -> RESPValue? {
        while true {
            guard let token = try readToken() else { return nil }
            var completed: RESPValue?
            switch token {
            case let .value(value):
                completed = value
            case let .aggregate(kind, count):
                if count == 0 {
                    if kind == .attribute { continue }
                    completed = Self.build(kind, elements: [])
                } else {
                    guard stack.count < limits.maxDepth else {
                        throw RESPError(.limitExceeded, "Reply nesting exceeds the limit of \(limits.maxDepth) levels")
                    }
                    let elementCount = (kind == .map || kind == .attribute) ? count * 2 : count
                    var elements: [RESPValue] = []
                    elements.reserveCapacity(Swift.min(elementCount, 1024))
                    stack.append(Frame(kind: kind, remaining: elementCount, elements: elements))
                    continue
                }
            }
            // Fold the completed value into its parent frames.
            while let value = completed {
                guard !stack.isEmpty else { return value }
                let top = stack.count - 1
                stack[top].elements.append(value)
                stack[top].remaining -= 1
                if stack[top].remaining > 0 {
                    completed = nil
                } else if let frame = stack.popLast() {
                    // Attributes annotate the following value and are dropped.
                    completed = frame.kind == .attribute ? nil : Self.build(frame.kind, elements: frame.elements)
                }
            }
        }
    }

    // MARK: Tokens

    private mutating func readToken() throws -> Token? {
        guard readIndex < buffer.count else { return nil }
        let marker = buffer[readIndex]
        switch marker {
        case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: ":"), UInt8(ascii: "_"),
             UInt8(ascii: ","), UInt8(ascii: "#"), UInt8(ascii: "("):
            guard let line = try readLine(maxLength: limits.maxLineLength) else { return nil }
            return .value(try decodeLine(marker: marker, line))
        case UInt8(ascii: "$"), UInt8(ascii: "!"), UInt8(ascii: "="):
            return try readBlob(marker: marker)
        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: "%"), UInt8(ascii: ">"), UInt8(ascii: "|"):
            let start = readIndex
            guard let line = try readLine(maxLength: Self.maxHeaderLength) else { return nil }
            guard let declared = RESPNumber.parseInteger(line), let count = Int(exactly: declared) else {
                readIndex = start
                throw RESPError(.malformed, "Invalid aggregate length '\(Self.printable(line))'")
            }
            if count == -1, marker == UInt8(ascii: "*") { return .value(.null) }
            guard count >= 0 else { throw RESPError(.malformed, "Negative aggregate length \(count)") }
            let kind: AggregateKind = switch marker {
            case UInt8(ascii: "~"): .set
            case UInt8(ascii: "%"): .map
            case UInt8(ascii: ">"): .push
            case UInt8(ascii: "|"): .attribute
            default: .array
            }
            // Map and attribute entries hold two values each; `count <= max` first keeps `* 2` safe.
            let elementCount = (kind == .map || kind == .attribute) && count <= limits.maxAggregateCount ? count * 2 : count
            guard elementCount <= limits.maxAggregateCount else {
                throw RESPError(.limitExceeded, "Reply declares \(elementCount) elements; the limit is \(limits.maxAggregateCount)")
            }
            return .aggregate(kind, count: count)
        default:
            throw RESPError(.malformed, Self.describeUnexpected(buffer[readIndex...]))
        }
    }

    /// Reads `$`, `!` and `=` values once header and payload are fully buffered.
    private mutating func readBlob(marker: UInt8) throws -> Token? {
        let start = readIndex
        guard let line = try readLine(maxLength: Self.maxHeaderLength) else { return nil }
        guard let declared = RESPNumber.parseInteger(line), let length = Int(exactly: declared) else {
            throw RESPError(.malformed, "Invalid bulk length '\(Self.printable(line))'")
        }
        if length == -1, marker == UInt8(ascii: "$") { return .value(.null) }
        guard length >= 0 else { throw RESPError(.malformed, "Negative bulk length \(length)") }
        guard length <= limits.maxBulkLength else {
            throw RESPError(.limitExceeded, "Reply declares a \(length)-byte string; the limit is \(limits.maxBulkLength) bytes")
        }
        let payloadStart = readIndex
        // `length <= maxBulkLength` keeps this addition far from overflow.
        guard buffer.count - payloadStart >= length + 2 else {
            readIndex = start // wait for the whole payload; only the short header is re-read
            return nil
        }
        let payloadEnd = payloadStart + length
        guard buffer[payloadEnd] == 13, buffer[payloadEnd + 1] == 10 else {
            throw RESPError(.malformed, "Bulk string of \(length) bytes is not terminated by CRLF")
        }
        let payload = Array(buffer[payloadStart..<payloadEnd])
        readIndex = payloadEnd + 2
        switch marker {
        case UInt8(ascii: "!"):
            return .value(.blobError(payload))
        case UInt8(ascii: "="):
            guard payload.count >= 4, payload[3] == UInt8(ascii: ":") else {
                throw RESPError(.malformed, "Verbatim string lacks its 'fmt:' prefix")
            }
            return .value(.verbatim(format: String(decoding: payload[0..<3], as: UTF8.self), text: Array(payload[4...])))
        default:
            return .value(.bulkString(payload))
        }
    }

    private func decodeLine(marker: UInt8, _ line: ArraySlice<UInt8>) throws -> RESPValue {
        switch marker {
        case UInt8(ascii: "+"):
            return .simpleString(String(decoding: line, as: UTF8.self))
        case UInt8(ascii: "-"):
            return .error(String(decoding: line, as: UTF8.self))
        case UInt8(ascii: ":"):
            guard let value = RESPNumber.parseInteger(line) else {
                throw RESPError(.malformed, "Invalid integer reply '\(Self.printable(line))'")
            }
            return .integer(value)
        case UInt8(ascii: "_"):
            guard line.isEmpty else { throw RESPError(.malformed, "Invalid null reply") }
            return .null
        case UInt8(ascii: ","):
            guard let value = RESPNumber.parseDouble(line) else {
                throw RESPError(.malformed, "Invalid double reply '\(Self.printable(line))'")
            }
            return .double(value)
        case UInt8(ascii: "#"):
            if line.elementsEqual([UInt8(ascii: "t")]) { return .boolean(true) }
            if line.elementsEqual([UInt8(ascii: "f")]) { return .boolean(false) }
            throw RESPError(.malformed, "Invalid boolean reply '\(Self.printable(line))'")
        default: // "("
            var digits = line
            if digits.first == UInt8(ascii: "-") || digits.first == UInt8(ascii: "+") { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                throw RESPError(.malformed, "Invalid big number '\(Self.printable(line))'")
            }
            return .bigNumber(String(decoding: line, as: UTF8.self))
        }
    }

    /// Returns the bytes between the type marker and CRLF and advances past CRLF, or `nil` when the
    /// line is incomplete.
    private mutating func readLine(maxLength: Int) throws -> ArraySlice<UInt8>? {
        let contentStart = readIndex + 1
        var scan = contentStart
        if let pending = pendingLine, pending.start == readIndex { scan = Swift.max(contentStart, pending.scanFrom) }
        while scan < buffer.count {
            if buffer[scan] == 13 {
                guard scan + 1 < buffer.count else { break }
                guard buffer[scan + 1] == 10 else { throw RESPError(.malformed, "Line is not terminated by CRLF") }
                pendingLine = nil
                let line = buffer[contentStart..<scan]
                readIndex = scan + 2
                return line
            }
            if buffer[scan] == 10 { throw RESPError(.malformed, "Line contains a bare LF") }
            scan += 1
        }
        if scan - contentStart > maxLength {
            throw RESPError(.limitExceeded, "Reply line exceeds \(maxLength) bytes without CRLF")
        }
        pendingLine = (readIndex, scan)
        return nil
    }

    // MARK: Helpers

    private static func build(_ kind: AggregateKind, elements: [RESPValue]) -> RESPValue {
        switch kind {
        case .array: return .array(elements)
        case .set: return .set(elements)
        case .push: return .push(elements)
        case .map, .attribute:
            var entries: [RESPPair] = []
            entries.reserveCapacity(elements.count / 2)
            var index = 0
            while index + 1 < elements.count {
                entries.append(RESPPair(elements[index], elements[index + 1]))
                index += 2
            }
            return .map(entries)
        }
    }

    private mutating func compactIfNeeded() {
        if readIndex == buffer.count {
            if readIndex > 0 {
                buffer.removeAll(keepingCapacity: buffer.capacity <= 1 << 20)
                readIndex = 0
                pendingLine = nil
            }
        } else if readIndex >= 1 << 16, readIndex * 2 >= buffer.count {
            buffer.removeSubrange(0..<readIndex)
            if let pending = pendingLine { pendingLine = (pending.start - readIndex, pending.scanFrom - readIndex) }
            readIndex = 0
        }
    }

    static func printable(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix(40), as: UTF8.self)
            .unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "." : String($0) }.joined()
    }

    static func describeUnexpected(_ bytes: ArraySlice<UInt8>) -> String {
        let head = String(decoding: bytes.prefix(16), as: UTF8.self)
        if head.hasPrefix("HTTP/") {
            return "Received an HTTP response — this endpoint is a web server, not Redis"
        }
        if let first = bytes.first, first == 0x15 || first == 0x16 {
            return "Received TLS data — the server expects TLS; enable TLS for this connection"
        }
        let byte = bytes.first ?? 0
        let character = byte >= 0x20 && byte < 0x7F ? " ('\(Character(UnicodeScalar(byte)))')" : ""
        return "Unexpected byte 0x\(String(byte, radix: 16, uppercase: true))\(character) at the start of a reply — the peer does not speak the Redis protocol"
    }
}
