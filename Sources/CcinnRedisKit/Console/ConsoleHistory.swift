import Foundation

/// Bounded per-profile command history with secret redaction (design D12).
public struct ConsoleHistory: Sendable, Equatable {
    public private(set) var entries: [String] = []
    public let limit: Int
    private var cursor: Int?
    private var draft = ""

    static let mask = "••••"

    public init(limit: Int = 500, entries: [String] = []) {
        self.limit = max(1, limit)
        self.entries = Array(entries.suffix(self.limit))
    }

    public mutating func record(_ line: String) {
        cursor = nil
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let redacted = Self.redact(trimmed)
        if entries.last != redacted { entries.append(redacted) }
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// Older entry (↑); remembers the unsent draft the first time.
    public mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let cursor {
            self.cursor = max(0, cursor - 1)
        } else {
            draft = current
            cursor = entries.count - 1
        }
        return cursor.map { entries[$0] }
    }

    /// Newer entry (↓); returns the draft after the newest entry.
    public mutating func next() -> String? {
        guard let cursor else { return nil }
        if cursor + 1 < entries.count {
            self.cursor = cursor + 1
            return entries[cursor + 1]
        }
        self.cursor = nil
        return draft
    }

    /// Replaces secrets in AUTH, HELLO … AUTH, CONFIG SET *pass*, ACL SETUSER >pw/#hash, MIGRATE AUTH/AUTH2.
    public static func redact(_ line: String) -> String {
        guard let tokens = try? CLITokenizer.tokenize(line), !tokens.isEmpty else {
            // Untokenizable: hide everything after an AUTH-like command name.
            let words = line.split(separator: " ")
            if let first = words.first, ["AUTH", "HELLO", "ACL", "CONFIG", "MIGRATE"].contains(first.uppercased()) {
                return "\(first) \(mask)"
            }
            return line
        }
        var words = tokens.map { String(decoding: $0, as: UTF8.self) }
        var redacted = Set<Int>()
        let name = words[0].uppercased()
        switch name {
        case "AUTH":
            if words.count >= 2 { redacted.insert(words.count - 1) }
        case "HELLO":
            if let auth = words.firstIndex(where: { $0.uppercased() == "AUTH" }), auth + 2 < words.count { redacted.insert(auth + 2) }
        case "CONFIG":
            if words.count >= 4, words[1].uppercased() == "SET" {
                var index = 2
                while index + 1 < words.count {
                    let parameter = words[index].lowercased()
                    if parameter.contains("pass") || parameter.contains("auth") || parameter.contains("secret") || parameter.contains("key-file-pass") {
                        redacted.insert(index + 1)
                    }
                    index += 2
                }
            }
        case "ACL":
            if words.count > 2, words[1].uppercased() == "SETUSER" {
                for index in 3..<words.count where words[index].hasPrefix(">") || words[index].hasPrefix("#") || words[index].hasPrefix("<") || words[index].hasPrefix("!") {
                    words[index] = String(words[index].prefix(1)) + mask
                }
            }
        case "MIGRATE":
            for index in words.indices {
                if words[index].uppercased() == "AUTH", index + 1 < words.count { redacted.insert(index + 1) }
                if words[index].uppercased() == "AUTH2", index + 2 < words.count { redacted.insert(index + 2) }
            }
        default:
            return line
        }
        for index in redacted { words[index] = mask }
        return words.enumerated().map { index, word in
            redacted.contains(index) || word.hasSuffix(mask) ? word : CLITokenizer.quote(Array(word.utf8))
        }.joined(separator: " ")
    }

    // MARK: Persistence

    private static func fileURL(directory: URL, profileID: UUID) -> URL {
        directory.appendingPathComponent("console-\(profileID.uuidString).json")
    }

    public func save(directory: URL, profileID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: Self.fileURL(directory: directory, profileID: profileID), options: [.atomic])
    }

    public static func load(directory: URL, profileID: UUID, limit: Int = 500) -> ConsoleHistory {
        guard let data = try? Data(contentsOf: fileURL(directory: directory, profileID: profileID)),
              let entries = try? JSONDecoder().decode([String].self, from: data) else {
            return ConsoleHistory(limit: limit)
        }
        return ConsoleHistory(limit: limit, entries: entries)
    }
}
