import Testing
@testable import RESPWire

@Suite("RESP value accessors")
struct RESPValueTests {
    @Test func stringAccessors() {
        #expect(RESPValue.bulkString(Array("héllo".utf8)).string == "héllo")
        #expect(RESPValue.simpleString("OK").string == "OK")
        #expect(RESPValue.verbatim(format: "txt", text: Array("v".utf8)).string == "v")
        #expect(RESPValue.integer(5).string == nil)
        #expect(RESPValue.integer(5).text == "5")
        #expect(RESPValue.null.string == nil)
        // Invalid UTF-8 decodes lossily instead of failing.
        #expect(RESPValue.bulkString([0x61, 0xFF]).string == "a\u{FFFD}")
    }

    @Test func numericAccessors() {
        #expect(RESPValue.integer(7).int == 7)
        #expect(RESPValue.bulkString(Array("-12".utf8)).int == -12)
        #expect(RESPValue.bulkString(Array("1.5".utf8)).int == nil)
        #expect(RESPValue.bulkString(Array("1.5".utf8)).double == 1.5)
        #expect(RESPValue.bulkString(Array("inf".utf8)).double == .infinity)
        #expect(RESPValue.bulkString(Array("-inf".utf8)).double == -.infinity)
        #expect(RESPValue.double(2.25).double == 2.25)
        #expect(RESPValue.integer(3).double == 3)
        #expect(RESPValue.bigNumber("12").int == 12)
    }

    @Test func pairsFromMapAndFlatArray() {
        let map = RESPValue.map([RESPPair(.simpleString("a"), .integer(1))])
        let flat = RESPValue.array([.bulkString(Array("a".utf8)), .integer(1)])
        #expect(map.pairs?.count == 1)
        #expect(flat.pairs?.first?.key.string == "a")
        #expect(flat.pairs?.first?.value.int == 1)
        #expect(RESPValue.array([.integer(1)]).pairs == nil)
        #expect(RESPValue.integer(1).pairs == nil)
    }

    @Test func dictionaryAccess() {
        let map = RESPValue.map([RESPPair(.simpleString("server"), .bulkString(Array("redis".utf8))),
                                 RESPPair(.simpleString("proto"), .integer(3))])
        #expect(map["server"]?.string == "redis")
        #expect(map["proto"]?.int == 3)
        #expect(map["missing"] == nil)
    }

    @Test func errorsAndCollections() {
        #expect(RESPValue.error("ERR x").errorMessage == "ERR x")
        #expect(RESPValue.blobError(Array("SYNTAX y".utf8)).errorMessage == "SYNTAX y")
        #expect(RESPValue.error("ERR").isError)
        #expect(RESPValue.set([.integer(1)]).array?.count == 1)
        #expect(RESPValue.push([.integer(1)]).array?.count == 1)
        #expect(RESPValue.null.isNull)
        #expect(RESPValue.boolean(true).bool == true)
        #expect(RESPValue.integer(1).bool == true)
        #expect(RESPValue.integer(0).bool == false)
    }
}
