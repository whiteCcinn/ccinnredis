import Foundation

/// Configuration parameters whose values are secrets (passwords, ACL users, TLS key passphrases).
public enum SecretConfig {
    public static func isSecret(_ parameter: String) -> Bool {
        let name = parameter.lowercased()
        return name.contains("pass") || name.contains("auth") || name.contains("secret") || name.contains("key-file")
            || name == "masteruser" || name == "primaryuser"
    }

    public static let mask = "••••••"
}

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

    /// Replaces secrets in AUTH, HELLO … AUTH, CONFIG SET *pass*, ACL SETUSER >pw/#hash, MIGRATE AUTH/AUTH2,
    /// SENTINEL SET … auth-pass/auth-user and SENTINEL CONFIG SET sentinel-pass/sentinel-user.
    public static func redact(_ line: String) -> String {
        guard let tokens = try? CLITokenizer.tokenize(line), !tokens.isEmpty else {
            // Untokenizable: hide everything after an AUTH-like command name.
            let words = line.split(separator: " ")
            if let first = words.first, sensitiveCommands.contains(first.uppercased()) {
                return "\(first) \(mask)"
            }
            return line
        }
        var words = tokens.map { String(decoding: $0, as: UTF8.self) }
        let redacted = secretPositions(in: &words)
        guard !redacted.isEmpty || words != tokens.map({ String(decoding: $0, as: UTF8.self) }) else { return line }
        for index in redacted { words[index] = mask }
        return words.enumerated().map { index, word in
            redacted.contains(index) || word.hasSuffix(mask) ? word : CLITokenizer.quote(Array(word.utf8))
        }.joined(separator: " ")
    }

    /// The same redaction for an argument vector (e.g. a SLOWLOG entry's logged arguments).
    public static func redact(arguments: [[UInt8]]) -> [[UInt8]] {
        guard !arguments.isEmpty else { return arguments }
        var words = arguments.map { String(decoding: $0, as: UTF8.self) }
        let original = words
        let redacted = secretPositions(in: &words)
        guard !redacted.isEmpty || words != original else { return arguments }
        return words.enumerated().map { index, word in redacted.contains(index) ? Array(mask.utf8) : Array(word.utf8) }
    }

    static let sensitiveCommands: Set<String> = ["AUTH", "HELLO", "ACL", "CONFIG", "MIGRATE", "SENTINEL"]

    /// Indexes of secret arguments; ACL SETUSER password rules are masked in place.
    private static func secretPositions(in words: inout [String]) -> Set<Int> {
        var redacted = Set<Int>()
        guard let first = words.first else { return redacted }
        switch first.uppercased() {
        case "AUTH":
            if words.count >= 2 { redacted.insert(words.count - 1) }
        case "HELLO":
            if let auth = words.firstIndex(where: { $0.uppercased() == "AUTH" }), auth + 2 < words.count { redacted.insert(auth + 2) }
        case "CONFIG":
            if words.count >= 4, words[1].uppercased() == "SET" {
                redacted.formUnion(secretValues(in: words, from: 2) { SecretConfig.isSecret($0) })
            }
        case "SENTINEL":
            guard words.count >= 4 else { break }
            let subcommand = words[1].uppercased()
            if subcommand == "SET", words.count >= 5 {
                // SENTINEL SET <master> <option> <value> [<option> <value> …]
                redacted.formUnion(secretValues(in: words, from: 3) { ["auth-pass", "auth-user"].contains($0.lowercased()) })
            } else if subcommand == "CONFIG", words[2].uppercased() == "SET" {
                redacted.formUnion(secretValues(in: words, from: 3) { ["sentinel-pass", "sentinel-user"].contains($0.lowercased()) })
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
            break
        }
        return redacted
    }

    /// Value positions of `name value` pairs starting at `start` whose name is secret.
    private static func secretValues(in words: [String], from start: Int, isSecret: (String) -> Bool) -> Set<Int> {
        var result = Set<Int>()
        var index = start
        while index + 1 < words.count {
            if isSecret(words[index]) { result.insert(index + 1) }
            index += 2
        }
        return result
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
