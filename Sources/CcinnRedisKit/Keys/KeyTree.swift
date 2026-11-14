import Foundation
import RedisKit

/// Row of the virtualised key browser.
public struct KeyTreeRow: Sendable, Hashable {
    public let node: Int32
    public let depth: Int
}

/// Immutable tree of keys grouped by a delimiter (design D11).
///
/// Built off the main actor from the keys loaded so far; the UI flattens only expanded folders into
/// rows, so a million keys in collapsed folders cost a handful of rows. Folders come first, then keys,
/// both in natural order (`k:2` before `k:10`). Nodes live in one arena array; children are
/// contiguous, so the snapshot is cheap to share across actors.
public final class KeyTreeSnapshot: Sendable {
    struct Node: Sendable {
        let isFolder: Bool
        let depth: Int16
        let parent: Int32
        var firstChild: Int32
        var childCount: Int32
        var leafCount: Int32
        /// Folder: index into `folders`; leaf: index into `keys`.
        let reference: Int32
        /// Leaf: offset of its display name inside the key bytes.
        let nameOffset: Int32
    }

    struct Folder: Sendable {
        let name: [UInt8]
        let prefix: [UInt8]
    }

    public let keys: [RedisKey]
    public let delimiter: String
    let nodes: [Node]
    let children: [Int32]
    let folders: [Folder]

    private init(keys: [RedisKey], delimiter: String, nodes: [Node], children: [Int32], folders: [Folder]) {
        self.keys = keys
        self.delimiter = delimiter
        self.nodes = nodes
        self.children = children
        self.folders = folders
    }

    public static let empty = KeyTreeSnapshot.build(keys: [], delimiter: ":")

    public var keyCount: Int { keys.count }
    public var folderCount: Int { folders.count - 1 }

    public func isFolder(_ node: Int32) -> Bool { valid(node) && nodes[Int(node)].isFolder }

    public func leafCount(of node: Int32) -> Int {
        guard valid(node) else { return 0 }
        return Int(nodes[Int(node)].leafCount)
    }

    /// Display name of the node (folder segment or the key's last part), escaped when not printable.
    public func name(of node: Int32) -> String {
        guard valid(node) else { return "" }
        let entry = nodes[Int(node)]
        if entry.isFolder {
            let folder = folders[Int(entry.reference)]
            return RedisKey(bytes: folder.name).display
        }
        let key = keys[Int(entry.reference)]
        let offset = min(Int(entry.nameOffset), key.bytes.count)
        return RedisKey(bytes: Array(key.bytes[offset...])).display
    }

    /// The key of a leaf.
    public func key(of node: Int32) -> RedisKey? {
        guard valid(node), !nodes[Int(node)].isFolder else { return nil }
        return keys[Int(nodes[Int(node)].reference)]
    }

    /// Bytes of the folder prefix including the trailing delimiter (`user:`), the expansion identity.
    public func prefix(of node: Int32) -> [UInt8]? {
        guard valid(node), nodes[Int(node)].isFolder else { return nil }
        return folders[Int(nodes[Int(node)].reference)].prefix
    }

    /// Every key below a folder (for "delete folder", "export folder").
    public func keys(under node: Int32) -> [RedisKey] {
        guard valid(node) else { return [] }
        var result: [RedisKey] = []
        var stack: [Int32] = [node]
        while let current = stack.popLast() {
            let entry = nodes[Int(current)]
            if entry.isFolder {
                let range = Int(entry.firstChild)..<Int(entry.firstChild + entry.childCount)
                for index in range.reversed() { stack.append(children[index]) }
            } else {
                result.append(keys[Int(entry.reference)])
            }
        }
        return result
    }

    /// Visible rows: root children plus the children of every expanded folder, depth-first.
    public func rows(expanded: Set<[UInt8]>) -> [KeyTreeRow] {
        guard let root = nodes.first else { return [] }
        var rows: [KeyTreeRow] = []
        rows.reserveCapacity(min(Int(root.childCount) + 256, 1 << 20))
        var stack: [Int32] = []
        let rootRange = Int(root.firstChild)..<Int(root.firstChild + root.childCount)
        for index in rootRange.reversed() { stack.append(children[index]) }
        while let current = stack.popLast() {
            let entry = nodes[Int(current)]
            rows.append(KeyTreeRow(node: current, depth: Int(entry.depth) - 1))
            if entry.isFolder, expanded.contains(folders[Int(entry.reference)].prefix) {
                let range = Int(entry.firstChild)..<Int(entry.firstChild + entry.childCount)
                for index in range.reversed() { stack.append(children[index]) }
            }
        }
        return rows
    }

    /// Every key as a row, ignoring folders (flat list mode).
    public func flatRows() -> [KeyTreeRow] {
        var leaves: [Int32] = []
        leaves.reserveCapacity(keys.count)
        for (index, node) in nodes.enumerated() where !node.isFolder { leaves.append(Int32(index)) }
        leaves.sort { lhs, rhs in
            Self.naturalLess(keys[Int(nodes[Int(lhs)].reference)].bytes[...], keys[Int(nodes[Int(rhs)].reference)].bytes[...])
        }
        return leaves.map { KeyTreeRow(node: $0, depth: 0) }
    }

    private func valid(_ node: Int32) -> Bool { node >= 0 && Int(node) < nodes.count }

    // MARK: Building

    public static func build(keys: [RedisKey], delimiter: String, maxDepth: Int = 16) -> KeyTreeSnapshot {
        let separator = Array(delimiter.utf8)
        let depthLimit = max(1, min(maxDepth, 64))

        struct WorkFolder {
            let name: [UInt8]
            let prefix: [UInt8]
            let depth: Int
            var subfolders: [[UInt8]: Int] = [:]
            var leaves: [(key: Int32, offset: Int32)] = []
        }
        var work: [WorkFolder] = [WorkFolder(name: [], prefix: [], depth: 0)]

        for (keyIndex, key) in keys.enumerated() {
            let bytes = key.bytes
            var folder = 0
            var start = 0
            var depth = 0
            if !separator.isEmpty {
                while depth < depthLimit, let match = Self.find(separator, in: bytes, from: start) {
                    let segment = Array(bytes[start..<match])
                    if let existing = work[folder].subfolders[segment] {
                        folder = existing
                    } else {
                        let child = WorkFolder(name: segment, prefix: Array(bytes[0..<(match + separator.count)]), depth: work[folder].depth + 1)
                        work.append(child)
                        work[folder].subfolders[segment] = work.count - 1
                        folder = work.count - 1
                    }
                    start = match + separator.count
                    depth += 1
                }
            }
            work[folder].leaves.append((Int32(clamping: keyIndex), Int32(clamping: start)))
        }

        // Lay out the arena depth-first with sorted children.
        var nodes: [Node] = []
        nodes.reserveCapacity(keys.count + work.count)
        var children: [Int32] = []
        children.reserveCapacity(keys.count + work.count)
        var folders: [Folder] = []
        folders.reserveCapacity(work.count)

        // Node for the root.
        folders.append(Folder(name: [], prefix: []))
        nodes.append(Node(isFolder: true, depth: 0, parent: -1, firstChild: 0, childCount: 0, leafCount: 0, reference: 0, nameOffset: 0))

        // (workIndex, nodeIndex) queue processed breadth-first so each folder's children are contiguous.
        var queue: [(work: Int, node: Int32)] = [(0, 0)]
        var head = 0
        while head < queue.count {
            let (workIndex, nodeIndex) = queue[head]
            head += 1
            let folder = work[workIndex]
            let subfolders = folder.subfolders.sorted { naturalLess($0.key[...], $1.key[...]) }
            let leaves = folder.leaves.sorted { lhs, rhs in
                let left = keys[Int(lhs.key)].bytes
                let right = keys[Int(rhs.key)].bytes
                let leftName = left[min(Int(lhs.offset), left.count)...]
                let rightName = right[min(Int(rhs.offset), right.count)...]
                if leftName.elementsEqual(rightName) { return left.lexicographicallyPrecedes(right) }
                return naturalLess(leftName, rightName)
            }
            let first = Int32(children.count)
            for (_, childWork) in subfolders {
                let child = work[childWork]
                folders.append(Folder(name: child.name, prefix: child.prefix))
                nodes.append(Node(isFolder: true, depth: Int16(clamping: child.depth), parent: nodeIndex, firstChild: 0, childCount: 0,
                                  leafCount: 0, reference: Int32(folders.count - 1), nameOffset: 0))
                let childNode = Int32(nodes.count - 1)
                children.append(childNode)
                queue.append((childWork, childNode))
            }
            for leaf in leaves {
                nodes.append(Node(isFolder: false, depth: Int16(clamping: folder.depth + 1), parent: nodeIndex, firstChild: 0, childCount: 0,
                                  leafCount: 1, reference: leaf.key, nameOffset: leaf.offset))
                children.append(Int32(nodes.count - 1))
            }
            nodes[Int(nodeIndex)].firstChild = first
            nodes[Int(nodeIndex)].childCount = Int32(children.count) - first
        }

        // Leaf counts bottom-up (children always come after their parent in the arena).
        for index in stride(from: nodes.count - 1, through: 1, by: -1) {
            let parent = Int(nodes[index].parent)
            if parent >= 0 { nodes[parent].leafCount += nodes[index].leafCount }
        }
        return KeyTreeSnapshot(keys: keys, delimiter: delimiter, nodes: nodes, children: children, folders: folders)
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count - start >= needle.count, start >= 0 else { return nil }
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var matched = true
                var offset = 1
                while offset < needle.count {
                    if haystack[index + offset] != needle[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    /// Natural order on bytes: digit runs compare numerically (`2` < `10`), everything else bytewise.
    static func naturalLess(_ lhs: ArraySlice<UInt8>, _ rhs: ArraySlice<UInt8>) -> Bool {
        @inline(__always) func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        var i = lhs.startIndex
        var j = rhs.startIndex
        while i < lhs.endIndex, j < rhs.endIndex {
            let a = lhs[i]
            let b = rhs[j]
            if isDigit(a), isDigit(b) {
                var iEnd = i
                while iEnd < lhs.endIndex, isDigit(lhs[iEnd]) { iEnd += 1 }
                var jEnd = j
                while jEnd < rhs.endIndex, isDigit(rhs[jEnd]) { jEnd += 1 }
                var iStart = i
                while iStart < iEnd - 1, lhs[iStart] == 48 { iStart += 1 }
                var jStart = j
                while jStart < jEnd - 1, rhs[jStart] == 48 { jStart += 1 }
                let leftLength = iEnd - iStart
                let rightLength = jEnd - jStart
                if leftLength != rightLength { return leftLength < rightLength }
                var x = iStart
                var y = jStart
                while x < iEnd {
                    if lhs[x] != rhs[y] { return lhs[x] < rhs[y] }
                    x += 1
                    y += 1
                }
                if iEnd - i != jEnd - j { return iEnd - i < jEnd - j }
                i = iEnd
                j = jEnd
            } else {
                if a != b { return a < b }
                i += 1
                j += 1
            }
        }
        return lhs.endIndex - i < rhs.endIndex - j
    }
}

/// Keys loaded so far: append-only order with a dedupe set (SCAN may repeat keys).
public struct KeyCollection: Sendable {
    public private(set) var keys: [RedisKey] = []
    private var members: Set<RedisKey> = []
    private var sortedCache: [RedisKey]?

    public init() {}

    public var count: Int { keys.count }

    /// Appends unseen keys; returns how many were new.
    @discardableResult
    public mutating func append(contentsOf newKeys: [RedisKey]) -> Int {
        var added = 0
        for key in newKeys where members.insert(key).inserted {
            keys.append(key)
            added += 1
        }
        if added > 0 { sortedCache = nil }
        return added
    }

    public func contains(_ key: RedisKey) -> Bool { members.contains(key) }

    public mutating func remove(_ removed: [RedisKey]) {
        let doomed = Set(removed).intersection(members)
        guard !doomed.isEmpty else { return }
        members.subtract(doomed)
        keys.removeAll { doomed.contains($0) }
        sortedCache = nil
    }

    public mutating func removeAll() {
        keys.removeAll()
        members.removeAll()
        sortedCache = nil
    }

    /// Up to `limit` keys starting with `prefix` (binary search over a lazily sorted copy).
    public mutating func keys(withPrefix prefix: String, limit: Int) -> [RedisKey] {
        let sorted: [RedisKey]
        if let cached = sortedCache {
            sorted = cached
        } else {
            sorted = keys.sorted()
            sortedCache = sorted
        }
        let needle = Array(prefix.utf8)
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].bytes.lexicographicallyPrecedes(needle) { low = mid + 1 } else { high = mid }
        }
        var result: [RedisKey] = []
        var index = low
        while index < sorted.count, result.count < limit, sorted[index].bytes.starts(with: needle) {
            result.append(sorted[index])
            index += 1
        }
        return result
    }
}
