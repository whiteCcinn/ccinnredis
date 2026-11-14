import Foundation
import RedisKit

public struct CommandDoc: Sendable, Hashable {
    public var name: String
    public var syntax: String
    public var summary: String
    public var group: String
    public var since: ServerVersion
}

/// Commands available on the connected server with their documentation (static catalogue merged with
/// what the server reports via `COMMAND`), filtered by version.
public struct CommandCatalog: Sendable {
    public let serverVersion: ServerVersion?
    public let family: ServerFamily
    private let specs: [String: CommandSpec]
    public let commandNames: [String]
    private let subcommandsByContainer: [String: [String]]

    public init(serverVersion: ServerVersion?, family: ServerFamily, extra: [CommandSpec]) {
        self.serverVersion = serverVersion
        self.family = family
        var specs = CommandSpecs.table
        for spec in extra where specs[spec.name] == nil { specs[spec.name] = spec }
        let available = specs.filter { Self.isAvailable($0.value, version: serverVersion, family: family) }
        self.specs = available
        var names = Set<String>()
        var subcommands: [String: Set<String>] = [:]
        for name in available.keys {
            let parts = name.split(separator: " ", maxSplits: 1)
            names.insert(String(parts[0]))
            if parts.count == 2 { subcommands[String(parts[0]), default: []].insert(String(parts[1])) }
        }
        commandNames = names.sorted()
        subcommandsByContainer = subcommands.mapValues { $0.sorted() }
    }

    static func isAvailable(_ spec: CommandSpec, version: ServerVersion?, family: ServerFamily) -> Bool {
        guard let version else { return true }
        if family == .valkey {
            // Valkey forked from Redis 7.2.4; later Redis-only commands are not there.
            return spec.since <= ServerVersion(7, 2, 4) || spec.group == "module"
        }
        return spec.since <= version || spec.group == "module" || spec.group == "json" || spec.group == "search"
            || spec.group == "bloom" || spec.group == "timeseries"
    }

    public func subcommands(of container: String) -> [String] { subcommandsByContainer[container.uppercased()] ?? [] }

    public func spec(for name: String) -> CommandSpec? { specs[name.uppercased()] }

    public func documentation(for name: String) -> CommandDoc? {
        let upper = name.uppercased().split(separator: " ").joined(separator: " ")
        let spec = specs[upper] ?? CommandSpecs.table[upper]
        guard spec != nil || CommandDocs.table[upper] != nil else { return nil }
        let doc = CommandDocs.table[upper]
        return CommandDoc(name: upper, syntax: doc?.syntax ?? upper.lowercased(), summary: doc?.summary ?? spec.map { "\($0.group.capitalized) command" } ?? "",
                          group: spec?.group ?? "", since: spec?.since ?? ServerVersion(1))
    }

    /// Options worth suggesting after the command name.
    public func keywords(for name: String) -> [String] { CommandDocs.keywords[name.uppercased()] ?? [] }
}

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case command, subcommand, key, keyword }
    public var label: String
    public var insertText: String
    public var detail: String?
    public var kind: Kind
    public var id: String { "\(kind)-\(label)" }
}

public struct CompletionResult: Sendable, Equatable {
    public var items: [CompletionItem]
    /// UTF-16 range of the text the selected item replaces.
    public var replacementRange: Range<Int>
    public var prefix: String
    public static let empty = CompletionResult(items: [], replacementRange: 0..<0, prefix: "")
}

/// Console completion: command names, subcommands, options and key names at key positions.
public enum CompletionEngine {
    public typealias KeyProvider = (_ prefix: String, _ limit: Int) -> [RedisKey]

    public static func complete(line: String, cursor: Int, catalog: CommandCatalog, keys: KeyProvider) -> CompletionResult {
        let utf16 = Array(line.utf16)
        let clamped = min(max(0, cursor), utf16.count)
        let before = String(decoding: utf16[0..<clamped], as: UTF16.self)
        let partial = CLITokenizer.partial(before)
        let range = partial.currentStart..<clamped
        let prefix = partial.current
        let upperPrefix = prefix.uppercased()

        if partial.completed.isEmpty {
            guard !partial.isQuoted else { return .empty }
            let items = catalog.commandNames.filter { $0.hasPrefix(upperPrefix) }.prefix(60).map { name in
                CompletionItem(label: name, insertText: name, detail: catalog.documentation(for: name)?.summary, kind: .command)
            }
            return CompletionResult(items: Array(items), replacementRange: range, prefix: prefix)
        }

        let name = String(decoding: partial.completed[0], as: UTF8.self).uppercased()
        if partial.completed.count == 1, CommandSpecs.containerCommands.contains(name), !partial.isQuoted {
            let items = catalog.subcommands(of: name).filter { $0.hasPrefix(upperPrefix) }.map { sub in
                CompletionItem(label: sub, insertText: sub, detail: catalog.documentation(for: "\(name) \(sub)")?.summary, kind: .subcommand)
            }
            return CompletionResult(items: items, replacementRange: range, prefix: prefix)
        }

        // Key positions per the command's key rule.
        let arguments = partial.completed + [Array(prefix.utf8)]
        let command = RedisCommand(rawArguments: arguments)
        let spec = CommandSpecs.spec(for: command) ?? catalog.spec(for: command.qualifiedName) ?? catalog.spec(for: name)
        var items: [CompletionItem] = []
        if let spec, spec.keyIndices(in: arguments).contains(arguments.count - 1) {
            items = keys(prefix, 50).map { key in
                CompletionItem(label: key.display, insertText: CLITokenizer.quote(key.bytes), detail: nil, kind: .key)
            }
        }
        if !upperPrefix.isEmpty || items.isEmpty {
            let keywords = catalog.keywords(for: name).filter { $0.hasPrefix(upperPrefix) && !upperPrefix.isEmpty }
            items += keywords.map { CompletionItem(label: $0, insertText: $0, detail: "option", kind: .keyword) }
        }
        return CompletionResult(items: items, replacementRange: range, prefix: prefix)
    }
}
