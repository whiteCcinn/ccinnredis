/// A protocol violation or a reply exceeding the configured limits. After this error the byte
/// stream is out of sync and the connection must be discarded.
public struct RESPError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case malformed
        case limitExceeded
        case unsupported
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

/// Hard bounds applied while decoding replies.
public struct RESPLimits: Sendable, Equatable {
    /// Largest accepted bulk string / blob error / verbatim string (Redis' `proto-max-bulk-len` default).
    public var maxBulkLength: Int
    /// Largest accepted number of elements in one aggregate (a map entry counts as two elements).
    public var maxAggregateCount: Int
    /// Deepest accepted nesting of aggregates.
    public var maxDepth: Int
    /// Longest accepted simple string / error / number line.
    public var maxLineLength: Int

    public init(maxBulkLength: Int = 512 * 1024 * 1024, maxAggregateCount: Int = 16 * 1024 * 1024,
                maxDepth: Int = 64, maxLineLength: Int = 16 * 1024 * 1024) {
        self.maxBulkLength = max(0, maxBulkLength)
        self.maxAggregateCount = max(0, maxAggregateCount)
        self.maxDepth = max(1, maxDepth)
        self.maxLineLength = max(16, maxLineLength)
    }
}

/// Overflow-safe number parsing on raw bytes.
enum RESPNumber {
    static func parseInteger(_ bytes: ArraySlice<UInt8>) -> Int64? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        var negative = false
        if bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        } else if bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        guard index < bytes.endIndex else { return nil }
        var value: Int64 = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Int64(byte - UInt8(ascii: "0"))
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (next, overflow2) = negative ? shifted.subtractingReportingOverflow(digit) : shifted.addingReportingOverflow(digit)
            guard !overflow1, !overflow2 else { return nil }
            value = next
            index += 1
        }
        return value
    }

    static func parseDouble(_ bytes: ArraySlice<UInt8>) -> Double? {
        guard !bytes.isEmpty, bytes.count <= 512 else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        switch text.lowercased() {
        case "inf", "+inf", "infinity", "+infinity": return .infinity
        case "-inf", "-infinity": return -.infinity
        case "nan", "-nan": return .nan
        default: break
        }
        // Only plain decimal notation (no hex floats or words).
        guard text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 101 || $0 == 69 || $0 == 43 || $0 == 45 }) else { return nil }
        return Double(text)
    }
}
