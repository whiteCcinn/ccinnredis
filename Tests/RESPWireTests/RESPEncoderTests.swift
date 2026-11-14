import Testing
@testable import RESPWire

@Suite("RESP encoding")
struct RESPEncoderTests {
    @Test func commandAsArrayOfBulkStrings() {
        let encoded = RESPEncoder.command(["SET", "key", "va lue"])
        #expect(String(decoding: encoded, as: UTF8.self) == "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$6\r\nva lue\r\n")
    }

    @Test func binaryArgumentsAndEmptyArgument() {
        let encoded = RESPEncoder.command(arguments: [Array("GET".utf8), [0x00, 0xFF], []])
        #expect(encoded == Array("*3\r\n$3\r\nGET\r\n$2\r\n".utf8) + [0x00, 0xFF] + Array("\r\n$0\r\n\r\n".utf8))
    }

    @Test func pipelineConcatenatesCommands() {
        var buffer: [UInt8] = []
        RESPEncoder.appendCommand(arguments: [Array("PING".utf8)], to: &buffer)
        RESPEncoder.appendCommand(arguments: [Array("ECHO".utf8), Array("x".utf8)], to: &buffer)
        #expect(String(decoding: buffer, as: UTF8.self) == "*1\r\n$4\r\nPING\r\n*2\r\n$4\r\nECHO\r\n$1\r\nx\r\n")
    }

    @Test func valueEncodingRoundTripsEveryType() throws {
        let value: RESPValue = .array([
            .simpleString("OK"), .error("ERR x"), .integer(-9), .bulkString([1, 2, 3]), .null,
            .double(2.5), .double(.infinity), .double(-.infinity), .boolean(true), .blobError(Array("E".utf8)),
            .verbatim(format: "mkd", text: Array("# hi".utf8)), .bigNumber("-123456789012345678901234567890"),
            .map([RESPPair(.bulkString(Array("a".utf8)), .integer(1))]), .set([.integer(1)]), .push([.simpleString("pong")]),
            .array([]),
        ])
        var parser = RESPParser()
        parser.append(RESPEncoder.encode(value))
        #expect(try parser.next() == value)
    }
}

@Suite("RESP fuzzing")
struct RESPFuzzTests {
    @Test func randomBytesNeverCrash() {
        var generator = SplitMix64(seed: 0xC0FFEE)
        let alphabet = Array("+-:$*_,#!=(%~>|\r\n0123456789-?abcdefxyz".utf8)
        for iteration in 0..<20_000 {
            var parser = RESPParser(limits: RESPLimits(maxBulkLength: 1 << 16, maxAggregateCount: 1 << 12, maxDepth: 16, maxLineLength: 1 << 12))
            let length = Int(generator.next() % 64)
            var input: [UInt8] = []
            for _ in 0..<length {
                // Mostly protocol-looking bytes, sometimes arbitrary ones.
                if generator.next() % 4 == 0 {
                    input.append(UInt8(truncatingIfNeeded: generator.next()))
                } else {
                    input.append(alphabet[Int(generator.next() % UInt64(alphabet.count))])
                }
            }
            parser.append(input)
            var steps = 0
            do {
                while try parser.next() != nil, steps < 1000 { steps += 1 }
            } catch {
                #expect(error is RESPError, "iteration \(iteration)")
            }
        }
    }

    @Test func randomValuesRoundTripThroughRandomChunks() throws {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<500 {
            let value = randomValue(&generator, depth: 0)
            let wire = RESPEncoder.encode(value)
            var parser = RESPParser()
            var produced: [RESPValue] = []
            var offset = 0
            while offset < wire.count {
                let size = min(wire.count - offset, Int(generator.next() % 13) + 1)
                parser.append(wire[offset..<(offset + size)])
                offset += size
                while let decoded = try parser.next() { produced.append(decoded) }
            }
            #expect(produced.count == 1)
            #expect(produced.first.map { equalTreatingNaN($0, value) } == true)
        }
    }

    private func randomValue(_ generator: inout SplitMix64, depth: Int) -> RESPValue {
        let choice = Int(generator.next() % (depth > 3 ? 10 : 15))
        func randomBytes() -> [UInt8] { (0..<Int(generator.next() % 20)).map { _ in UInt8(truncatingIfNeeded: generator.next()) } }
        func randomLine() -> String { String((0..<Int(generator.next() % 12)).map { _ in Character(UnicodeScalar(UInt8(97 + generator.next() % 26))) }) }
        switch choice {
        case 0: return .simpleString(randomLine())
        case 1: return .error("ERR " + randomLine())
        case 2: return .integer(Int64(bitPattern: generator.next()))
        case 3: return .bulkString(randomBytes())
        case 4: return .null
        case 5: return .double(Double(Int64(bitPattern: generator.next() % 1_000_000)) / 8)
        case 6: return .boolean(generator.next() % 2 == 0)
        case 7: return .blobError(randomBytes())
        case 8: return .verbatim(format: "txt", text: randomBytes())
        case 9: return .bigNumber(String(generator.next()))
        case 10: return .array((0..<Int(generator.next() % 5)).map { _ in randomValue(&generator, depth: depth + 1) })
        case 11: return .set((0..<Int(generator.next() % 5)).map { _ in randomValue(&generator, depth: depth + 1) })
        case 12: return .push((0..<Int(generator.next() % 5 + 1)).map { _ in randomValue(&generator, depth: depth + 1) })
        default:
            return .map((0..<Int(generator.next() % 4)).map { _ in
                RESPPair(randomValue(&generator, depth: depth + 1), randomValue(&generator, depth: depth + 1))
            })
        }
    }

    private func equalTreatingNaN(_ lhs: RESPValue, _ rhs: RESPValue) -> Bool {
        lhs == rhs
    }
}
