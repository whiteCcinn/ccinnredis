import Testing
@testable import RESPWire

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func parseAll(_ text: String, limits: RESPLimits = RESPLimits()) throws -> [RESPValue] {
    var parser = RESPParser(limits: limits)
    parser.append(bytes(text))
    var values: [RESPValue] = []
    while let value = try parser.next() { values.append(value) }
    return values
}

private func parseOne(_ text: String, limits: RESPLimits = RESPLimits()) throws -> RESPValue? {
    try parseAll(text, limits: limits).first
}

@Suite("RESP2 decoding")
struct RESP2DecodingTests {
    @Test func simpleStringErrorAndInteger() throws {
        #expect(try parseOne("+OK\r\n") == .simpleString("OK"))
        #expect(try parseOne("-ERR unknown command 'FOO'\r\n") == .error("ERR unknown command 'FOO'"))
        #expect(try parseOne(":1000\r\n") == .integer(1000))
        #expect(try parseOne(":-42\r\n") == .integer(-42))
        #expect(try parseOne(":+7\r\n") == .integer(7))
    }

    @Test func bulkStrings() throws {
        #expect(try parseOne("$5\r\nhello\r\n") == .bulkString(bytes("hello")))
        #expect(try parseOne("$0\r\n\r\n") == .bulkString([]))
        #expect(try parseOne("$-1\r\n") == .null)
        // Payload may itself contain CRLF.
        #expect(try parseOne("$4\r\na\r\nb\r\n") == .bulkString(bytes("a\r\nb")))
    }

    @Test func binarySafeBulkString() throws {
        let payload = (0...255).map { UInt8($0) }
        var parser = RESPParser()
        parser.append(bytes("$256\r\n") + payload + bytes("\r\n"))
        #expect(try parser.next() == .bulkString(payload))
    }

    @Test func arrays() throws {
        #expect(try parseOne("*0\r\n") == .array([]))
        #expect(try parseOne("*-1\r\n") == .null)
        #expect(try parseOne("*2\r\n$3\r\nfoo\r\n:1\r\n") == .array([.bulkString(bytes("foo")), .integer(1)]))
        #expect(try parseOne("*2\r\n*1\r\n:1\r\n*2\r\n+a\r\n$-1\r\n")
            == .array([.array([.integer(1)]), .array([.simpleString("a"), .null])]))
        // Empty aggregates nested in aggregates complete their parent correctly.
        #expect(try parseOne("*3\r\n*0\r\n*-1\r\n:5\r\n") == .array([.array([]), .null, .integer(5)]))
    }

    @Test func severalValuesInOneBuffer() throws {
        let values = try parseAll("+OK\r\n:1\r\n$1\r\nx\r\n*1\r\n+y\r\n")
        #expect(values == [.simpleString("OK"), .integer(1), .bulkString([0x78]), .array([.simpleString("y")])])
    }
}

@Suite("RESP3 decoding")
struct RESP3DecodingTests {
    @Test func scalars() throws {
        #expect(try parseOne("_\r\n") == .null)
        #expect(try parseOne("#t\r\n") == .boolean(true))
        #expect(try parseOne("#f\r\n") == .boolean(false))
        #expect(try parseOne(",1.5\r\n") == .double(1.5))
        #expect(try parseOne(",-2\r\n") == .double(-2))
        #expect(try parseOne(",1e10\r\n") == .double(1e10))
        #expect(try parseOne(",inf\r\n") == .double(.infinity))
        #expect(try parseOne(",-inf\r\n") == .double(-.infinity))
        let nan = try #require(try parseOne(",nan\r\n")?.double)
        #expect(nan.isNaN)
        #expect(try parseOne("(3492890328409238509324850943850943825024385\r\n") == .bigNumber("3492890328409238509324850943850943825024385"))
        #expect(try parseOne("!21\r\nSYNTAX invalid syntax\r\n") == .blobError(bytes("SYNTAX invalid syntax")))
        #expect(try parseOne("=15\r\ntxt:Some string\r\n") == .verbatim(format: "txt", text: bytes("Some string")))
    }

    @Test func aggregates() throws {
        #expect(try parseOne("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n")
            == .map([RESPPair(.simpleString("first"), .integer(1)), RESPPair(.simpleString("second"), .integer(2))]))
        #expect(try parseOne("~2\r\n+a\r\n+b\r\n") == .set([.simpleString("a"), .simpleString("b")]))
        #expect(try parseOne(">3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$3\r\nhi!\r\n")
            == .push([.bulkString(bytes("message")), .bulkString(bytes("ch")), .bulkString(bytes("hi!"))]))
        #expect(try parseOne("%0\r\n") == .map([]))
    }

    @Test func attributesAreSkipped() throws {
        let text = "|1\r\n+key-popularity\r\n%2\r\n$1\r\na\r\n,0.1923\r\n$1\r\nb\r\n,0.0012\r\n*2\r\n:2039123\r\n:9543892\r\n"
        #expect(try parseAll(text) == [.array([.integer(2_039_123), .integer(9_543_892)])])
        // An attribute inside an aggregate does not count as an element.
        #expect(try parseOne("*2\r\n:1\r\n|1\r\n+ttl\r\n:3600\r\n:2\r\n") == .array([.integer(1), .integer(2)]))
    }
}

@Suite("Incremental parsing")
struct IncrementalParsingTests {
    @Test func incompleteInputWaits() throws {
        var parser = RESPParser()
        parser.append(bytes("$5\r\nhel"))
        #expect(try parser.next() == nil)
        parser.append(bytes("lo\r"))
        #expect(try parser.next() == nil)
        parser.append(bytes("\n+OK"))
        #expect(try parser.next() == .bulkString(bytes("hello")))
        #expect(try parser.next() == nil)
        parser.append(bytes("\r\n"))
        #expect(try parser.next() == .simpleString("OK"))
        #expect(parser.bufferedByteCount == 0)
    }

    @Test func largeArrayOneByteAtATime() throws {
        let count = 100_000
        var wire = bytes("*\(count)\r\n")
        for index in 0..<count { wire += bytes("$\(String(index).utf8.count)\r\n\(index)\r\n") }
        var parser = RESPParser()
        var produced: [RESPValue] = []
        for byte in wire {
            parser.append(CollectionOfOne(byte))
            while let value = try parser.next() { produced.append(value) }
        }
        #expect(produced.count == 1)
        let elements = try #require(produced.first?.array)
        #expect(elements.count == count)
        #expect(elements.first == .bulkString(bytes("0")))
        #expect(elements.last == .bulkString(bytes("\(count - 1)")))
    }

    @Test func randomChunkingProducesSameValues() throws {
        let text = "*3\r\n%1\r\n+k\r\n~2\r\n:1\r\n,2.5\r\n$10\r\n0123456789\r\n>2\r\n+message\r\n_\r\n+DONE\r\n"
        let expected = try parseAll(text)
        var generator = SplitMix64(seed: 42)
        for _ in 0..<200 {
            var parser = RESPParser()
            var produced: [RESPValue] = []
            var remaining = bytes(text)[...]
            while !remaining.isEmpty {
                let size = Int(generator.next() % 7) + 1
                let chunk = remaining.prefix(size)
                remaining = remaining.dropFirst(chunk.count)
                parser.append(chunk)
                while let value = try parser.next() { produced.append(value) }
            }
            #expect(produced == expected)
        }
    }
}

@Suite("Parser bounds and malformed input")
struct ParserBoundsTests {
    @Test func bulkLengthLimit() {
        let limits = RESPLimits(maxBulkLength: 8)
        #expect(throws: RESPError.self) { try parseOne("$9\r\n123456789\r\n", limits: limits) }
        #expect((try? parseOne("$8\r\n12345678\r\n", limits: limits)) == .bulkString(bytes("12345678")))
    }

    @Test func aggregateCountLimit() {
        let limits = RESPLimits(maxAggregateCount: 3)
        #expect(throws: RESPError.self) { try parseOne("*4\r\n", limits: limits) }
        #expect(throws: RESPError.self) { try parseOne("%2\r\n", limits: RESPLimits(maxAggregateCount: 3)) }
    }

    @Test func hugeDeclaredCountDoesNotAllocate() throws {
        var parser = RESPParser()
        parser.append(bytes("*2147483647\r\n"))
        // Waits for data (count is within the default limit only if configured so) or throws — never traps.
        do {
            #expect(try parser.next() == nil)
        } catch {
            #expect(error is RESPError)
        }
    }

    @Test func depthLimit() {
        let deep = String(repeating: "*1\r\n", count: 10) + ":1\r\n"
        #expect(throws: RESPError.self) { try parseOne(deep, limits: RESPLimits(maxDepth: 5)) }
        #expect((try? parseOne(deep, limits: RESPLimits(maxDepth: 10))) != nil)
    }

    @Test func lineLengthLimit() {
        var parser = RESPParser(limits: RESPLimits(maxLineLength: 16))
        parser.append(bytes("+" + String(repeating: "a", count: 40)))
        #expect(throws: RESPError.self) { try parser.next() }
    }

    @Test(arguments: [
        "$abc\r\nx\r\n", "$-2\r\n", "*-5\r\n", ":12a\r\n", ":\r\n", ":99999999999999999999\r\n",
        "$3\r\nabcde\r\n", "#x\r\n", ",abc\r\n", "Hello\r\n", "=2\r\nab\r\n", "$?\r\n", "*?\r\n",
        "(12x\r\n", "+OK\rX", "%-1\r\n",
    ])
    func malformedInputThrows(_ text: String) {
        #expect(throws: RESPError.self) { try parseAll(text) }
    }

    @Test func errorDescribesNonRESPPeer() {
        do {
            _ = try parseAll("HTTP/1.1 400 Bad Request\r\n")
            Issue.record("expected an error")
        } catch let error as RESPError {
            #expect(error.message.contains("HTTP"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

/// Deterministic PRNG for reproducible fuzzing.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
