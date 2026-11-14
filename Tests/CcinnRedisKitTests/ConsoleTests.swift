import Foundation
import RedisKit
import RESPWire
import Testing
@testable import CcinnRedisKit

@Suite("CLI tokenizer")
struct CLITokenizerTests {
    @Test func splitsLikeRedisCli() throws {
        #expect(try CLITokenizer.tokenize("SET  key   value") == ["SET", "key", "value"].map { Array($0.utf8) })
        #expect(try CLITokenizer.tokenize(#"SET "hello world" 'single quoted'"#) == ["SET", "hello world", "single quoted"].map { Array($0.utf8) })
        #expect(try CLITokenizer.tokenize(#"SET k "a\nb\t\"q\"\x41\xff""#) == [Array("SET".utf8), Array("k".utf8), Array("a\nb\t\"q\"A".utf8) + [0xFF]])
        #expect(try CLITokenizer.tokenize(#"SET k 'it\'s'"#) == ["SET", "k", "it's"].map { Array($0.utf8) })
        #expect(try CLITokenizer.tokenize(#"SET k """#) == ["SET", "k", ""].map { Array($0.utf8) })
        #expect(try CLITokenizer.tokenize("   ").isEmpty)
        #expect(try CLITokenizer.tokenize("SET 吉隆坡 🇲🇾") == ["SET", "吉隆坡", "🇲🇾"].map { Array($0.utf8) })
    }

    @Test func unbalancedQuotesAreErrors() {
        #expect(throws: CLITokenizer.TokenizeError.self) { try CLITokenizer.tokenize(#"SET k "open"#) }
        #expect(throws: CLITokenizer.TokenizeError.self) { try CLITokenizer.tokenize(#"SET k "a"b"#) }
    }

    @Test func partialTokenizationForCompletion() {
        let partial = CLITokenizer.partial("HSET user:1 na")
        #expect(partial.completed.map { String(decoding: $0, as: UTF8.self) } == ["HSET", "user:1"])
        #expect(partial.current == "na")
        let afterSpace = CLITokenizer.partial("GET ")
        #expect(afterSpace.completed.count == 1)
        #expect(afterSpace.current.isEmpty)
        let quoted = CLITokenizer.partial(#"SET "my key"#)
        #expect(quoted.current == "my key")
        #expect(quoted.isQuoted)
    }
}

@Suite("Reply formatter")
struct ReplyFormatterTests {
    @Test func scalarsLikeRedisCli() {
        #expect(ReplyFormatter.format(.simpleString("OK")) == "OK")
        #expect(ReplyFormatter.format(.integer(42)) == "(integer) 42")
        #expect(ReplyFormatter.format(.null) == "(nil)")
        #expect(ReplyFormatter.format(.error("ERR boom")) == "(error) ERR boom")
        #expect(ReplyFormatter.format(.bulkString(Array("hi".utf8))) == "\"hi\"")
        #expect(ReplyFormatter.format(.bulkString([0x61, 0x0A, 0xFF])) == "\"a\\n\\xff\"")
        #expect(ReplyFormatter.format(.double(1.5)) == "(double) 1.5")
        #expect(ReplyFormatter.format(.boolean(true)) == "(true)")
        #expect(ReplyFormatter.format(.bigNumber("123")) == "(big number) 123")
        #expect(ReplyFormatter.format(.verbatim(format: "txt", text: Array("line1\nline2".utf8))) == "line1\nline2")
        #expect(ReplyFormatter.format(.array([])) == "(empty array)")
    }

    @Test func nestedAggregatesAreNumberedAndIndented() {
        let value = RESPValue.array([.integer(1), .null, .array([.bulkString(Array("a".utf8)), .bulkString(Array("b".utf8))])])
        #expect(ReplyFormatter.format(value) == "1) (integer) 1\n2) (nil)\n3) 1) \"a\"\n   2) \"b\"")
        let wide = RESPValue.array((1...10).map { .integer(Int64($0)) })
        #expect(ReplyFormatter.format(wide).split(separator: "\n").last == "10) (integer) 10")
        #expect(ReplyFormatter.format(wide).split(separator: "\n").first == " 1) (integer) 1")
    }

    @Test func resp3MapsAndSets() {
        let map = RESPValue.map([RESPPair(.bulkString(Array("server".utf8)), .bulkString(Array("redis".utf8))), RESPPair(.bulkString(Array("proto".utf8)), .integer(3))])
        #expect(ReplyFormatter.format(map) == "1# \"server\" => \"redis\"\n2# \"proto\" => (integer) 3")
        #expect(ReplyFormatter.format(.set([.integer(1)])) == "1~ (integer) 1")
    }

    @Test func outputIsBoundedForHugeReplies() {
        let huge = RESPValue.array((0..<50_000).map { .integer(Int64($0)) })
        let text = ReplyFormatter.format(huge, limits: ReplyFormatter.Limits(maxElements: 1000, maxStringBytes: 100))
        #expect(text.contains("49000 more"))
        #expect(text.split(separator: "\n").count < 1100)
        let long = ReplyFormatter.format(.bulkString(Array(repeating: 0x61, count: 10_000)), limits: ReplyFormatter.Limits(maxElements: 10, maxStringBytes: 100))
        #expect(long.count < 200)
        #expect(long.contains("9900 more bytes"))
    }

    @Test func rawModePrintsPayloadsVerbatim() {
        #expect(ReplyFormatter.format(.bulkString(Array("a b".utf8)), style: .raw) == "a b")
        #expect(ReplyFormatter.format(.array([.integer(1), .bulkString(Array("x".utf8))]), style: .raw) == "1\nx")
    }
}

@Suite("Command safety")
struct CommandSafetyTests {
    private func command(_ line: String) throws -> RedisCommand {
        RedisCommand(rawArguments: try CLITokenizer.tokenize(line))
    }

    @Test func flushNeedsTypedConfirmation() throws {
        let flushdb = CommandSafety.assess(try command("flushdb"), database: 3, connectionName: "prod")
        #expect(flushdb == .typedConfirmation(expected: "3", reason: CommandSafety.Assessment.flushReason(name: "FLUSHDB", target: "database 3")))
        let flushall = CommandSafety.assess(try command("FLUSHALL ASYNC"), database: 0, connectionName: "prod")
        guard case let .typedConfirmation(expected, _) = flushall else { Issue.record("expected typed confirmation"); return }
        #expect(expected == "prod")
    }

    @Test func dangerousCommandsNeedConfirmation() throws {
        for line in ["CONFIG SET maxmemory 1gb", "SHUTDOWN", "KEYS *", "DEBUG SLEEP 1", "CLIENT KILL ID 3", "SWAPDB 0 1", "SCRIPT FLUSH"] {
            guard case .confirmation = CommandSafety.assess(try command(line), database: 0, connectionName: "x") else {
                Issue.record("\(line) should need confirmation")
                continue
            }
        }
        #expect(CommandSafety.assess(try command("GET a"), database: 0, connectionName: "x") == .allowed)
        #expect(CommandSafety.assess(try command("CONFIG GET maxmemory"), database: 0, connectionName: "x") == .allowed)
        #expect(CommandSafety.assess(try command("DEL a"), database: 0, connectionName: "x") == .allowed)
    }
}

@Suite("Console history")
struct ConsoleHistoryTests {
    @Test func redactsSecrets() {
        #expect(ConsoleHistory.redact("AUTH secret") == "AUTH ••••")
        #expect(ConsoleHistory.redact("auth alice secret") == "auth alice ••••")
        #expect(ConsoleHistory.redact("HELLO 3 AUTH default pw SETNAME x") == "HELLO 3 AUTH default •••• SETNAME x")
        #expect(ConsoleHistory.redact("CONFIG SET requirepass hunter2") == "CONFIG SET requirepass ••••")
        #expect(ConsoleHistory.redact("CONFIG SET masterauth hunter2") == "CONFIG SET masterauth ••••")
        #expect(ConsoleHistory.redact("ACL SETUSER bob on >pw1 >pw2 ~*") == "ACL SETUSER bob on >•••• >•••• ~*")
        #expect(ConsoleHistory.redact("MIGRATE h 6379 k 0 1000 AUTH pw") == "MIGRATE h 6379 k 0 1000 AUTH ••••")
        #expect(ConsoleHistory.redact("MIGRATE h 6379 k 0 1000 AUTH2 user pw") == "MIGRATE h 6379 k 0 1000 AUTH2 user ••••")
        #expect(ConsoleHistory.redact("GET auth") == "GET auth")
    }

    @Test func boundedAndNavigable() {
        var history = ConsoleHistory(limit: 3)
        for line in ["a", "b", "b", "c", "d"] { history.record(line) }
        #expect(history.entries == ["b", "c", "d"])
        #expect(history.previous(current: "draft") == "d")
        #expect(history.previous(current: "") == "c")
        #expect(history.next() == "d")
        #expect(history.next() == "draft")
        history.record("AUTH pw")
        #expect(history.entries.last == "AUTH ••••")
    }

    @Test func persistsPerProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        var history = ConsoleHistory(limit: 10)
        history.record("PING")
        try history.save(directory: directory, profileID: id)
        let loaded = ConsoleHistory.load(directory: directory, profileID: id, limit: 10)
        #expect(loaded.entries == ["PING"])
    }
}

@Suite("Completion")
struct CompletionTests {
    private let catalog = CommandCatalog(serverVersion: ServerVersion(7, 2, 0), family: .redis, extra: [])

    @Test func commandNamesFilteredByVersion() {
        let result = CompletionEngine.complete(line: "HGE", cursor: 3, catalog: catalog, keys: { _, _ in [] })
        let labels = result.items.map(\.label)
        #expect(labels.contains("HGET"))
        #expect(labels.contains("HGETALL"))
        #expect(!labels.contains("HGETDEL")) // 8.0 only
        #expect(result.replacementRange == 0..<3)
        let redis8 = CommandCatalog(serverVersion: ServerVersion(8, 0, 0), family: .redis, extra: [])
        #expect(CompletionEngine.complete(line: "hge", cursor: 3, catalog: redis8, keys: { _, _ in [] }).items.map(\.label).contains("HGETDEL"))
    }

    @Test func subcommandsAndKeys() {
        let sub = CompletionEngine.complete(line: "CONFIG G", cursor: 8, catalog: catalog, keys: { _, _ in [] })
        #expect(sub.items.map(\.label) == ["GET"])
        let keys = CompletionEngine.complete(line: "GET us", cursor: 6, catalog: catalog, keys: { prefix, _ in
            ["user:1", "user:2"].filter { $0.hasPrefix(prefix) }.map(RedisKey.init)
        })
        #expect(keys.items.map(\.label) == ["user:1", "user:2"])
        #expect(keys.items.first?.kind == .key)
        #expect(keys.replacementRange == 4..<6)
        // Values are not completed with keys.
        let value = CompletionEngine.complete(line: "SET k v", cursor: 7, catalog: catalog, keys: { _, _ in [RedisKey("v1")] })
        #expect(value.items.isEmpty)
    }

    @Test func syntaxHintForTheCurrentCommand() {
        let hint = catalog.documentation(for: "zadd")
        #expect(hint?.syntax.contains("score member") == true)
        #expect(hint?.summary.isEmpty == false)
        #expect(catalog.documentation(for: "config get")?.syntax.contains("parameter") == true)
    }

    @Test func moduleCommandsFromServerAreIncluded() {
        let spec = CommandSpec(name: "FT.SEARCH", arity: -3, flags: [.readonly], keys: .none, since: ServerVersion(1), group: "module")
        let withModules = CommandCatalog(serverVersion: ServerVersion(7, 2, 0), family: .redis, extra: [spec])
        let labels = CompletionEngine.complete(line: "FT.S", cursor: 4, catalog: withModules, keys: { _, _ in [] }).items.map(\.label)
        #expect(labels.contains("FT.SEARCH"))
    }
}
