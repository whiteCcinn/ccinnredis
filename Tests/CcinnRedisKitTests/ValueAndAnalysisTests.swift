import Foundation
import RedisKit
import Testing
@testable import CcinnRedisKit

@Suite("Value formats")
struct ValueFormatTests {
    @Test func detection() {
        #expect(ValueFormatter.detect(Array(#"{"a":1}"#.utf8)) == .json)
        #expect(ValueFormatter.detect(Array("[1, 2, 3]".utf8)) == .json)
        #expect(ValueFormatter.detect(Array("hello world".utf8)) == .text)
        #expect(ValueFormatter.detect(Array("42".utf8)) == .text)
        #expect(ValueFormatter.detect([0x00, 0x01, 0xFF, 0xFE]) == .hex)
        #expect(ValueFormatter.detect(Array("{not json".utf8)) == .text)
        #expect(ValueFormatter.detect(Array("吉隆坡".utf8)) == .text)
    }

    @Test func prettyJSONPreservesKeyOrderAndNumbers() throws {
        let pretty = try #require(JSONPrettyPrinter.format(#"{"z":1,"a":[1.50,true,null,{"k":"v \"q\""}],"e":{}}"#))
        #expect(pretty == """
        {
          "z": 1,
          "a": [
            1.50,
            true,
            null,
            {
              "k": "v \\"q\\""
            }
          ],
          "e": {}
        }
        """)
        #expect(JSONPrettyPrinter.format("{\"a\":}") == nil)
        #expect(JSONPrettyPrinter.format("[1,2") == nil)
        #expect(JSONPrettyPrinter.format("\"just a string\"") == "\"just a string\"")
        #expect(JSONPrettyPrinter.minify("{\n  \"a\" : [ 1, 2 ]\n}") == #"{"a":[1,2]}"#)
    }

    @Test func deeplyNestedJSONDoesNotRecurseUnbounded() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(JSONPrettyPrinter.format(deep) == nil) // rejected beyond the depth limit, no stack overflow
    }

    @Test func hexDumpAndParsing() throws {
        let dump = ValueFormatter.hexDump(Array("Hello, CcinnRedis!".utf8))
        #expect(dump.hasPrefix("00000000  48 65 6c 6c 6f 2c 20 43  63 69 6e 6e 52 65 64 69  |Hello, CcinnRedi|"))
        #expect(dump.contains("00000010  73 21"))
        #expect(try ValueFormatter.parse("48 65 6C\n6c 6f", as: .hex) == Array("Hello".utf8))
        #expect(try ValueFormatter.parse("00000000  48 65  |He|", as: .hex) == Array("He".utf8))
        #expect(throws: (any Error).self) { try ValueFormatter.parse("4", as: .hex) }
        #expect(throws: (any Error).self) { try ValueFormatter.parse("zz", as: .hex) }
        #expect(throws: (any Error).self) { try ValueFormatter.parse("{bad", as: .json) }
        #expect(try ValueFormatter.parse("{ \"a\": 1 }", as: .json) == Array("{ \"a\": 1 }".utf8))
    }

    @Test func renderingIsBounded() {
        let big = [UInt8](repeating: 0x41, count: 5_000_000)
        let text = ValueFormatter.render(big, as: .hex, limit: 4096)
        #expect(text.count < 30_000)
        #expect(text.contains("more bytes"))
    }
}

@Suite("Memory analysis")
struct MemoryAnalysisTests {
    private func sample(_ key: String, _ type: KeyType, _ bytes: Int64, ttl: Int64? = nil) -> KeySample {
        KeySample(key: RedisKey(key), type: type, bytes: bytes, isEstimate: false, ttlMilliseconds: ttl, elements: nil, node: nil)
    }

    @Test func aggregatesByTypePrefixAndTTL() {
        var aggregator = MemoryAggregator(topCount: 2, delimiter: ":", prefixDepth: 1)
        aggregator.add(sample("user:1", .hash, 100))
        aggregator.add(sample("user:2", .hash, 300, ttl: 300_000))
        aggregator.add(sample("cache:a", .string, 50, ttl: 7_200_000))
        aggregator.add(sample("plain", .string, 10))
        let report = aggregator.report
        #expect(report.sampledKeys == 4)
        #expect(report.totalBytes == 460)
        #expect(report.topKeys.map(\.key.string) == ["user:2", "user:1"])
        #expect(report.byType.first?.type == .hash)
        #expect(report.byType.first?.bytes == 400)
        #expect(report.byPrefix.first?.prefix == "user:*")
        #expect(report.byPrefix.first?.keys == 2)
        #expect(report.byPrefix.contains { $0.prefix == "(no prefix)" })
        let buckets = Dictionary(uniqueKeysWithValues: report.ttlBuckets.map { ($0.bucket, $0.keys) })
        #expect(buckets[.persistent] == 2)
        #expect(buckets[.underHour] == 1)
        #expect(buckets[.underDay] == 1)
    }

    @Test func topKeysUseABoundedHeap() {
        var aggregator = MemoryAggregator(topCount: 10, delimiter: ":", prefixDepth: 1)
        for index in 0..<10_000 { aggregator.add(sample("k:\(index)", .string, Int64(index))) }
        let top = aggregator.report.topKeys
        #expect(top.count == 10)
        #expect(top.first?.bytes == 9999)
        #expect(top.last?.bytes == 9990)
    }

    @Test func prefixCardinalityIsBounded() {
        var aggregator = MemoryAggregator(topCount: 1, delimiter: ":", prefixDepth: 1, maxPrefixes: 3)
        for index in 0..<10 { aggregator.add(sample("p\(index):x", .string, 1)) }
        let prefixes = aggregator.report.byPrefix
        #expect(prefixes.count == 4)
        #expect(prefixes.contains { $0.prefix == "(other prefixes)" && $0.keys == 7 })
    }

    @Test func estimatesFromLengthsWhenMemoryUsageIsMissing() {
        #expect(MemoryEstimator.estimate(type: .string, length: 1000) > 1000)
        #expect(MemoryEstimator.estimate(type: .hash, length: 10) > 0)
        #expect(MemoryEstimator.estimate(type: .none, length: nil) == 0)
        #expect(MemoryEstimator.serializedLength(fromDebugObject: "Value at:0x7f refcount:1 encoding:raw serializedlength:12345 lru:1 lru_seconds_idle:3") == 12345)
        #expect(MemoryEstimator.serializedLength(fromDebugObject: "ERR") == nil)
    }

    @Test func rateLimiterPacesBatches() {
        var limiter = RateLimiter(perSecond: 1000)
        #expect(limiter.delay(afterConsuming: 500, elapsed: 0) == .milliseconds(500))
        #expect(limiter.delay(afterConsuming: 500, elapsed: 2) == .zero)
        var unlimited = RateLimiter(perSecond: 0)
        #expect(unlimited.delay(afterConsuming: 1_000_000, elapsed: 0) == .zero)
    }

    @Test func csvExportEscapes() {
        var aggregator = MemoryAggregator(topCount: 5, delimiter: ":", prefixDepth: 1)
        aggregator.add(sample("a,\"b\"", .string, 10))
        let csv = AnalysisExport.csv(aggregator.report)
        #expect(csv.hasPrefix("key,type,bytes,estimate,ttl_ms,elements,node\n"))
        #expect(csv.contains("\"a,\"\"b\"\"\",string,10,false,,,"))
    }
}
