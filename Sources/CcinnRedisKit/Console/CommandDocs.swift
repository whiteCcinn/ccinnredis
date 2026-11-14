import Foundation

/// Syntax and one-line summaries for the console (completion details and the hint bar).
enum CommandDocs {
    struct Entry: Sendable {
        let syntax: String
        let summary: String
    }

    static let table: [String: Entry] = {
        var table: [String: Entry] = [:]
        // Syntax may contain `|` (alternatives); the name ends at the first bar and the summary starts after the last.
        for line in raw.split(separator: "\n") where !line.isEmpty {
            guard let first = line.firstIndex(of: "|"), let last = line.lastIndex(of: "|"), first < last else { continue }
            let name = line[..<first].trimmingCharacters(in: .whitespaces)
            let syntax = line[line.index(after: first)..<last].trimmingCharacters(in: .whitespaces)
            let summary = line[line.index(after: last)...].trimmingCharacters(in: .whitespaces)
            table[name] = Entry(syntax: syntax, summary: summary)
        }
        return table
    }()

    static let keywords: [String: [String]] = [
        "SET": ["EX", "PX", "EXAT", "PXAT", "NX", "XX", "KEEPTTL", "GET"],
        "GETEX": ["EX", "PX", "EXAT", "PXAT", "PERSIST"],
        "SCAN": ["MATCH", "COUNT", "TYPE"],
        "HSCAN": ["MATCH", "COUNT", "NOVALUES"],
        "SSCAN": ["MATCH", "COUNT"],
        "ZSCAN": ["MATCH", "COUNT"],
        "ZRANGE": ["BYSCORE", "BYLEX", "REV", "LIMIT", "WITHSCORES"],
        "ZADD": ["NX", "XX", "GT", "LT", "CH", "INCR"],
        "ZRANGEBYSCORE": ["WITHSCORES", "LIMIT"],
        "ZREVRANGEBYSCORE": ["WITHSCORES", "LIMIT"],
        "EXPIRE": ["NX", "XX", "GT", "LT"],
        "XADD": ["NOMKSTREAM", "MAXLEN", "MINID", "LIMIT"],
        "XRANGE": ["COUNT"],
        "XREVRANGE": ["COUNT"],
        "XREAD": ["COUNT", "BLOCK", "STREAMS"],
        "XREADGROUP": ["GROUP", "COUNT", "BLOCK", "NOACK", "STREAMS"],
        "XTRIM": ["MAXLEN", "MINID", "LIMIT"],
        "LPOS": ["RANK", "COUNT", "MAXLEN"],
        "CLIENT": ["LIST", "KILL", "INFO", "SETNAME", "GETNAME", "ID", "PAUSE", "UNPAUSE", "TRACKING", "REPLY", "NO-EVICT"],
        "INFO": ["SERVER", "CLIENTS", "MEMORY", "PERSISTENCE", "STATS", "REPLICATION", "CPU", "COMMANDSTATS", "LATENCYSTATS", "CLUSTER", "KEYSPACE", "MODULES", "ALL", "EVERYTHING"],
        "SORT": ["BY", "LIMIT", "GET", "ASC", "DESC", "ALPHA", "STORE"],
        "GEOSEARCH": ["FROMMEMBER", "FROMLONLAT", "BYRADIUS", "BYBOX", "ASC", "DESC", "COUNT", "ANY", "WITHCOORD", "WITHDIST", "WITHHASH"],
        "FLUSHDB": ["ASYNC", "SYNC"],
        "FLUSHALL": ["ASYNC", "SYNC"],
        "COPY": ["DB", "REPLACE"],
        "RESTORE": ["REPLACE", "ABSTTL", "IDLETIME", "FREQ"],
        "MIGRATE": ["COPY", "REPLACE", "AUTH", "AUTH2", "KEYS"],
        "HELLO": ["AUTH", "SETNAME"],
        "SHUTDOWN": ["NOSAVE", "SAVE", "NOW", "FORCE", "ABORT"],
        "MEMORY": ["USAGE", "STATS", "DOCTOR", "MALLOC-STATS", "PURGE"],
        "OBJECT": ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"],
        "JSON.SET": ["NX", "XX"],
        "FT.SEARCH": ["NOCONTENT", "VERBATIM", "WITHSCORES", "LIMIT", "RETURN", "SORTBY", "DIALECT"],
    ]

    // name | syntax | summary
    // swiftlint:disable line_length
    static let raw = """
    APPEND|APPEND key value|Appends a string to the value of a key; creates the key if needed.
    DECR|DECR key|Decrements the integer value of a key by one.
    DECRBY|DECRBY key decrement|Decrements the integer value of a key by a number.
    GET|GET key|Returns the string value of a key.
    GETDEL|GETDEL key|Returns the string value of a key and deletes it.
    GETEX|GETEX key [EX seconds | PX ms | EXAT ts | PXAT ts | PERSIST]|Returns the value of a key and sets or removes its expiration.
    GETRANGE|GETRANGE key start end|Returns a substring of the string stored at a key.
    GETSET|GETSET key value|Sets a new value and returns the old one (deprecated: use SET … GET).
    INCR|INCR key|Increments the integer value of a key by one.
    INCRBY|INCRBY key increment|Increments the integer value of a key by a number.
    INCRBYFLOAT|INCRBYFLOAT key increment|Increments the floating-point value of a key.
    LCS|LCS key1 key2 [LEN] [IDX] [MINMATCHLEN len] [WITHMATCHLEN]|Finds the longest common substring.
    MGET|MGET key [key ...]|Returns the values of one or more keys.
    MSET|MSET key value [key value ...]|Sets several keys at once.
    MSETNX|MSETNX key value [key value ...]|Sets several keys only if none of them exists.
    PSETEX|PSETEX key milliseconds value|Sets a value with a millisecond expiration.
    SET|SET key value [NX | XX] [GET] [EX seconds | PX ms | EXAT ts | PXAT ts | KEEPTTL]|Sets the string value of a key, optionally with an expiration.
    SETEX|SETEX key seconds value|Sets a value with an expiration in seconds.
    SETNX|SETNX key value|Sets a key only if it does not exist.
    SETRANGE|SETRANGE key offset value|Overwrites part of a string at an offset.
    STRLEN|STRLEN key|Returns the length of a string value.
    BITCOUNT|BITCOUNT key [start end [BYTE | BIT]]|Counts set bits in a string.
    BITFIELD|BITFIELD key [GET type offset] [SET type offset value] [INCRBY type offset increment] [OVERFLOW WRAP|SAT|FAIL]|Performs arbitrary bitfield operations.
    BITOP|BITOP AND|OR|XOR|NOT destkey key [key ...]|Bitwise operations between strings.
    BITPOS|BITPOS key bit [start [end [BYTE | BIT]]]|Finds the first set or clear bit.
    GETBIT|GETBIT key offset|Returns a bit value by offset.
    SETBIT|SETBIT key offset value|Sets or clears the bit at an offset.
    HDEL|HDEL key field [field ...]|Deletes one or more hash fields.
    HEXISTS|HEXISTS key field|Determines whether a field exists in a hash.
    HEXPIRE|HEXPIRE key seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]|Sets an expiration on hash fields (7.4+).
    HGET|HGET key field|Returns the value of a hash field.
    HGETALL|HGETALL key|Returns all fields and values of a hash.
    HGETDEL|HGETDEL key FIELDS numfields field [field ...]|Returns and deletes hash fields (8.0+).
    HGETEX|HGETEX key [EX seconds | PX ms | EXAT ts | PXAT ts | PERSIST] FIELDS numfields field [field ...]|Returns hash fields and sets their expiration (8.0+).
    HINCRBY|HINCRBY key field increment|Increments the integer value of a hash field.
    HINCRBYFLOAT|HINCRBYFLOAT key field increment|Increments the float value of a hash field.
    HKEYS|HKEYS key|Returns all fields of a hash.
    HLEN|HLEN key|Returns the number of fields in a hash.
    HMGET|HMGET key field [field ...]|Returns the values of several hash fields.
    HMSET|HMSET key field value [field value ...]|Sets several hash fields (deprecated: use HSET).
    HPERSIST|HPERSIST key FIELDS numfields field [field ...]|Removes the expiration of hash fields (7.4+).
    HPEXPIRE|HPEXPIRE key milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]|Sets millisecond expirations on hash fields (7.4+).
    HPTTL|HPTTL key FIELDS numfields field [field ...]|Returns the remaining TTL of hash fields in milliseconds (7.4+).
    HRANDFIELD|HRANDFIELD key [count [WITHVALUES]]|Returns random fields of a hash.
    HSCAN|HSCAN key cursor [MATCH pattern] [COUNT count] [NOVALUES]|Iterates hash fields and values.
    HSET|HSET key field value [field value ...]|Sets hash fields.
    HSETEX|HSETEX key [FNX | FXX] [EX seconds | PX ms | EXAT ts | PXAT ts | KEEPTTL] FIELDS numfields field value [...]|Sets hash fields with an expiration (8.0+).
    HSETNX|HSETNX key field value|Sets a hash field only if it does not exist.
    HSTRLEN|HSTRLEN key field|Returns the length of a hash field value.
    HTTL|HTTL key FIELDS numfields field [field ...]|Returns the remaining TTL of hash fields (7.4+).
    HVALS|HVALS key|Returns all values of a hash.
    BLMOVE|BLMOVE source destination LEFT|RIGHT LEFT|RIGHT timeout|Pops from one list and pushes to another, blocking.
    BLMPOP|BLMPOP timeout numkeys key [key ...] LEFT|RIGHT [COUNT count]|Pops from the first non-empty list, blocking.
    BLPOP|BLPOP key [key ...] timeout|Removes and returns the first element of a list, blocking.
    BRPOP|BRPOP key [key ...] timeout|Removes and returns the last element of a list, blocking.
    BRPOPLPUSH|BRPOPLPUSH source destination timeout|Pops and pushes between lists, blocking (deprecated).
    LINDEX|LINDEX key index|Returns an element of a list by index.
    LINSERT|LINSERT key BEFORE|AFTER pivot element|Inserts an element before or after another.
    LLEN|LLEN key|Returns the length of a list.
    LMOVE|LMOVE source destination LEFT|RIGHT LEFT|RIGHT|Pops from one list and pushes to another.
    LMPOP|LMPOP numkeys key [key ...] LEFT|RIGHT [COUNT count]|Pops elements from the first non-empty list.
    LPOP|LPOP key [count]|Removes and returns the first elements of a list.
    LPOS|LPOS key element [RANK rank] [COUNT num] [MAXLEN len]|Returns the index of matching elements.
    LPUSH|LPUSH key element [element ...]|Prepends elements to a list.
    LPUSHX|LPUSHX key element [element ...]|Prepends elements only if the list exists.
    LRANGE|LRANGE key start stop|Returns a range of elements from a list.
    LREM|LREM key count element|Removes elements from a list.
    LSET|LSET key index element|Sets the value of an element by index.
    LTRIM|LTRIM key start stop|Trims a list to the given range.
    RPOP|RPOP key [count]|Removes and returns the last elements of a list.
    RPOPLPUSH|RPOPLPUSH source destination|Pops the last element and pushes it to another list.
    RPUSH|RPUSH key element [element ...]|Appends elements to a list.
    RPUSHX|RPUSHX key element [element ...]|Appends elements only if the list exists.
    SADD|SADD key member [member ...]|Adds members to a set.
    SCARD|SCARD key|Returns the number of members of a set.
    SDIFF|SDIFF key [key ...]|Returns the difference of sets.
    SDIFFSTORE|SDIFFSTORE destination key [key ...]|Stores the difference of sets.
    SINTER|SINTER key [key ...]|Returns the intersection of sets.
    SINTERCARD|SINTERCARD numkeys key [key ...] [LIMIT limit]|Returns the size of the intersection of sets.
    SINTERSTORE|SINTERSTORE destination key [key ...]|Stores the intersection of sets.
    SISMEMBER|SISMEMBER key member|Determines whether a member belongs to a set.
    SMEMBERS|SMEMBERS key|Returns all members of a set.
    SMISMEMBER|SMISMEMBER key member [member ...]|Checks several members at once.
    SMOVE|SMOVE source destination member|Moves a member between sets.
    SPOP|SPOP key [count]|Removes and returns random members.
    SRANDMEMBER|SRANDMEMBER key [count]|Returns random members.
    SREM|SREM key member [member ...]|Removes members from a set.
    SSCAN|SSCAN key cursor [MATCH pattern] [COUNT count]|Iterates set members.
    SUNION|SUNION key [key ...]|Returns the union of sets.
    SUNIONSTORE|SUNIONSTORE destination key [key ...]|Stores the union of sets.
    BZPOPMAX|BZPOPMAX key [key ...] timeout|Pops the highest-scored member, blocking.
    BZPOPMIN|BZPOPMIN key [key ...] timeout|Pops the lowest-scored member, blocking.
    ZADD|ZADD key [NX | XX] [GT | LT] [CH] [INCR] score member [score member ...]|Adds members with scores to a sorted set.
    ZCARD|ZCARD key|Returns the number of members in a sorted set.
    ZCOUNT|ZCOUNT key min max|Counts members within a score range.
    ZDIFF|ZDIFF numkeys key [key ...] [WITHSCORES]|Returns the difference of sorted sets.
    ZINCRBY|ZINCRBY key increment member|Increments the score of a member.
    ZINTER|ZINTER numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE SUM|MIN|MAX] [WITHSCORES]|Returns the intersection of sorted sets.
    ZINTERSTORE|ZINTERSTORE destination numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE SUM|MIN|MAX]|Stores the intersection of sorted sets.
    ZLEXCOUNT|ZLEXCOUNT key min max|Counts members within a lexicographical range.
    ZMSCORE|ZMSCORE key member [member ...]|Returns the scores of several members.
    ZPOPMAX|ZPOPMAX key [count]|Removes and returns the highest-scored members.
    ZPOPMIN|ZPOPMIN key [count]|Removes and returns the lowest-scored members.
    ZRANDMEMBER|ZRANDMEMBER key [count [WITHSCORES]]|Returns random members.
    ZRANGE|ZRANGE key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]|Returns members within a range of indexes, scores or lex values.
    ZRANGEBYLEX|ZRANGEBYLEX key min max [LIMIT offset count]|Returns members in a lexicographical range.
    ZRANGEBYSCORE|ZRANGEBYSCORE key min max [WITHSCORES] [LIMIT offset count]|Returns members within a score range.
    ZRANK|ZRANK key member [WITHSCORE]|Returns the rank of a member.
    ZREM|ZREM key member [member ...]|Removes members from a sorted set.
    ZREMRANGEBYRANK|ZREMRANGEBYRANK key start stop|Removes members within a range of ranks.
    ZREMRANGEBYSCORE|ZREMRANGEBYSCORE key min max|Removes members within a score range.
    ZREVRANGE|ZREVRANGE key start stop [WITHSCORES]|Returns members by rank, highest score first.
    ZREVRANK|ZREVRANK key member [WITHSCORE]|Returns the rank of a member, highest score first.
    ZSCAN|ZSCAN key cursor [MATCH pattern] [COUNT count]|Iterates members and scores.
    ZSCORE|ZSCORE key member|Returns the score of a member.
    ZUNION|ZUNION numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE SUM|MIN|MAX] [WITHSCORES]|Returns the union of sorted sets.
    ZUNIONSTORE|ZUNIONSTORE destination numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE SUM|MIN|MAX]|Stores the union of sorted sets.
    XACK|XACK key group id [id ...]|Acknowledges messages of a consumer group.
    XADD|XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]] *|id field value [field value ...]|Appends an entry to a stream.
    XAUTOCLAIM|XAUTOCLAIM key group consumer min-idle-time start [COUNT count] [JUSTID]|Transfers ownership of idle pending messages.
    XCLAIM|XCLAIM key group consumer min-idle-time id [id ...] [IDLE ms] [TIME ms] [RETRYCOUNT n] [FORCE] [JUSTID]|Changes ownership of pending messages.
    XDEL|XDEL key id [id ...]|Deletes entries from a stream.
    XGROUP CREATE|XGROUP CREATE key group id|$ [MKSTREAM] [ENTRIESREAD n]|Creates a consumer group.
    XGROUP CREATECONSUMER|XGROUP CREATECONSUMER key group consumer|Creates a consumer in a group.
    XGROUP DELCONSUMER|XGROUP DELCONSUMER key group consumer|Deletes a consumer from a group.
    XGROUP DESTROY|XGROUP DESTROY key group|Destroys a consumer group.
    XGROUP SETID|XGROUP SETID key group id|$ [ENTRIESREAD n]|Sets the last delivered ID of a group.
    XINFO CONSUMERS|XINFO CONSUMERS key group|Lists the consumers of a group.
    XINFO GROUPS|XINFO GROUPS key|Lists the consumer groups of a stream.
    XINFO STREAM|XINFO STREAM key [FULL [COUNT count]]|Returns information about a stream.
    XLEN|XLEN key|Returns the number of entries in a stream.
    XPENDING|XPENDING key group [[IDLE min-idle-time] start end count [consumer]]|Returns pending messages of a group.
    XRANGE|XRANGE key start end [COUNT count]|Returns entries within an ID range.
    XREAD|XREAD [COUNT count] [BLOCK ms] STREAMS key [key ...] id [id ...]|Reads entries from streams.
    XREADGROUP|XREADGROUP GROUP group consumer [COUNT n] [BLOCK ms] [NOACK] STREAMS key [key ...] id [id ...]|Reads entries as a consumer group member.
    XREVRANGE|XREVRANGE key end start [COUNT count]|Returns entries in reverse ID order.
    XTRIM|XTRIM key MAXLEN|MINID [=|~] threshold [LIMIT count]|Trims a stream.
    GEOADD|GEOADD key [NX | XX] [CH] longitude latitude member [...]|Adds geospatial members.
    GEODIST|GEODIST key member1 member2 [M | KM | FT | MI]|Returns the distance between two members.
    GEOHASH|GEOHASH key member [member ...]|Returns members as geohash strings.
    GEOPOS|GEOPOS key member [member ...]|Returns the coordinates of members.
    GEOSEARCH|GEOSEARCH key FROMMEMBER member|FROMLONLAT lon lat BYRADIUS r unit|BYBOX w h unit [ASC|DESC] [COUNT n [ANY]] [WITHCOORD] [WITHDIST] [WITHHASH]|Searches members in an area.
    PFADD|PFADD key [element [element ...]]|Adds elements to a HyperLogLog.
    PFCOUNT|PFCOUNT key [key ...]|Returns the approximated cardinality.
    PFMERGE|PFMERGE destkey [sourcekey ...]|Merges HyperLogLogs.
    COPY|COPY source destination [DB db] [REPLACE]|Copies a key (6.2+).
    DEL|DEL key [key ...]|Deletes keys (blocking; prefer UNLINK on 4.0+).
    DUMP|DUMP key|Returns a serialized representation of a value.
    EXISTS|EXISTS key [key ...]|Counts how many of the keys exist.
    EXPIRE|EXPIRE key seconds [NX | XX | GT | LT]|Sets a timeout on a key in seconds.
    EXPIREAT|EXPIREAT key unix-time-seconds [NX | XX | GT | LT]|Sets the expiration to a Unix timestamp.
    EXPIRETIME|EXPIRETIME key|Returns the expiration Unix timestamp (7.0+).
    KEYS|KEYS pattern|Returns all keys matching a pattern — blocks the server; prefer SCAN.
    MIGRATE|MIGRATE host port key|"" destination-db timeout [COPY] [REPLACE] [AUTH password | AUTH2 user password] [KEYS key ...]|Atomically moves keys to another instance.
    MOVE|MOVE key db|Moves a key to another database.
    OBJECT ENCODING|OBJECT ENCODING key|Returns the internal encoding of a value.
    OBJECT FREQ|OBJECT FREQ key|Returns the access frequency (LFU policies only).
    OBJECT IDLETIME|OBJECT IDLETIME key|Returns seconds since the last access.
    OBJECT REFCOUNT|OBJECT REFCOUNT key|Returns the reference count of a value.
    PERSIST|PERSIST key|Removes the expiration of a key.
    PEXPIRE|PEXPIRE key milliseconds [NX | XX | GT | LT]|Sets a timeout in milliseconds.
    PEXPIREAT|PEXPIREAT key unix-time-ms [NX | XX | GT | LT]|Sets the expiration to a Unix timestamp in milliseconds.
    PTTL|PTTL key|Returns the remaining TTL in milliseconds.
    RANDOMKEY|RANDOMKEY|Returns a random key name.
    RENAME|RENAME key newkey|Renames a key, overwriting the destination.
    RENAMENX|RENAMENX key newkey|Renames a key only if the new name does not exist.
    RESTORE|RESTORE key ttl serialized-value [REPLACE] [ABSTTL] [IDLETIME s] [FREQ f]|Creates a key from a DUMP payload.
    SCAN|SCAN cursor [MATCH pattern] [COUNT count] [TYPE type]|Iterates the keyspace incrementally.
    SORT|SORT key [BY pattern] [LIMIT offset count] [GET pattern ...] [ASC | DESC] [ALPHA] [STORE destination]|Sorts the elements of a list, set or sorted set.
    TOUCH|TOUCH key [key ...]|Updates the last access time of keys.
    TTL|TTL key|Returns the remaining TTL in seconds.
    TYPE|TYPE key|Returns the type of the value stored at a key.
    UNLINK|UNLINK key [key ...]|Deletes keys asynchronously (4.0+).
    WAIT|WAIT numreplicas timeout|Waits for replication of previous writes.
    AUTH|AUTH [username] password|Authenticates the connection.
    CLIENT GETNAME|CLIENT GETNAME|Returns the name of the connection.
    CLIENT ID|CLIENT ID|Returns the unique ID of the connection.
    CLIENT INFO|CLIENT INFO|Returns information about the connection.
    CLIENT KILL|CLIENT KILL ip:port | ID id | USER name | ADDR ip:port …|Terminates client connections.
    CLIENT LIST|CLIENT LIST [TYPE NORMAL|MASTER|REPLICA|PUBSUB] [ID id ...]|Lists connected clients.
    CLIENT PAUSE|CLIENT PAUSE timeout [WRITE | ALL]|Suspends commands from clients.
    CLIENT SETNAME|CLIENT SETNAME name|Sets the name of the connection.
    CLIENT TRACKING|CLIENT TRACKING ON|OFF [REDIRECT id] [PREFIX p ...] [BCAST] [OPTIN] [OPTOUT] [NOLOOP]|Controls server-assisted client-side caching.
    ECHO|ECHO message|Returns the given string.
    HELLO|HELLO [protover [AUTH username password] [SETNAME clientname]]|Handshakes and selects the protocol (RESP2/RESP3).
    PING|PING [message]|Returns PONG (or the message).
    RESET|RESET|Resets the connection state.
    SELECT|SELECT index|Changes the selected database.
    DISCARD|DISCARD|Discards a transaction.
    EXEC|EXEC|Executes a transaction.
    MULTI|MULTI|Starts a transaction.
    UNWATCH|UNWATCH|Forgets watched keys.
    WATCH|WATCH key [key ...]|Watches keys for an optimistic transaction.
    EVAL|EVAL script numkeys [key ...] [arg ...]|Runs a Lua script.
    EVALSHA|EVALSHA sha1 numkeys [key ...] [arg ...]|Runs a cached Lua script.
    EVAL_RO|EVAL_RO script numkeys [key ...] [arg ...]|Runs a read-only Lua script (7.0+).
    FCALL|FCALL function numkeys [key ...] [arg ...]|Calls a function (7.0+).
    FCALL_RO|FCALL_RO function numkeys [key ...] [arg ...]|Calls a read-only function (7.0+).
    FUNCTION LIST|FUNCTION LIST [LIBRARYNAME pattern] [WITHCODE]|Lists libraries and functions.
    FUNCTION LOAD|FUNCTION LOAD [REPLACE] code|Loads a function library.
    FUNCTION DELETE|FUNCTION DELETE library|Deletes a library.
    FUNCTION FLUSH|FUNCTION FLUSH [ASYNC | SYNC]|Deletes all libraries.
    SCRIPT EXISTS|SCRIPT EXISTS sha1 [sha1 ...]|Checks scripts in the cache.
    SCRIPT FLUSH|SCRIPT FLUSH [ASYNC | SYNC]|Removes all scripts from the cache.
    SCRIPT KILL|SCRIPT KILL|Kills the running script.
    SCRIPT LOAD|SCRIPT LOAD script|Loads a script into the cache.
    PSUBSCRIBE|PSUBSCRIBE pattern [pattern ...]|Subscribes to channels matching patterns.
    PUBLISH|PUBLISH channel message|Posts a message to a channel.
    PUBSUB CHANNELS|PUBSUB CHANNELS [pattern]|Lists active channels.
    PUBSUB NUMPAT|PUBSUB NUMPAT|Returns the number of pattern subscriptions.
    PUBSUB NUMSUB|PUBSUB NUMSUB [channel ...]|Returns subscriber counts of channels.
    PUNSUBSCRIBE|PUNSUBSCRIBE [pattern ...]|Stops listening to patterns.
    SPUBLISH|SPUBLISH shardchannel message|Posts a message to a shard channel (7.0+).
    SSUBSCRIBE|SSUBSCRIBE shardchannel [shardchannel ...]|Subscribes to shard channels (7.0+).
    SUBSCRIBE|SUBSCRIBE channel [channel ...]|Subscribes to channels.
    UNSUBSCRIBE|UNSUBSCRIBE [channel ...]|Stops listening to channels.
    ACL CAT|ACL CAT [category]|Lists ACL categories.
    ACL DELUSER|ACL DELUSER username [username ...]|Deletes ACL users.
    ACL GETUSER|ACL GETUSER username|Returns the rules of a user.
    ACL LIST|ACL LIST|Lists ACL rules.
    ACL LOG|ACL LOG [count | RESET]|Lists recent ACL denials.
    ACL SETUSER|ACL SETUSER username [rule ...]|Creates or modifies a user.
    ACL USERS|ACL USERS|Lists user names.
    ACL WHOAMI|ACL WHOAMI|Returns the authenticated user.
    BGREWRITEAOF|BGREWRITEAOF|Rewrites the append-only file in the background.
    BGSAVE|BGSAVE [SCHEDULE]|Saves the dataset in the background.
    COMMAND|COMMAND|Returns details about all commands.
    COMMAND COUNT|COMMAND COUNT|Returns the number of commands.
    COMMAND DOCS|COMMAND DOCS [command ...]|Returns documentary information about commands (7.0+).
    COMMAND GETKEYS|COMMAND GETKEYS command [arg ...]|Extracts the keys of a full command.
    COMMAND INFO|COMMAND INFO [command ...]|Returns details about commands.
    COMMAND LIST|COMMAND LIST [FILTERBY MODULE m | ACLCAT c | PATTERN p]|Lists command names (7.0+).
    CONFIG GET|CONFIG GET parameter [parameter ...]|Returns configuration parameters.
    CONFIG RESETSTAT|CONFIG RESETSTAT|Resets statistics.
    CONFIG REWRITE|CONFIG REWRITE|Writes the configuration to the config file.
    CONFIG SET|CONFIG SET parameter value [parameter value ...]|Sets configuration parameters.
    DBSIZE|DBSIZE|Returns the number of keys in the database.
    DEBUG|DEBUG subcommand …|Debugging commands (dangerous).
    FAILOVER|FAILOVER [TO host port [FORCE]] [ABORT] [TIMEOUT ms]|Starts a coordinated failover (6.2+).
    FLUSHALL|FLUSHALL [ASYNC | SYNC]|Deletes every key in every database.
    FLUSHDB|FLUSHDB [ASYNC | SYNC]|Deletes every key in the current database.
    INFO|INFO [section ...]|Returns information and statistics about the server.
    LASTSAVE|LASTSAVE|Returns the Unix time of the last successful save.
    LATENCY DOCTOR|LATENCY DOCTOR|Returns a human-readable latency analysis.
    LATENCY LATEST|LATENCY LATEST|Returns the latest latency samples.
    LOLWUT|LOLWUT [VERSION version]|Displays computer art and the version.
    MEMORY DOCTOR|MEMORY DOCTOR|Returns a memory problems report.
    MEMORY STATS|MEMORY STATS|Returns memory usage details.
    MEMORY USAGE|MEMORY USAGE key [SAMPLES count]|Estimates the memory used by a key (4.0+).
    MODULE LIST|MODULE LIST|Lists loaded modules.
    MONITOR|MONITOR|Streams every command processed by the server.
    REPLICAOF|REPLICAOF host port | NO ONE|Configures replication.
    ROLE|ROLE|Returns the replication role.
    SAVE|SAVE|Synchronously saves the dataset (blocks the server).
    SHUTDOWN|SHUTDOWN [NOSAVE | SAVE] [NOW] [FORCE] [ABORT]|Stops the server.
    SLOWLOG GET|SLOWLOG GET [count]|Returns slow log entries.
    SLOWLOG LEN|SLOWLOG LEN|Returns the number of slow log entries.
    SLOWLOG RESET|SLOWLOG RESET|Clears the slow log.
    SWAPDB|SWAPDB index1 index2|Swaps two databases.
    TIME|TIME|Returns the server time.
    CLUSTER COUNTKEYSINSLOT|CLUSTER COUNTKEYSINSLOT slot|Counts keys in a slot.
    CLUSTER FAILOVER|CLUSTER FAILOVER [FORCE | TAKEOVER]|Forces a replica to take over its master.
    CLUSTER GETKEYSINSLOT|CLUSTER GETKEYSINSLOT slot count|Returns key names in a slot.
    CLUSTER INFO|CLUSTER INFO|Returns the state of the cluster.
    CLUSTER KEYSLOT|CLUSTER KEYSLOT key|Returns the hash slot of a key.
    CLUSTER MYID|CLUSTER MYID|Returns the node ID.
    CLUSTER NODES|CLUSTER NODES|Returns the cluster configuration of a node.
    CLUSTER REPLICAS|CLUSTER REPLICAS node-id|Lists the replicas of a master.
    CLUSTER SHARDS|CLUSTER SHARDS|Returns the mapping of shards to slots (7.0+).
    CLUSTER SLOTS|CLUSTER SLOTS|Returns the mapping of slots to nodes.
    READONLY|READONLY|Enables reads on a cluster replica connection.
    READWRITE|READWRITE|Disables reads on a cluster replica connection.
    SENTINEL GET-MASTER-ADDR-BY-NAME|SENTINEL GET-MASTER-ADDR-BY-NAME master-name|Returns the address of a master.
    SENTINEL MASTERS|SENTINEL MASTERS|Lists monitored masters.
    SENTINEL REPLICAS|SENTINEL REPLICAS master-name|Lists the replicas of a master.
    JSON.GET|JSON.GET key [INDENT s] [NEWLINE s] [SPACE s] [path ...]|Returns JSON values.
    JSON.SET|JSON.SET key path value [NX | XX]|Sets a JSON value.
    JSON.DEL|JSON.DEL key [path]|Deletes a JSON value.
    JSON.TYPE|JSON.TYPE key [path]|Returns the type of a JSON value.
    JSON.MGET|JSON.MGET key [key ...] path|Returns values from several documents.
    JSON.ARRAPPEND|JSON.ARRAPPEND key path value [value ...]|Appends to a JSON array.
    JSON.NUMINCRBY|JSON.NUMINCRBY key path value|Increments a JSON number.
    JSON.OBJKEYS|JSON.OBJKEYS key [path]|Returns the keys of a JSON object.
    FT._LIST|FT._LIST|Lists search indexes.
    FT.INFO|FT.INFO index|Returns information about an index.
    FT.SEARCH|FT.SEARCH index query [NOCONTENT] [LIMIT offset num] [RETURN n field ...] [SORTBY field [ASC|DESC]] …|Searches an index.
    FT.AGGREGATE|FT.AGGREGATE index query …|Runs an aggregation query.
    FT.CREATE|FT.CREATE index [ON HASH|JSON] [PREFIX n prefix ...] SCHEMA field type …|Creates a search index.
    """
    // swiftlint:enable line_length
}
