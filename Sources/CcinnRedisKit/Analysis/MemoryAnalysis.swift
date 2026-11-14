import Foundation
import RedisKit
import RESPWire

/// Size of one sampled key.
public struct KeySample: Sendable, Hashable {
    public var key: RedisKey
    public var type: KeyType
    public var bytes: Int64
    /// `true` when estimated from lengths or DEBUG OBJECT instead of MEMORY USAGE.
    public var isEstimate: Bool
    public var ttlMilliseconds: Int64?
    public var elements: Int64?
    public var node: Endpoint?

    public init(key: RedisKey, type: KeyType, bytes: Int64, isEstimate: Bool, ttlMilliseconds: Int64?, elements: Int64?, node: Endpoint?) {
        self.key = key
        self.type = type
        self.bytes = bytes
        self.isEstimate = isEstimate
        self.ttlMilliseconds = ttlMilliseconds
        self.elements = elements
        self.node = node
    }
}

public enum TTLBucket: String, CaseIterable, Sendable, Hashable, Identifiable {
    case persistent = "No expiry"
    case underMinute = "< 1 min"
    case underHour = "< 1 hour"
    case underDay = "< 1 day"
    case underWeek = "< 7 days"
    case longer = "≥ 7 days"
    public var id: String { rawValue }

    static func bucket(for ttl: Int64?) -> TTLBucket {
        guard let ttl else { return .persistent }
        switch ttl {
        case ..<60_000: return .underMinute
        case ..<3_600_000: return .underHour
        case ..<86_400_000: return .underDay
        case ..<604_800_000: return .underWeek
        default: return .longer
        }
    }
}

public struct AnalysisReport: Sendable, Equatable {
    public struct TypeSummary: Sendable, Equatable, Identifiable {
        public var type: KeyType
        public var keys: Int
        public var bytes: Int64
        public var id: String { type.rawValue }
    }

    public struct PrefixSummary: Sendable, Equatable, Identifiable {
        public var prefix: String
        public var keys: Int
        public var bytes: Int64
        public var id: String { prefix }
    }

    public struct BucketSummary: Sendable, Equatable, Identifiable {
        public var bucket: TTLBucket
        public var keys: Int
        public var bytes: Int64
        public var id: String { bucket.rawValue }
    }

    public var sampledKeys: Int
    public var totalBytes: Int64
    public var usesEstimates: Bool
    public var byType: [TypeSummary]
    public var byPrefix: [PrefixSummary]
    public var ttlBuckets: [BucketSummary]
    public var topKeys: [KeySample]

    public static let empty = AnalysisReport(sampledKeys: 0, totalBytes: 0, usesEstimates: false, byType: [], byPrefix: [], ttlBuckets: [], topKeys: [])
}

/// Pure aggregation of samples (design D13): bounded top-N heap, per-type, per-prefix (bounded
/// cardinality) and TTL-bucket totals.
public struct MemoryAggregator: Sendable {
    public let topCount: Int
    public let delimiter: String
    public let prefixDepth: Int
    public let maxPrefixes: Int
    private var heap: [KeySample] = [] // min-heap by bytes
    private var types: [KeyType: (keys: Int, bytes: Int64)] = [:]
    private var prefixes: [String: (keys: Int, bytes: Int64)] = [:]
    private var other: (keys: Int, bytes: Int64) = (0, 0)
    private var buckets: [TTLBucket: (keys: Int, bytes: Int64)] = [:]
    private var count = 0
    private var total: Int64 = 0
    private var estimates = false

    static let noPrefix = "(no prefix)"
    static let otherPrefixes = "(other prefixes)"

    public init(topCount: Int = 100, delimiter: String = ":", prefixDepth: Int = 1, maxPrefixes: Int = 5_000) {
        self.topCount = max(1, topCount)
        self.delimiter = delimiter
        self.prefixDepth = max(1, prefixDepth)
        self.maxPrefixes = max(1, maxPrefixes)
    }

    public mutating func add(_ sample: KeySample) {
        count += 1
        total &+= sample.bytes
        estimates = estimates || sample.isEstimate
        let typeEntry = types[sample.type] ?? (0, 0)
        types[sample.type] = (typeEntry.keys + 1, typeEntry.bytes &+ sample.bytes)
        let bucket = TTLBucket.bucket(for: sample.ttlMilliseconds)
        let bucketEntry = buckets[bucket] ?? (0, 0)
        buckets[bucket] = (bucketEntry.keys + 1, bucketEntry.bytes &+ sample.bytes)

        let prefix = prefix(of: sample.key)
        if let existing = prefixes[prefix] {
            prefixes[prefix] = (existing.keys + 1, existing.bytes &+ sample.bytes)
        } else if prefixes.count < maxPrefixes {
            prefixes[prefix] = (1, sample.bytes)
        } else {
            other = (other.keys + 1, other.bytes &+ sample.bytes)
        }
        pushTop(sample)
    }

    private func prefix(of key: RedisKey) -> String {
        guard !delimiter.isEmpty else { return Self.noPrefix }
        let separator = Array(delimiter.utf8)
        var end = 0
        var depth = 0
        while depth < prefixDepth, let match = KeyTreeSnapshot.find(separator, in: key.bytes, from: end) {
            end = match + separator.count
            depth += 1
        }
        guard depth > 0 else { return Self.noPrefix }
        return RedisKey(bytes: Array(key.bytes[0..<end])).display + "*"
    }

    private mutating func pushTop(_ sample: KeySample) {
        if heap.count < topCount {
            heap.append(sample)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child].bytes < heap[parent].bytes else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        } else if let smallest = heap.first, sample.bytes > smallest.bytes {
            heap[0] = sample
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var candidate = parent
                if left < heap.count, heap[left].bytes < heap[candidate].bytes { candidate = left }
                if right < heap.count, heap[right].bytes < heap[candidate].bytes { candidate = right }
                guard candidate != parent else { break }
                heap.swapAt(parent, candidate)
                parent = candidate
            }
        }
    }

    public var report: AnalysisReport {
        var prefixSummaries = prefixes.map { AnalysisReport.PrefixSummary(prefix: $0.key, keys: $0.value.keys, bytes: $0.value.bytes) }
        if other.keys > 0 { prefixSummaries.append(AnalysisReport.PrefixSummary(prefix: Self.otherPrefixes, keys: other.keys, bytes: other.bytes)) }
        prefixSummaries.sort { ($0.bytes, $1.prefix) > ($1.bytes, $0.prefix) }
        return AnalysisReport(
            sampledKeys: count,
            totalBytes: total,
            usesEstimates: estimates,
            byType: types.map { AnalysisReport.TypeSummary(type: $0.key, keys: $0.value.keys, bytes: $0.value.bytes) }.sorted { $0.bytes > $1.bytes },
            byPrefix: prefixSummaries,
            ttlBuckets: TTLBucket.allCases.compactMap { bucket in
                buckets[bucket].map { AnalysisReport.BucketSummary(bucket: bucket, keys: $0.keys, bytes: $0.bytes) }
            },
            topKeys: heap.sorted { $0.bytes > $1.bytes }
        )
    }
}

/// Size estimates for servers without MEMORY USAGE (< 4.0, proxies).
public enum MemoryEstimator {
    public static func estimate(type: KeyType, length: Int64?) -> Int64 {
        guard type.exists else { return 0 }
        let length = max(0, length ?? 0)
        let overhead: Int64 = 56
        switch type {
        case .string: return overhead + length
        case .list, .set: return overhead + length.multipliedReportingOverflow(by: 24).partialValue
        case .hash, .zset: return overhead + length.multipliedReportingOverflow(by: 48).partialValue
        case .stream: return overhead + length.multipliedReportingOverflow(by: 64).partialValue
        default: return overhead + length
        }
    }

    /// `serializedlength:N` from a `DEBUG OBJECT` reply.
    public static func serializedLength(fromDebugObject text: String) -> Int64? {
        for token in text.split(separator: " ") where token.hasPrefix("serializedlength:") {
            return Int64(token.dropFirst("serializedlength:".count))
        }
        return nil
    }
}

/// Paces work to `perSecond` items (0 = unlimited).
public struct RateLimiter: Sendable {
    public let perSecond: Int
    private var consumed = 0

    public init(perSecond: Int) { self.perSecond = max(0, perSecond) }

    /// Delay to wait after consuming `count` more items, given seconds elapsed since the start.
    public mutating func delay(afterConsuming count: Int, elapsed: Double) -> Duration {
        consumed = consumed.addingReportingOverflow(max(0, count)).partialValue
        guard perSecond > 0 else { return .zero }
        let target = Double(consumed) / Double(perSecond)
        let wait = min(target - elapsed, 60)
        return wait > 0 ? .milliseconds(Int((wait * 1000).rounded())) : .zero
    }
}

/// Samples the keyspace off the main actor (design D13).
public actor MemoryAnalyzer {
    public struct Options: Sendable {
        public var pattern: String?
        public var maxKeys: Int
        public var keysPerSecond: Int
        public var batchSize: Int
        public var memorySamples: Int
        public var delimiter: String
        public var prefixDepth: Int
        public var topCount: Int

        public init(pattern: String? = nil, maxKeys: Int = 100_000, keysPerSecond: Int = 2_000, batchSize: Int = 200,
                    memorySamples: Int = 5, delimiter: String = ":", prefixDepth: Int = 1, topCount: Int = 100) {
            self.pattern = pattern
            self.maxKeys = max(1, maxKeys)
            self.keysPerSecond = max(0, keysPerSecond)
            self.batchSize = min(max(10, batchSize), 2_000)
            self.memorySamples = max(0, memorySamples)
            self.delimiter = delimiter
            self.prefixDepth = prefixDepth
            self.topCount = topCount
        }
    }

    public struct Progress: Sendable {
        public var sampled: Int
        public var completedNodes: Int
        public var totalNodes: Int
        public var elapsed: Double
        public var report: AnalysisReport
        public var method: String
    }

    private let client: RedisClient
    private let options: Options

    public init(client: RedisClient, options: Options) {
        self.client = client
        self.options = options
    }

    public func run(progress: @escaping @Sendable (Progress) -> Void) async throws -> AnalysisReport {
        let scanner = KeyScanner(client: client, pattern: options.pattern, type: nil, count: options.batchSize)
        var aggregator = MemoryAggregator(topCount: options.topCount, delimiter: options.delimiter, prefixDepth: options.prefixDepth)
        var limiter = RateLimiter(perSecond: options.keysPerSecond)
        let start = ContinuousClock.now
        var sampled = 0
        var useMemoryUsage = client.capabilities.supports(.memoryUsage)
        // DEBUG OBJECT is an admin command: never behind proxies (they reject or mis-route it) or read-only connections.
        var useDebugObject = !useMemoryUsage && !client.isReadOnly && !client.deployment.isProxy
        while sampled < options.maxKeys, let batch = try await scanner.next() {
            try Task.checkCancellation()
            let keys = Array(batch.keys.prefix(options.maxKeys - sampled))
            guard !keys.isEmpty else {
                // An empty page still cost the server a SCAN of `batchSize` slots: pace it like a full batch.
                let elapsed = Self.seconds(since: start)
                progress(Progress(sampled: sampled, completedNodes: batch.completedNodes, totalNodes: batch.totalNodes,
                                  elapsed: elapsed, report: aggregator.report, method: method(useMemoryUsage, useDebugObject)))
                let delay = limiter.delay(afterConsuming: options.batchSize, elapsed: elapsed)
                if delay > .zero { try await Task.sleep(for: delay) }
                continue
            }
            var commands: [RedisCommand] = []
            for key in keys {
                commands.append(RedisCommand("TYPE", [.key(key)]))
                commands.append(RedisCommand("PTTL", [.key(key)]))
                if useMemoryUsage {
                    commands.append(RedisCommand("MEMORY", ["USAGE", .key(key), "SAMPLES", .int(options.memorySamples)]))
                } else if useDebugObject {
                    commands.append(RedisCommand("DEBUG", ["OBJECT", .key(key)]))
                }
            }
            let stride = useMemoryUsage || useDebugObject ? 3 : 2
            let replies = try await client.pipeline(commands)
            var types: [KeyType] = []
            var ttls: [Int64?] = []
            var sizes: [Int64?] = []
            for index in keys.indices {
                types.append(KeyType(rawValue: replies[index * stride].string ?? "none"))
                let ttl = replies[index * stride + 1].int
                ttls.append(ttl.flatMap { $0 >= 0 ? $0 : nil })
                if stride == 3 {
                    let reply = replies[index * stride + 2]
                    if let message = reply.errorMessage, RedisError.looksLikeUnavailableCommand(message) || message.uppercased().hasPrefix("ERR DEBUG") {
                        if useMemoryUsage {
                            client.markUnavailable(.memoryUsage, reason: "MEMORY USAGE is not available: \(message)")
                            useMemoryUsage = false
                        }
                        useDebugObject = false
                        sizes.append(nil)
                    } else if useMemoryUsage {
                        sizes.append(reply.int)
                    } else {
                        sizes.append(MemoryEstimator.serializedLength(fromDebugObject: reply.string ?? ""))
                    }
                } else {
                    sizes.append(nil)
                }
            }
            // Element counts for keys without a measured size.
            let missing = keys.indices.filter { sizes[$0] == nil && types[$0].exists }
            var lengths: [Int: Int64] = [:]
            if !missing.isEmpty {
                let lengthCommands = missing.compactMap { RedisClient.lengthCommand(for: types[$0], key: keys[$0]) }
                if lengthCommands.count == missing.count {
                    let lengthReplies = try await client.pipeline(lengthCommands)
                    for (offset, index) in missing.enumerated() { lengths[index] = lengthReplies[offset].int }
                }
            }
            for index in keys.indices where types[index].exists {
                let measured = sizes[index]
                let bytes = measured ?? MemoryEstimator.estimate(type: types[index], length: lengths[index])
                aggregator.add(KeySample(key: keys[index], type: types[index], bytes: bytes, isEstimate: measured == nil || !useMemoryUsage,
                                         ttlMilliseconds: ttls[index], elements: lengths[index], node: batch.node))
            }
            sampled += keys.count
            let elapsed = Self.seconds(since: start)
            progress(Progress(sampled: sampled, completedNodes: batch.completedNodes, totalNodes: batch.totalNodes, elapsed: elapsed,
                              report: aggregator.report, method: method(useMemoryUsage, useDebugObject)))
            let delay = limiter.delay(afterConsuming: max(keys.count, options.batchSize), elapsed: elapsed)
            if delay > .zero { try await Task.sleep(for: delay) }
        }
        return aggregator.report
    }

    private func method(_ memoryUsage: Bool, _ debugObject: Bool) -> String {
        memoryUsage ? "MEMORY USAGE" : debugObject ? "DEBUG OBJECT (serialized size)" : "Estimated from element counts"
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

public enum AnalysisExport {
    public static func csv(_ report: AnalysisReport) -> String {
        var lines = ["key,type,bytes,estimate,ttl_ms,elements,node"]
        for sample in report.topKeys {
            lines.append([
                field(sample.key.display), field(sample.type.rawValue), String(sample.bytes), sample.isEstimate ? "true" : "false",
                sample.ttlMilliseconds.map(String.init) ?? "", sample.elements.map(String.init) ?? "", field(sample.node?.description ?? ""),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
