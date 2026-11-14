/// Redis Cluster key → slot mapping: CRC16/XMODEM of the key (or of its first non-empty `{hashtag}`) mod 16384.
public enum HashSlot {
    public static let count = 16_384

    private static let table: [UInt16] = (0..<256).map { byte -> UInt16 in
        var crc = UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }

    public static func crc16<Bytes: Collection>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            let index = Int(UInt8(truncatingIfNeeded: crc >> 8) ^ byte)
            crc = (crc << 8) ^ table[index]
        }
        return crc
    }

    public static func slot(for key: RedisKey) -> Int { slot(bytes: key.bytes) }

    public static func slot(bytes: [UInt8]) -> Int {
        if let open = bytes.firstIndex(of: UInt8(ascii: "{")) {
            let afterOpen = bytes.index(after: open)
            if let close = bytes[afterOpen...].firstIndex(of: UInt8(ascii: "}")), close > afterOpen {
                return Int(crc16(bytes[afterOpen..<close]) & 0x3FFF)
            }
        }
        return Int(crc16(bytes) & 0x3FFF)
    }
}
