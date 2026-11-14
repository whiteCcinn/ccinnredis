import Foundation

/// Routing and safety facts about a command: where its keys are, whether it writes, blocks or is
/// dangerous, and the first server version that has it. A static table covers Redis/Valkey and the
/// common modules; `CommandRegistry` merges what the server reports via `COMMAND`.
public struct CommandSpec: Sendable, Hashable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let readonly = Flags(rawValue: 1 << 0)
        public static let write = Flags(rawValue: 1 << 1)
        public static let admin = Flags(rawValue: 1 << 2)
        /// Destroys data or disrupts the server; needs confirmation.
        public static let dangerous = Flags(rawValue: 1 << 3)
        public static let blocking = Flags(rawValue: 1 << 4)
        public static let pubsub = Flags(rawValue: 1 << 5)
        /// Changes connection state (SELECT, MULTI, AUTH…).
        public static let connectionState = Flags(rawValue: 1 << 6)
        /// Turns the connection into a stream (SUBSCRIBE, MONITOR).
        public static let streaming = Flags(rawValue: 1 << 7)
        /// Keyless command that concerns the whole keyspace; in a cluster it runs on every master.
        public static let allMasters = Flags(rawValue: 1 << 8)
    }

    /// Where the keys of a command are.
    public enum KeyRule: Sendable, Hashable {
        case none
        /// Classic `COMMAND` triple; `last < 0` counts from the end.
        case range(first: Int, last: Int, step: Int)
        /// `numkeys` at `countIndex`, keys right after it (EVAL, ZUNION, LMPOP…), plus an optional fixed key.
        case numkeys(countIndex: Int, fixedKey: Int?)
        /// Keys after the `STREAMS` keyword, first half of the remainder (XREAD, XREADGROUP).
        case streams
    }

    public let name: String
    public let arity: Int
    public let flags: Flags
    public let keys: KeyRule
    public let since: ServerVersion
    public let group: String

    public init(name: String, arity: Int, flags: Flags, keys: KeyRule, since: ServerVersion, group: String) {
        self.name = name
        self.arity = arity
        self.flags = flags
        self.keys = keys
        self.since = since
        self.group = group
    }

    public var isWrite: Bool { flags.contains(.write) }

    /// Indices of key arguments in `arguments` (index 0 is the command name).
    public func keyIndices(in arguments: [[UInt8]]) -> [Int] {
        let count = arguments.count
        switch keys {
        case .none:
            return []
        case let .range(first, last, step):
            guard first > 0, first < count else { return [] }
            let end = last < 0 ? count + last : min(last, count - 1)
            guard end >= first else { return [] }
            return Array(stride(from: first, through: end, by: max(1, step)))
        case let .numkeys(countIndex, fixedKey):
            var result: [Int] = []
            if let fixedKey, fixedKey < count { result.append(fixedKey) }
            guard countIndex < count, let declared = Int(String(decoding: arguments[countIndex], as: UTF8.self)), declared > 0 else {
                return result
            }
            let start = countIndex + 1
            let end = min(count - 1, start + declared - 1)
            if end >= start { result += Array(start...end) }
            return result
        case .streams:
            guard let streamsIndex = arguments.firstIndex(where: { String(decoding: $0, as: UTF8.self).uppercased() == "STREAMS" }) else { return [] }
            let remaining = count - streamsIndex - 1
            guard remaining >= 2, remaining % 2 == 0 else { return [] }
            return Array((streamsIndex + 1)...(streamsIndex + remaining / 2))
        }
    }
}

public enum CommandSpecs {
    /// Commands whose second word selects a subcommand with its own spec (`CONFIG GET`).
    public static let containerCommands: Set<String> = [
        "ACL", "CLIENT", "CLUSTER", "COMMAND", "CONFIG", "DEBUG", "FUNCTION", "LATENCY", "MEMORY", "MODULE",
        "OBJECT", "PUBSUB", "SCRIPT", "SENTINEL", "SLOWLOG", "XGROUP", "XINFO",
    ]

    /// name → spec (names upper-case; subcommands as "CONFIG GET").
    public static let table: [String: CommandSpec] = {
        var table: [String: CommandSpec] = [:]
        for line in raw.split(separator: "\n") where !line.hasPrefix("#") && !line.isEmpty {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6, let arity = Int(fields[1]) else { continue }
            var flags: CommandSpec.Flags = []
            for letter in fields[2] {
                switch letter {
                case "r": flags.insert(.readonly)
                case "w": flags.insert(.write)
                case "a": flags.insert(.admin)
                case "d": flags.insert(.dangerous)
                case "b": flags.insert(.blocking)
                case "p": flags.insert(.pubsub)
                case "s": flags.insert(.connectionState)
                case "m": flags.insert(.streaming)
                case "f": flags.insert(.allMasters)
                default: break
                }
            }
            let rule: CommandSpec.KeyRule
            let keyField = fields[3]
            if keyField == "-" {
                rule = .none
            } else if keyField == "streams" {
                rule = .streams
            } else if keyField.hasPrefix("numkeys:") {
                let parts = keyField.dropFirst("numkeys:".count).split(separator: "+")
                rule = .numkeys(countIndex: Int(parts[0]) ?? 1, fixedKey: parts.count > 1 ? Int(parts[1]) : nil)
            } else {
                let numbers = keyField.split(separator: ",").compactMap { Int($0) }
                rule = numbers.count == 3 ? .range(first: numbers[0], last: numbers[1], step: numbers[2]) : .none
            }
            let spec = CommandSpec(name: fields[0], arity: arity, flags: flags, keys: rule,
                                   since: ServerVersion(parsing: fields[4]) ?? ServerVersion(1, 0, 0), group: fields[5])
            table[fields[0]] = spec
        }
        return table
    }()

    /// Spec for a command line (subcommand-aware).
    public static func spec(for command: RedisCommand) -> CommandSpec? {
        if let qualified = table[command.qualifiedName] { return qualified }
        return table[command.name]
    }

    // name | arity | flags | keys (first,last,step / numkeys:i[+fixed] / streams / -) | since | group
    // swiftlint:disable line_length
    static let raw = """
    APPEND|3|w|1,1,1|2.0.0|string
    DECR|2|w|1,1,1|1.0.0|string
    DECRBY|3|w|1,1,1|1.0.0|string
    GET|2|r|1,1,1|1.0.0|string
    GETDEL|2|w|1,1,1|6.2.0|string
    GETEX|-2|w|1,1,1|6.2.0|string
    GETRANGE|4|r|1,1,1|2.4.0|string
    GETSET|3|w|1,1,1|1.0.0|string
    INCR|2|w|1,1,1|1.0.0|string
    INCRBY|3|w|1,1,1|1.0.0|string
    INCRBYFLOAT|3|w|1,1,1|2.6.0|string
    LCS|-3|r|1,2,1|7.0.0|string
    MGET|-2|r|1,-1,1|1.0.0|string
    MSET|-3|w|1,-1,2|1.0.1|string
    MSETNX|-3|w|1,-1,2|1.0.1|string
    PSETEX|4|w|1,1,1|2.6.0|string
    SET|-3|w|1,1,1|1.0.0|string
    SETEX|4|w|1,1,1|2.0.0|string
    SETNX|3|w|1,1,1|1.0.0|string
    SETRANGE|4|w|1,1,1|2.2.0|string
    STRLEN|2|r|1,1,1|2.2.0|string
    SUBSTR|4|r|1,1,1|1.0.0|string
    BITCOUNT|-2|r|1,1,1|2.6.0|bitmap
    BITFIELD|-2|w|1,1,1|3.2.0|bitmap
    BITFIELD_RO|-2|r|1,1,1|6.0.0|bitmap
    BITOP|-4|w|2,-1,1|2.6.0|bitmap
    BITPOS|-3|r|1,1,1|2.8.7|bitmap
    GETBIT|3|r|1,1,1|2.2.0|bitmap
    SETBIT|4|w|1,1,1|2.2.0|bitmap
    HDEL|-3|w|1,1,1|2.0.0|hash
    HEXISTS|3|r|1,1,1|2.0.0|hash
    HEXPIRE|-6|w|1,1,1|7.4.0|hash
    HEXPIRETIME|-5|r|1,1,1|7.4.0|hash
    HGET|3|r|1,1,1|2.0.0|hash
    HGETALL|2|r|1,1,1|2.0.0|hash
    HGETDEL|-5|w|1,1,1|8.0.0|hash
    HGETEX|-5|w|1,1,1|8.0.0|hash
    HINCRBY|4|w|1,1,1|2.0.0|hash
    HINCRBYFLOAT|4|w|1,1,1|2.6.0|hash
    HKEYS|2|r|1,1,1|2.0.0|hash
    HLEN|2|r|1,1,1|2.0.0|hash
    HMGET|-3|r|1,1,1|2.0.0|hash
    HMSET|-4|w|1,1,1|2.0.0|hash
    HPERSIST|-5|w|1,1,1|7.4.0|hash
    HPEXPIRE|-6|w|1,1,1|7.4.0|hash
    HPEXPIRETIME|-5|r|1,1,1|7.4.0|hash
    HPTTL|-5|r|1,1,1|7.4.0|hash
    HRANDFIELD|-2|r|1,1,1|6.2.0|hash
    HSCAN|-3|r|1,1,1|2.8.0|hash
    HSET|-4|w|1,1,1|2.0.0|hash
    HSETEX|-6|w|1,1,1|8.0.0|hash
    HSETNX|4|w|1,1,1|2.0.0|hash
    HSTRLEN|3|r|1,1,1|3.2.0|hash
    HTTL|-5|r|1,1,1|7.4.0|hash
    HVALS|2|r|1,1,1|2.0.0|hash
    BLMOVE|6|wb|1,2,1|6.2.0|list
    BLMPOP|-5|wb|numkeys:2|7.0.0|list
    BLPOP|-3|wb|1,-2,1|2.0.0|list
    BRPOP|-3|wb|1,-2,1|2.0.0|list
    BRPOPLPUSH|4|wb|1,2,1|2.2.0|list
    LINDEX|3|r|1,1,1|1.0.0|list
    LINSERT|5|w|1,1,1|2.2.0|list
    LLEN|2|r|1,1,1|1.0.0|list
    LMOVE|5|w|1,2,1|6.2.0|list
    LMPOP|-4|w|numkeys:1|7.0.0|list
    LPOP|-2|w|1,1,1|1.0.0|list
    LPOS|-3|r|1,1,1|6.0.6|list
    LPUSH|-3|w|1,1,1|1.0.0|list
    LPUSHX|-3|w|1,1,1|2.2.0|list
    LRANGE|4|r|1,1,1|1.0.0|list
    LREM|4|w|1,1,1|1.0.0|list
    LSET|4|w|1,1,1|1.0.0|list
    LTRIM|4|w|1,1,1|1.0.0|list
    RPOP|-2|w|1,1,1|1.0.0|list
    RPOPLPUSH|3|w|1,2,1|1.2.0|list
    RPUSH|-3|w|1,1,1|1.0.0|list
    RPUSHX|-3|w|1,1,1|2.2.0|list
    SADD|-3|w|1,1,1|1.0.0|set
    SCARD|2|r|1,1,1|1.0.0|set
    SDIFF|-2|r|1,-1,1|1.0.0|set
    SDIFFSTORE|-3|w|1,-1,1|1.0.0|set
    SINTER|-2|r|1,-1,1|1.0.0|set
    SINTERCARD|-3|r|numkeys:1|7.0.0|set
    SINTERSTORE|-3|w|1,-1,1|1.0.0|set
    SISMEMBER|3|r|1,1,1|1.0.0|set
    SMEMBERS|2|r|1,1,1|1.0.0|set
    SMISMEMBER|-3|r|1,1,1|6.2.0|set
    SMOVE|4|w|1,2,1|1.0.0|set
    SPOP|-2|w|1,1,1|1.0.0|set
    SRANDMEMBER|-2|r|1,1,1|1.0.0|set
    SREM|-3|w|1,1,1|1.0.0|set
    SSCAN|-3|r|1,1,1|2.8.0|set
    SUNION|-2|r|1,-1,1|1.0.0|set
    SUNIONSTORE|-3|w|1,-1,1|1.0.0|set
    BZMPOP|-5|wb|numkeys:2|7.0.0|sorted-set
    BZPOPMAX|-3|wb|1,-2,1|5.0.0|sorted-set
    BZPOPMIN|-3|wb|1,-2,1|5.0.0|sorted-set
    ZADD|-4|w|1,1,1|1.2.0|sorted-set
    ZCARD|2|r|1,1,1|1.2.0|sorted-set
    ZCOUNT|4|r|1,1,1|2.0.0|sorted-set
    ZDIFF|-3|r|numkeys:1|6.2.0|sorted-set
    ZDIFFSTORE|-4|w|numkeys:2+1|6.2.0|sorted-set
    ZINCRBY|4|w|1,1,1|1.2.0|sorted-set
    ZINTER|-3|r|numkeys:1|6.2.0|sorted-set
    ZINTERCARD|-3|r|numkeys:1|7.0.0|sorted-set
    ZINTERSTORE|-4|w|numkeys:2+1|2.0.0|sorted-set
    ZLEXCOUNT|4|r|1,1,1|2.8.9|sorted-set
    ZMPOP|-4|w|numkeys:1|7.0.0|sorted-set
    ZMSCORE|-3|r|1,1,1|6.2.0|sorted-set
    ZPOPMAX|-2|w|1,1,1|5.0.0|sorted-set
    ZPOPMIN|-2|w|1,1,1|5.0.0|sorted-set
    ZRANDMEMBER|-2|r|1,1,1|6.2.0|sorted-set
    ZRANGE|-4|r|1,1,1|1.2.0|sorted-set
    ZRANGEBYLEX|-4|r|1,1,1|2.8.9|sorted-set
    ZRANGEBYSCORE|-4|r|1,1,1|1.0.5|sorted-set
    ZRANGESTORE|-5|w|1,2,1|6.2.0|sorted-set
    ZRANK|-3|r|1,1,1|2.0.0|sorted-set
    ZREM|-3|w|1,1,1|1.2.0|sorted-set
    ZREMRANGEBYLEX|4|w|1,1,1|2.8.9|sorted-set
    ZREMRANGEBYRANK|4|w|1,1,1|2.0.0|sorted-set
    ZREMRANGEBYSCORE|4|w|1,1,1|1.2.0|sorted-set
    ZREVRANGE|-4|r|1,1,1|1.2.0|sorted-set
    ZREVRANGEBYLEX|-4|r|1,1,1|2.8.9|sorted-set
    ZREVRANGEBYSCORE|-4|r|1,1,1|2.2.0|sorted-set
    ZREVRANK|-3|r|1,1,1|2.0.0|sorted-set
    ZSCAN|-3|r|1,1,1|2.8.0|sorted-set
    ZSCORE|3|r|1,1,1|1.2.0|sorted-set
    ZUNION|-3|r|numkeys:1|6.2.0|sorted-set
    ZUNIONSTORE|-4|w|numkeys:2+1|2.0.0|sorted-set
    XACK|-4|w|1,1,1|5.0.0|stream
    XADD|-5|w|1,1,1|5.0.0|stream
    XAUTOCLAIM|-6|w|1,1,1|6.2.0|stream
    XCLAIM|-6|w|1,1,1|5.0.0|stream
    XDEL|-3|w|1,1,1|5.0.0|stream
    XGROUP CREATE|-5|w|2,2,1|5.0.0|stream
    XGROUP CREATECONSUMER|5|w|2,2,1|6.2.0|stream
    XGROUP DELCONSUMER|5|w|2,2,1|5.0.0|stream
    XGROUP DESTROY|4|w|2,2,1|5.0.0|stream
    XGROUP SETID|-5|w|2,2,1|5.0.0|stream
    XINFO CONSUMERS|4|r|2,2,1|5.0.0|stream
    XINFO GROUPS|3|r|2,2,1|5.0.0|stream
    XINFO STREAM|-3|r|2,2,1|5.0.0|stream
    XLEN|2|r|1,1,1|5.0.0|stream
    XPENDING|-3|r|1,1,1|5.0.0|stream
    XRANGE|-4|r|1,1,1|5.0.0|stream
    XREAD|-4|rb|streams|5.0.0|stream
    XREADGROUP|-7|wb|streams|5.0.0|stream
    XREVRANGE|-4|r|1,1,1|5.0.0|stream
    XSETID|-3|w|1,1,1|5.0.0|stream
    XTRIM|-4|w|1,1,1|5.0.0|stream
    GEOADD|-5|w|1,1,1|3.2.0|geo
    GEODIST|-4|r|1,1,1|3.2.0|geo
    GEOHASH|-2|r|1,1,1|3.2.0|geo
    GEOPOS|-2|r|1,1,1|3.2.0|geo
    GEORADIUS|-6|w|1,1,1|3.2.0|geo
    GEORADIUSBYMEMBER|-5|w|1,1,1|3.2.0|geo
    GEOSEARCH|-7|r|1,1,1|6.2.0|geo
    GEOSEARCHSTORE|-8|w|1,2,1|6.2.0|geo
    PFADD|-2|w|1,1,1|2.8.9|hyperloglog
    PFCOUNT|-2|r|1,-1,1|2.8.9|hyperloglog
    PFMERGE|-2|w|1,-1,1|2.8.9|hyperloglog
    COPY|-3|w|1,2,1|6.2.0|generic
    DEL|-2|w|1,-1,1|1.0.0|generic
    DUMP|2|r|1,1,1|2.6.0|generic
    EXISTS|-2|r|1,-1,1|1.0.0|generic
    EXPIRE|-3|w|1,1,1|1.0.0|generic
    EXPIREAT|-3|w|1,1,1|1.2.0|generic
    EXPIRETIME|2|r|1,1,1|7.0.0|generic
    KEYS|2|rdf|-|1.0.0|generic
    MIGRATE|-6|wd|3,3,1|2.6.0|generic
    MOVE|3|w|1,1,1|1.0.0|generic
    OBJECT ENCODING|3|r|2,2,1|2.2.3|generic
    OBJECT FREQ|3|r|2,2,1|4.0.0|generic
    OBJECT IDLETIME|3|r|2,2,1|2.2.3|generic
    OBJECT REFCOUNT|3|r|2,2,1|2.2.3|generic
    OBJECT HELP|2|r|-|6.2.0|generic
    PERSIST|2|w|1,1,1|2.2.0|generic
    PEXPIRE|-3|w|1,1,1|2.6.0|generic
    PEXPIREAT|-3|w|1,1,1|2.6.0|generic
    PEXPIRETIME|2|r|1,1,1|7.0.0|generic
    PTTL|2|r|1,1,1|2.6.0|generic
    RANDOMKEY|1|r|-|1.0.0|generic
    RENAME|3|w|1,2,1|1.0.0|generic
    RENAMENX|3|w|1,2,1|1.0.0|generic
    RESTORE|-4|w|1,1,1|2.6.0|generic
    SCAN|-2|rf|-|2.8.0|generic
    SORT|-2|w|1,1,1|1.0.0|generic
    SORT_RO|-2|r|1,1,1|7.0.0|generic
    TOUCH|-2|r|1,-1,1|3.2.1|generic
    TTL|2|r|1,1,1|1.0.0|generic
    TYPE|2|r|1,1,1|1.0.0|generic
    UNLINK|-2|w|1,-1,1|4.0.0|generic
    WAIT|3|-|-|3.0.0|generic
    WAITAOF|4|-|-|7.2.0|generic
    AUTH|-2|s|-|1.0.0|connection
    CLIENT GETNAME|2|r|-|2.6.9|connection
    CLIENT ID|2|r|-|5.0.0|connection
    CLIENT INFO|2|r|-|6.2.0|connection
    CLIENT KILL|-3|ad|-|2.4.0|connection
    CLIENT LIST|-2|a|-|2.4.0|connection
    CLIENT NO-EVICT|3|as|-|7.0.0|connection
    CLIENT PAUSE|-3|ad|-|2.9.50|connection
    CLIENT REPLY|3|s|-|3.2.0|connection
    CLIENT SETINFO|4|s|-|7.2.0|connection
    CLIENT SETNAME|3|s|-|2.6.9|connection
    CLIENT TRACKING|-3|s|-|6.0.0|connection
    CLIENT UNBLOCK|-3|a|-|5.0.0|connection
    CLIENT UNPAUSE|2|a|-|6.2.0|connection
    ECHO|2|r|-|1.0.0|connection
    HELLO|-1|s|-|6.0.0|connection
    PING|-1|r|-|1.0.0|connection
    QUIT|-1|s|-|1.0.0|connection
    RESET|1|s|-|6.2.0|connection
    SELECT|2|s|-|1.0.0|connection
    DISCARD|1|s|-|2.0.0|transactions
    EXEC|1|s|-|1.2.0|transactions
    MULTI|1|s|-|1.2.0|transactions
    UNWATCH|1|s|-|2.2.0|transactions
    WATCH|-2|rs|1,-1,1|2.2.0|transactions
    EVAL|-3|w|numkeys:2|2.6.0|scripting
    EVALSHA|-3|w|numkeys:2|2.6.0|scripting
    EVAL_RO|-3|r|numkeys:2|7.0.0|scripting
    EVALSHA_RO|-3|r|numkeys:2|7.0.0|scripting
    FCALL|-3|w|numkeys:2|7.0.0|scripting
    FCALL_RO|-3|r|numkeys:2|7.0.0|scripting
    FUNCTION DELETE|3|wd|-|7.0.0|scripting
    FUNCTION DUMP|2|r|-|7.0.0|scripting
    FUNCTION FLUSH|-2|wd|-|7.0.0|scripting
    FUNCTION LIST|-2|r|-|7.0.0|scripting
    FUNCTION LOAD|-3|w|-|7.0.0|scripting
    FUNCTION STATS|2|r|-|7.0.0|scripting
    SCRIPT EXISTS|-3|r|-|2.6.0|scripting
    SCRIPT FLUSH|-2|wd|-|2.6.0|scripting
    SCRIPT KILL|2|a|-|2.6.0|scripting
    SCRIPT LOAD|3|r|-|2.6.0|scripting
    PSUBSCRIBE|-2|psm|-|2.0.0|pubsub
    PUBLISH|3|p|-|2.0.0|pubsub
    PUBSUB CHANNELS|-2|pr|-|2.8.0|pubsub
    PUBSUB NUMPAT|2|pr|-|2.8.0|pubsub
    PUBSUB NUMSUB|-2|pr|-|2.8.0|pubsub
    PUBSUB SHARDCHANNELS|-2|pr|-|7.0.0|pubsub
    PUBSUB SHARDNUMSUB|-2|pr|-|7.0.0|pubsub
    PUNSUBSCRIBE|-1|ps|-|2.0.0|pubsub
    SPUBLISH|3|p|1,1,1|7.0.0|pubsub
    SSUBSCRIBE|-2|psm|1,-1,1|7.0.0|pubsub
    SUBSCRIBE|-2|psm|-|2.0.0|pubsub
    SUNSUBSCRIBE|-1|ps|1,-1,1|7.0.0|pubsub
    UNSUBSCRIBE|-1|ps|-|2.0.0|pubsub
    ACL CAT|-2|r|-|6.0.0|server
    ACL DELUSER|-3|ad|-|6.0.0|server
    ACL GETUSER|3|a|-|6.0.0|server
    ACL LIST|2|a|-|6.0.0|server
    ACL LOG|-2|a|-|6.0.0|server
    ACL SETUSER|-3|ad|-|6.0.0|server
    ACL USERS|2|a|-|6.0.0|server
    ACL WHOAMI|2|r|-|6.0.0|server
    BGREWRITEAOF|1|a|-|1.0.0|server
    BGSAVE|-1|a|-|1.0.0|server
    COMMAND COUNT|2|r|-|2.8.13|server
    COMMAND DOCS|-2|r|-|7.0.0|server
    COMMAND GETKEYS|-3|r|-|2.8.13|server
    COMMAND INFO|-2|r|-|2.8.13|server
    COMMAND LIST|-2|r|-|7.0.0|server
    COMMAND|-1|r|-|2.8.13|server
    CONFIG GET|-3|a|-|2.0.0|server
    CONFIG RESETSTAT|2|a|-|2.0.0|server
    CONFIG REWRITE|2|ad|-|2.8.0|server
    CONFIG SET|-4|ad|-|2.0.0|server
    DBSIZE|1|rf|-|1.0.0|server
    DEBUG|-2|ad|-|1.0.0|server
    FAILOVER|-1|ad|-|6.2.0|server
    FLUSHALL|-1|wdf|-|1.0.0|server
    FLUSHDB|-1|wdf|-|1.0.0|server
    INFO|-1|r|-|1.0.0|server
    LASTSAVE|1|r|-|1.0.0|server
    LATENCY DOCTOR|2|a|-|2.8.13|server
    LATENCY HISTORY|3|a|-|2.8.13|server
    LATENCY LATEST|2|a|-|2.8.13|server
    LATENCY RESET|-2|a|-|2.8.13|server
    LOLWUT|-1|r|-|5.0.0|server
    MEMORY DOCTOR|2|r|-|4.0.0|server
    MEMORY STATS|2|r|-|4.0.0|server
    MEMORY USAGE|-3|r|2,2,1|4.0.0|server
    MODULE LIST|2|a|-|4.0.0|server
    MODULE LOAD|-3|ad|-|4.0.0|server
    MODULE UNLOAD|3|ad|-|4.0.0|server
    MONITOR|1|am|-|1.0.0|server
    REPLICAOF|3|ad|-|5.0.0|server
    ROLE|1|r|-|2.8.12|server
    SAVE|1|a|-|1.0.0|server
    SHUTDOWN|-1|ad|-|1.0.0|server
    SLAVEOF|3|ad|-|1.0.0|server
    SLOWLOG GET|-2|a|-|2.2.12|server
    SLOWLOG LEN|2|a|-|2.2.12|server
    SLOWLOG RESET|2|ad|-|2.2.12|server
    SWAPDB|3|wd|-|4.0.0|server
    TIME|1|r|-|2.6.0|server
    CLUSTER COUNTKEYSINSLOT|3|r|-|3.0.0|cluster
    CLUSTER FAILOVER|-2|ad|-|3.0.0|cluster
    CLUSTER FORGET|3|ad|-|3.0.0|cluster
    CLUSTER GETKEYSINSLOT|4|r|-|3.0.0|cluster
    CLUSTER INFO|2|r|-|3.0.0|cluster
    CLUSTER KEYSLOT|3|r|-|3.0.0|cluster
    CLUSTER MYID|2|r|-|3.0.0|cluster
    CLUSTER NODES|2|r|-|3.0.0|cluster
    CLUSTER REPLICAS|3|r|-|5.0.0|cluster
    CLUSTER RESET|-2|ad|-|3.0.0|cluster
    CLUSTER SHARDS|2|r|-|7.0.0|cluster
    CLUSTER SLOTS|2|r|-|3.0.0|cluster
    ASKING|1|s|-|3.0.0|cluster
    READONLY|1|s|-|3.0.0|cluster
    READWRITE|1|s|-|3.0.0|cluster
    SENTINEL GET-MASTER-ADDR-BY-NAME|3|r|-|2.8.0|sentinel
    SENTINEL MASTERS|2|r|-|2.8.0|sentinel
    SENTINEL MASTER|3|r|-|2.8.0|sentinel
    SENTINEL REPLICAS|3|r|-|5.0.0|sentinel
    SENTINEL SLAVES|3|r|-|2.8.0|sentinel
    SENTINEL SENTINELS|3|r|-|2.8.4|sentinel
    SENTINEL FAILOVER|3|ad|-|2.8.0|sentinel
    JSON.ARRAPPEND|-4|w|1,1,1|4.0.0|json
    JSON.ARRINDEX|-4|r|1,1,1|4.0.0|json
    JSON.ARRINSERT|-5|w|1,1,1|4.0.0|json
    JSON.ARRLEN|-2|r|1,1,1|4.0.0|json
    JSON.ARRPOP|-2|w|1,1,1|4.0.0|json
    JSON.ARRTRIM|5|w|1,1,1|4.0.0|json
    JSON.CLEAR|-2|w|1,1,1|4.0.0|json
    JSON.DEBUG|-2|r|2,2,1|4.0.0|json
    JSON.DEL|-2|w|1,1,1|4.0.0|json
    JSON.FORGET|-2|w|1,1,1|4.0.0|json
    JSON.GET|-2|r|1,1,1|4.0.0|json
    JSON.MERGE|4|w|1,1,1|4.0.0|json
    JSON.MGET|-3|r|1,-2,1|4.0.0|json
    JSON.MSET|-4|w|1,-1,3|4.0.0|json
    JSON.NUMINCRBY|4|w|1,1,1|4.0.0|json
    JSON.NUMMULTBY|4|w|1,1,1|4.0.0|json
    JSON.OBJKEYS|-2|r|1,1,1|4.0.0|json
    JSON.OBJLEN|-2|r|1,1,1|4.0.0|json
    JSON.RESP|-2|r|1,1,1|4.0.0|json
    JSON.SET|-4|w|1,1,1|4.0.0|json
    JSON.STRAPPEND|-3|w|1,1,1|4.0.0|json
    JSON.STRLEN|-2|r|1,1,1|4.0.0|json
    JSON.TOGGLE|-2|w|1,1,1|4.0.0|json
    JSON.TYPE|-2|r|1,1,1|4.0.0|json
    FT._LIST|1|r|-|4.0.0|search
    FT.AGGREGATE|-3|r|-|4.0.0|search
    FT.CREATE|-2|w|-|4.0.0|search
    FT.DROPINDEX|-2|wd|-|4.0.0|search
    FT.EXPLAIN|-3|r|-|4.0.0|search
    FT.INFO|2|r|-|4.0.0|search
    FT.SEARCH|-3|r|-|4.0.0|search
    BF.ADD|3|w|1,1,1|4.0.0|bloom
    BF.EXISTS|3|r|1,1,1|4.0.0|bloom
    BF.INFO|-2|r|1,1,1|4.0.0|bloom
    BF.RESERVE|-4|w|1,1,1|4.0.0|bloom
    TS.ADD|-4|w|1,1,1|4.0.0|timeseries
    TS.CREATE|-2|w|1,1,1|4.0.0|timeseries
    TS.GET|-2|r|1,1,1|4.0.0|timeseries
    TS.INFO|-2|r|1,1,1|4.0.0|timeseries
    TS.RANGE|-4|r|1,1,1|4.0.0|timeseries
    """
    // swiftlint:enable line_length
}
