import AppKit
import CcinnRedisKit
import Foundation
import Observation
import RedisKit
import RESPWire

struct ConsoleEntry: Identifiable {
    let id = UUID()
    let command: String
    var output: NSAttributedString
    var isError: Bool
    var duration: Duration?
    var target: String?
    var isLive = false
}

/// One console tab (design D12): its own connection (so SELECT/MULTI are the user's), redis-cli style
/// input and output, completion, history, streaming for SUBSCRIBE/MONITOR, cluster routing.
@MainActor
@Observable
final class ConsoleModel {
    let title: String
    unowned let workspace: WorkspaceModel

    private(set) var entries: [ConsoleEntry] = []
    var input = ""
    private(set) var isRunning = false
    private(set) var isStreaming = false
    private(set) var database: Int
    /// Cluster only: `nil` routes each command by its key.
    var targetNode: Endpoint? {
        didSet { if oldValue != targetNode { dropConnection() } }
    }
    var rawOutput = false
    private(set) var revision = 0

    private(set) var history: ConsoleHistory
    private(set) var catalog: CommandCatalog
    private var connection: RedisConnection?
    private var connectionEndpoint: Endpoint?
    private var runTask: Task<Void, Never>?
    private var streaming: StreamingSession?
    private var streamTask: Task<Void, Never>?

    static let maxEntries = 400
    static let maxLiveLines = 2000

    init(workspace: WorkspaceModel, title: String) {
        self.workspace = workspace
        self.title = title
        database = workspace.client.database
        history = ConsoleHistory.load(directory: AppServices.shared.historyDirectory, profileID: workspace.profile.id)
        catalog = CommandCatalog(serverVersion: workspace.serverInfo.version, family: workspace.serverInfo.family,
                                 extra: workspace.client.serverOnlyCommands)
    }

    var client: RedisClient { workspace.client }
    var isCluster: Bool { client.deployment.isCluster }

    var prompt: String {
        if isCluster { return (targetNode?.description ?? "cluster") + ">" }
        return client.primaryEndpoint.description + (database == 0 ? "" : "[\(database)]") + ">"
    }

    func start(initialCommands: String?) {
        append(system: "Connected to \(client.serverInfo.displayName) · \(client.deployment.displayName) · RESP\(client.protocolVersion)"
            + (client.isReadOnly ? " · read-only" : "") + "\nType a command, ↑/↓ for history, Tab or ⌃Space to complete, “help <command>” for syntax.")
        if let initialCommands {
            let commands = initialCommands.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Task {
                for command in commands { await execute(line: command) }
            }
        }
    }

    func close() {
        runTask?.cancel()
        stopStreaming()
        dropConnection()
        try? history.save(directory: AppServices.shared.historyDirectory, profileID: workspace.profile.id)
    }

    // MARK: Input

    func submit() {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isRunning else { return }
        input = ""
        history.record(line)
        runTask = Task { await execute(line: line) }
    }

    func historyPrevious() -> String? { history.previous(current: input) }
    func historyNext() -> String? { history.next() }

    func cancelRunning() {
        runTask?.cancel()
        if isStreaming { stopStreaming() }
    }

    func clear() {
        entries.removeAll()
        revision &+= 1
    }

    func complete(text: String, cursor: Int) -> CompletionResult {
        let browser = workspace.browser
        return CompletionEngine.complete(line: text, cursor: cursor, catalog: catalog) { prefix, limit in
            browser.keys(withPrefix: prefix, limit: limit)
        }
    }

    func hint(for text: String) -> CommandDoc? {
        let partial = CLITokenizer.partial(text)
        guard let first = partial.completed.first.map({ String(decoding: $0, as: UTF8.self) }) ?? (partial.current.isEmpty ? nil : partial.current) else {
            return nil
        }
        if partial.completed.count >= 1, CommandSpecs.containerCommands.contains(first.uppercased()) {
            let second = partial.completed.count > 1 ? String(decoding: partial.completed[1], as: UTF8.self) : partial.current
            if let doc = catalog.documentation(for: "\(first) \(second)") { return doc }
        }
        return catalog.documentation(for: first)
    }

    // MARK: Execution

    private func execute(line: String) async {
        let arguments: [[UInt8]]
        do {
            arguments = try CLITokenizer.tokenize(line)
        } catch {
            append(command: line, error: describe(error))
            return
        }
        guard !arguments.isEmpty else { return }
        let command = RedisCommand(rawArguments: arguments)

        switch command.name {
        case "CLEAR":
            clear()
            return
        case "HELP":
            let topic = arguments.dropFirst().map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
            if let doc = topic.isEmpty ? nil : catalog.documentation(for: topic) {
                append(command: line, output: plain("\(doc.syntax)\n\(doc.summary)\nGroup: \(doc.group) · since \(doc.since.shortDescription)"))
            } else {
                append(command: line, output: plain("help <command> shows syntax. Commands available on this server: \(catalog.commandNames.count)."))
            }
            return
        case "QUIT", "EXIT":
            append(command: line, output: plain("Close the tab to end the console session."))
            return
        default:
            break
        }

        do {
            try client.enforceReadOnly([command])
        } catch {
            append(command: line, error: describe(error))
            return
        }
        if isCluster, targetNode == nil, ["MULTI", "WATCH", "SELECT"].contains(command.name) {
            append(command: line, error: "\(command.name) needs a single connection. Pick a node in the console toolbar first.")
            return
        }

        switch CommandSafety.assess(command, database: database, connectionName: workspace.connectionName) {
        case .allowed:
            await run(command, line: line)
        case let .confirmation(reason):
            await confirmThenRun(command, line: line, title: "Run \(command.qualifiedName)?", message: reason, expected: nil)
        case let .typedConfirmation(expected, reason):
            await confirmThenRun(command, line: line, title: "Run \(command.name)?", message: reason, expected: expected)
        }
    }

    /// Asks for confirmation; the command runs only from the confirmation's action.
    private func confirmThenRun(_ command: RedisCommand, line: String, title: String, message: String, expected: String?) async {
        workspace.confirm(Confirmation(title: title, message: message, confirmTitle: "Run", expectedText: expected) { [weak self] in
            guard let self else { return }
            self.runTask = Task { await self.run(command, line: line) }
        })
    }

    private func run(_ command: RedisCommand, line: String) async {
        if CommandSpecs.spec(for: command)?.flags.contains(.streaming) == true {
            await startStreaming(command, line: line)
            return
        }
        isRunning = true
        defer { isRunning = false }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let reply: RESPValue
            var target: String?
            if isCluster, targetNode == nil {
                reply = try await client.executeAllowingErrors(command)
                if let slotKey = client.spec(for: command)?.keyIndices(in: command.arguments).first.map({ command.arguments[$0] }) {
                    let slot = HashSlot.slot(bytes: slotKey)
                    target = "slot \(slot) → \(client.slotMap.master(forSlot: slot)?.endpoint.description ?? "?")"
                }
            } else {
                let connection = try await activeConnection()
                let blocking = CommandSpecs.spec(for: command)?.flags.contains(.blocking) == true
                reply = try await connection.pipeline([command], timeout: blocking ? nil : client.configuration.commandTimeout)[0]
                if command.name == "SELECT", !reply.isError, let index = command.argument(1).flatMap({ Int(String(decoding: $0, as: UTF8.self)) }) {
                    database = index
                }
                target = isCluster ? targetNode?.description : nil
            }
            append(command: line, output: Self.render(reply, raw: rawOutput), isError: reply.isError, duration: clock.now - start, target: target)
            if !reply.isError, client.spec(for: command)?.isWrite == true { workspace.browser.refreshKeyspace() }
        } catch {
            if (error as? RedisError)?.breaksConnection ?? true { dropConnection() }
            append(command: line, error: describe(error), duration: clock.now - start)
        }
    }

    private func activeConnection() async throws -> RedisConnection {
        if let connection, await !connection.isBroken { return connection }
        let route: Route = targetNode.map { .node($0) } ?? .auto
        var (fresh, _) = try await client.dedicatedConnection(route: route)
        if database != client.database, !isCluster {
            // Restore the database chosen with SELECT in this console after a reconnect.
            let reply = try await fresh.pipeline([RedisCommand("SELECT", [.int(database)])])[0]
            if reply.isError {
                await fresh.close()
                (fresh, _) = try await client.dedicatedConnection(route: route)
                database = client.database
            }
        }
        connection = fresh
        connectionEndpoint = fresh.endpoint
        return fresh
    }

    private func dropConnection() {
        let old = connection
        connection = nil
        Task { await old?.close() }
    }

    // MARK: Streaming

    private func startStreaming(_ command: RedisCommand, line: String) async {
        stopStreaming()
        do {
            let route: Route = targetNode.map { .node($0) } ?? .auto
            let session = try await StreamingSession.open(client: client, route: route, initial: [command])
            streaming = session
            isStreaming = true
            var entry = ConsoleEntry(command: line, output: plain(command.name == "MONITOR" ? "Monitoring… press Stop to end." : "Listening… press Stop to end."),
                                     isError: false, duration: nil, target: session.endpoint.description, isLive: true)
            entries.append(entry)
            trimEntries()
            let entryID = entry.id
            let frames = session.frames
            streamTask = Task { [weak self] in
                var lines: [String] = []
                for await frame in frames {
                    guard let self else { return }
                    let text: String
                    switch PubSubEvent.parse(frame) {
                    case let .message(channel, payload, pattern):
                        let time = Date().formatted(date: .omitted, time: .standard)
                        text = "\(time)  \(pattern.map { "[\(String(decoding: $0, as: UTF8.self))] " } ?? "")\(String(decoding: channel, as: UTF8.self)): \(Format.bytesText(payload, limit: 2000))"
                    case let .subscribed(kind, channel, count):
                        text = "\(kind) \(channel) (\(count) active)"
                    default:
                        text = frame.string ?? ReplyFormatter.format(frame)
                    }
                    lines.append(text)
                    if lines.count > Self.maxLiveLines { lines.removeFirst(lines.count - Self.maxLiveLines) }
                    if let index = self.entries.firstIndex(where: { $0.id == entryID }) {
                        self.entries[index].output = self.plain(lines.joined(separator: "\n"))
                        self.revision &+= 1
                    }
                }
                self?.isStreaming = false
            }
            entry.isLive = true
        } catch {
            append(command: line, error: describe(error))
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        let session = streaming
        streaming = nil
        isStreaming = false
        for index in entries.indices where entries[index].isLive { entries[index].isLive = false }
        Task { await session?.close() }
    }

    // MARK: Output

    private func append(command: String, output: NSAttributedString, isError: Bool = false, duration: Duration? = nil, target: String? = nil) {
        entries.append(ConsoleEntry(command: command, output: output, isError: isError, duration: duration, target: target))
        trimEntries()
    }

    private func append(command: String, error: String, duration: Duration? = nil) {
        append(command: command, output: NSAttributedString(string: "(error) " + error, attributes: [
            .font: Self.font, .foregroundColor: NSColor.consoleError,
        ]), isError: true, duration: duration)
    }

    private func append(system text: String) {
        entries.append(ConsoleEntry(command: "", output: NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]),
                                    isError: false))
        revision &+= 1
    }

    private func trimEntries() {
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        revision &+= 1
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// redis-cli formatting with light syntax colouring per line.
    static func render(_ value: RESPValue, raw: Bool) -> NSAttributedString {
        let text = ReplyFormatter.format(value, style: raw ? .raw : .readable, limits: ReplyFormatter.Limits(maxElements: 5000, maxStringBytes: 32 * 1024))
        let result = NSMutableAttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(colorize(String(line)))
        }
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func colorize(_ line: String) -> NSAttributedString {
        // Split the "  1) 2# " numbering from the value.
        var prefixEnd = line.startIndex
        var scan = line.startIndex
        while scan < line.endIndex {
            let character = line[scan]
            if character == " " || character.isNumber {
                scan = line.index(after: scan)
                continue
            }
            if character == ")" || character == "~" || character == "#" {
                let next = line.index(after: scan)
                if next < line.endIndex, line[next] == " " {
                    scan = line.index(after: next)
                    prefixEnd = scan
                    continue
                }
            }
            break
        }
        let prefix = String(line[..<prefixEnd])
        let value = String(line[prefixEnd...])
        let color: NSColor
        if value.hasPrefix("(error)") {
            color = .consoleError
        } else if value.hasPrefix("(integer)") || value.hasPrefix("(double)") || value.hasPrefix("(big number)") {
            color = .consoleNumber
        } else if value.hasPrefix("(nil)") || value.hasPrefix("(empty") {
            color = .consoleNil
        } else if value.hasPrefix("(true)") || value.hasPrefix("(false)") {
            color = .consoleMeta
        } else if value.hasPrefix("\"") {
            color = .consoleString
        } else {
            color = .labelColor
        }
        let result = NSMutableAttributedString(string: prefix, attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
        if let arrow = value.range(of: "\" => ") ?? value.range(of: ") => ") {
            let key = String(value[..<arrow.lowerBound]) + String(value[arrow.lowerBound..<value.index(after: arrow.lowerBound)])
            let rest = String(value[value.index(after: arrow.lowerBound)...])
            result.append(NSAttributedString(string: key, attributes: [.foregroundColor: NSColor.consoleMeta]))
            result.append(colorize(rest.replacingOccurrences(of: " => ", with: "", options: .anchored)).prefixed(" => "))
        } else {
            result.append(NSAttributedString(string: value, attributes: [.foregroundColor: color]))
        }
        return result
    }
}

private extension NSAttributedString {
    func prefixed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
        result.append(self)
        return result
    }
}
