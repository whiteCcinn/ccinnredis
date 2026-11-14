import Foundation

/// Conversions from server-provided numbers that never trap: Redis replies (INFO, SLOWLOG, CLIENT LIST,
/// MEMORY USAGE…) may carry NaN, ±inf or values beyond the integer range.
public enum SafeNumber {
    /// `Int` from a Double, clamped to the representable range; nil for NaN.
    public static func int(_ value: Double) -> Int? {
        guard !value.isNaN else { return nil }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    /// `Int64` from a Double, clamped; nil for NaN.
    public static func int64(_ value: Double) -> Int64? {
        guard !value.isNaN else { return nil }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    /// `Int` from text such as an INFO field ("123", "1.5", "nan"); nil when not a finite number.
    public static func int(_ text: String) -> Int? {
        if let exact = Int(text) { return exact }
        guard let value = Double(text), value.isFinite else { return nil }
        return int(value)
    }

    /// A finite Double for charts and progress views (NaN/inf become nil).
    public static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// Sum that saturates instead of overflowing.
    public static func sum<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        values.reduce(0) { partial, next in
            let (result, overflow) = partial.addingReportingOverflow(next)
            return overflow ? (next > 0 ? Int64.max : Int64.min) : result
        }
    }

    /// A duration in seconds for display, clamped to a sane range.
    public static func seconds(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100 * 365 * 24 * 3600)
    }
}

/// Fixed-capacity FIFO that drops the oldest element; O(1) append (live MONITOR/Pub/Sub output).
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(self.capacity, 4096))
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Oldest first.
    public var elements: [Element] {
        guard head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }
}
