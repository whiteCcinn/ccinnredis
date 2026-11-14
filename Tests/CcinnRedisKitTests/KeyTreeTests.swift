import Foundation
import RedisKit
import Testing
@testable import CcinnRedisKit

@Suite("Key tree")
struct KeyTreeTests {
    private func keys(_ names: [String]) -> [RedisKey] { names.map(RedisKey.init) }

    private func describe(_ tree: KeyTreeSnapshot, expanded: Set<[UInt8]>) -> [String] {
        tree.rows(expanded: expanded).map { row in
            String(repeating: "  ", count: row.depth) + (tree.isFolder(row.node) ? "[\(tree.name(of: row.node))] \(tree.leafCount(of: row.node))" : tree.name(of: row.node))
        }
    }

    @Test func groupsByDelimiterWithCountsFoldersFirst() {
        let tree = KeyTreeSnapshot.build(keys: keys(["user:1", "user:2", "order:1", "config", "user:10:profile"]), delimiter: ":")
        #expect(tree.keyCount == 5)
        #expect(describe(tree, expanded: []) == ["[order] 1", "[user] 3", "config"])
        let expanded: Set<[UInt8]> = [Array("user:".utf8)]
        #expect(describe(tree, expanded: expanded) == ["[order] 1", "[user] 3", "  [10] 1", "  1", "  2", "config"])
        let deeper: Set<[UInt8]> = [Array("user:".utf8), Array("user:10:".utf8)]
        #expect(describe(tree, expanded: deeper) == ["[order] 1", "[user] 3", "  [10] 1", "    profile", "  1", "  2", "config"])
    }

    @Test func naturalOrderingOfNumbers() {
        let tree = KeyTreeSnapshot.build(keys: keys(["k:10", "k:9", "k:100", "k:2", "k:1a", "k:1"]), delimiter: ":")
        let rows = describe(tree, expanded: [Array("k:".utf8)])
        #expect(rows == ["[k] 6", "  1", "  1a", "  2", "  9", "  10", "  100"])
    }

    @Test func keyThatIsAlsoAFolderAppearsTwice() {
        let tree = KeyTreeSnapshot.build(keys: keys(["a", "a:b"]), delimiter: ":")
        #expect(describe(tree, expanded: []) == ["[a] 1", "a"])
    }

    @Test func emptyDelimiterGivesAFlatList() {
        let tree = KeyTreeSnapshot.build(keys: keys(["b:1", "a:2"]), delimiter: "")
        #expect(describe(tree, expanded: []) == ["a:2", "b:1"])
    }

    @Test func multiCharacterDelimiterAndEmptySegments() {
        let tree = KeyTreeSnapshot.build(keys: keys(["x::y", "x::z", "x:::w", "a::::b"]), delimiter: "::")
        #expect(describe(tree, expanded: []) == ["[a] 1", "[x] 3"])
        #expect(describe(tree, expanded: [Array("x::".utf8)]) == ["[a] 1", "[x] 3", "  :w", "  y", "  z"])
        // An empty segment becomes a folder with an empty name.
        #expect(describe(tree, expanded: [Array("a::".utf8)]) == ["[a] 1", "  [] 1", "[x] 3"])
    }

    @Test func leafKeysAndFolderPrefixes() throws {
        let tree = KeyTreeSnapshot.build(keys: keys(["user:1", "user:2"]), delimiter: ":")
        let folder = try #require(tree.rows(expanded: []).first?.node)
        #expect(tree.isFolder(folder))
        #expect(tree.prefix(of: folder) == Array("user:".utf8))
        #expect(tree.keys(under: folder).map(\.string) == ["user:1", "user:2"])
        let rows = tree.rows(expanded: [Array("user:".utf8)])
        let leaf = rows[1].node
        #expect(tree.key(of: leaf)?.string == "user:1")
        #expect(tree.key(of: folder) == nil)
    }

    @Test func flatRowsListEveryKeySorted() {
        let tree = KeyTreeSnapshot.build(keys: keys(["b", "a:2", "a:10"]), delimiter: ":")
        #expect(tree.flatRows().map { tree.key(of: $0.node)?.string ?? "" } == ["a:2", "a:10", "b"])
    }

    @Test func binaryKeysAreDisplayedEscaped() {
        let tree = KeyTreeSnapshot.build(keys: [RedisKey(bytes: [0x62, 0x3A, 0xFF, 0x00])], delimiter: ":")
        let rows = tree.rows(expanded: [Array("b:".utf8)])
        #expect(tree.name(of: rows[1].node) == "\\xff\\x00")
    }

    @Test func depthIsBounded() {
        let deep = (0..<100).map(String.init).joined(separator: ":")
        let tree = KeyTreeSnapshot.build(keys: keys([deep]), delimiter: ":", maxDepth: 4)
        var expanded: Set<[UInt8]> = []
        var prefix: [UInt8] = []
        for segment in 0..<4 {
            prefix += Array("\(segment):".utf8)
            expanded.insert(prefix)
        }
        let rows = tree.rows(expanded: expanded)
        #expect(rows.count == 5)
        #expect(tree.key(of: rows[4].node)?.string == deep)
    }

    @Test func buildsTwoHundredThousandKeysQuickly() {
        var names: [RedisKey] = []
        names.reserveCapacity(200_000)
        for index in 0..<200_000 {
            names.append(RedisKey("cache:page:\(["home", "product", "search", "cart"][index % 4]):\(index)"))
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let tree = KeyTreeSnapshot.build(keys: names, delimiter: ":")
            #expect(tree.keyCount == 200_000)
            #expect(tree.rows(expanded: []).count == 1)
        }
        #expect(elapsed < .seconds(20), "built in \(elapsed)")
    }
}

@Suite("Key collection")
struct KeyCollectionTests {
    @Test func deduplicatesAndRemoves() {
        var collection = KeyCollection()
        #expect(collection.append(contentsOf: [RedisKey("a"), RedisKey("b"), RedisKey("a")]) == 2)
        #expect(collection.append(contentsOf: [RedisKey("b"), RedisKey("c")]) == 1)
        #expect(collection.count == 3)
        collection.remove([RedisKey("b")])
        #expect(collection.keys.map(\.string) == ["a", "c"])
        #expect(collection.contains(RedisKey("a")))
        #expect(!collection.contains(RedisKey("b")))
        collection.removeAll()
        #expect(collection.count == 0)
    }

    @Test func prefixSearchForCompletion() {
        var collection = KeyCollection()
        collection.append(contentsOf: ["user:1", "user:2", "order:1", "user:10"].map(RedisKey.init))
        #expect(collection.keys(withPrefix: "user:1", limit: 10).map(\.string) == ["user:1", "user:10"])
        #expect(collection.keys(withPrefix: "zzz", limit: 10).isEmpty)
        #expect(collection.keys(withPrefix: "", limit: 2).count == 2)
    }
}
