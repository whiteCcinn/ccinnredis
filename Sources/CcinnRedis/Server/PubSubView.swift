import CcinnRedisKit
import RedisKit
import SwiftUI

@MainActor
@Observable
final class PubSubModel {
    struct Message: Identifiable {
        let id: Int
        let time: Date
        let channel: String
        let pattern: String?
        let payload: [UInt8]
    }

    let workspace: WorkspaceModel
    var subscribeText = ""
    var publishChannel = ""
    var publishMessage = ""
    private(set) var subscriptions: [String] = []
    private(set) var patterns: [String] = []
    private(set) var messages: [Message] = []
    private(set) var channels: [(channel: String, subscribers: Int64)] = []
    private(set) var error: String?
    private(set) var revision = 0
    private var session: StreamingSession?
    private var listenTask: Task<Void, Never>?
    /// Subscribe/unsubscribe/close run one after another, so a double click cannot open two sessions.
    private var commandChain: Task<Void, Never>?
    /// Bumped by close(): work started for an older session discards what it opened.
    private var sessionGeneration = 0
    private var counter = 0
    @ObservationIgnored private var pending: [Message] = []
    @ObservationIgnored private var coalescer: UpdateCoalescer?
    static let maxMessages = 5000

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        coalescer = UpdateCoalescer { [weak self] in self?.flushPending() }
        refreshChannels()
    }

    var unavailableReason: String? { workspace.capabilities.supports(.pubsub) ? nil : workspace.capabilities[.pubsub].reason }

    private func enqueue(_ operation: @escaping @MainActor (PubSubModel) async -> Void) {
        let previous = commandChain
        commandChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
    }

    func subscribe(pattern: Bool) {
        let names = subscribeText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        subscribeText = ""
        let command = RedisCommand(pattern ? "PSUBSCRIBE" : "SUBSCRIBE", names.map { RedisArgument($0) })
        let client = workspace.client
        enqueue { model in
            let generation = model.sessionGeneration
            do {
                if let session = model.session {
                    try await session.send([command])
                } else {
                    let session = try await StreamingSession.open(client: client, initial: [command])
                    guard model.sessionGeneration == generation, model.session == nil else {
                        await session.close() // closed (or replaced) while connecting
                        return
                    }
                    model.session = session
                    model.listen(session)
                }
                if pattern {
                    model.patterns += names.filter { !model.patterns.contains($0) }
                } else {
                    model.subscriptions += names.filter { !model.subscriptions.contains($0) }
                }
                model.error = nil
            } catch {
                model.error = describe(error)
            }
        }
    }

    func unsubscribe(_ name: String, pattern: Bool) {
        enqueue { model in
            try? await model.session?.send([RedisCommand(pattern ? "PUNSUBSCRIBE" : "UNSUBSCRIBE", [RedisArgument(name)])])
            if pattern { model.patterns.removeAll { $0 == name } } else { model.subscriptions.removeAll { $0 == name } }
            if model.subscriptions.isEmpty, model.patterns.isEmpty { model.closeSession() }
        }
    }

    private func listen(_ session: StreamingSession) {
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            for await frame in session.frames {
                guard let self else { return }
                if case let .message(channel, payload, pattern) = PubSubEvent.parse(frame) {
                    self.counter &+= 1
                    self.pending.append(Message(id: self.counter, time: Date(), channel: RedisKey(bytes: channel).display,
                                                pattern: pattern.map { RedisKey(bytes: $0).display }, payload: payload))
                    if self.pending.count > Self.maxMessages { self.pending.removeFirst(self.pending.count - Self.maxMessages) }
                    self.coalescer?.signal()
                }
            }
            self?.coalescer?.flushNow()
            if let reason = await session.closeReason { self?.error = "Subscription connection closed: \(reason)" }
        }
    }

    /// Moves buffered messages into the table (≈10 times per second at most).
    private func flushPending() {
        guard !pending.isEmpty else { return }
        messages.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
        revision &+= 1
    }

    func publish() {
        let channel = publishChannel.trimmingCharacters(in: .whitespaces)
        guard !channel.isEmpty else { return }
        let message = Array(publishMessage.utf8)
        let client = workspace.client
        Task { [weak self] in
            do {
                let receivers = try await client.publish(channel: channel, message: message)
                self?.workspace.showToast("Published to \(channel) · \(receivers) receiver\(receivers == 1 ? "" : "s")")
                self?.refreshChannels()
            } catch {
                self?.workspace.showToast(describe(error), isError: true)
            }
        }
    }

    func refreshChannels() {
        guard workspace.capabilities.supports(.pubsubIntrospection) else { return }
        let client = workspace.client
        Task { [weak self] in
            let channels = (try? await client.pubsubChannels()) ?? []
            self?.channels = channels
        }
    }

    func clearMessages() {
        pending.removeAll()
        messages.removeAll()
        revision &+= 1
    }

    private func closeSession() {
        sessionGeneration &+= 1
        listenTask?.cancel()
        listenTask = nil
        coalescer?.cancel()
        let session = session
        self.session = nil
        subscriptions.removeAll()
        patterns.removeAll()
        Task { await session?.close() }
    }

    func close() {
        commandChain?.cancel()
        commandChain = nil
        closeSession()
    }
}

struct PubSubView: View {
    @Bindable var model: PubSubModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "Pub/Sub is unavailable", reason: reason, systemImage: "dot.radiowaves.left.and.right")
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    subscribeBar
                    if let error = model.error { ErrorBanner(message: error).padding(.horizontal, 12) }
                    Divider()
                    DataTable(columns: [
                        TableColumnSpec(id: "time", title: "Time", width: 90),
                        TableColumnSpec(id: "channel", title: "Channel", width: 160, monospaced: true),
                        TableColumnSpec(id: "pattern", title: "Pattern", width: 100, monospaced: true),
                        TableColumnSpec(id: "payload", title: "Message", width: 420, monospaced: true, flexible: true),
                    ], rowCount: model.messages.count, revision: model.revision, cell: { row, column in
                        let message = model.messages[model.messages.count - 1 - row]
                        switch column {
                        case 0: return message.time.formatted(date: .omitted, time: .standard)
                        case 1: return message.channel
                        case 2: return message.pattern ?? ""
                        default: return Format.bytesText(message.payload, limit: 1000)
                        }
                    }, cellColor: { _, column in column == 1 ? NSColor.appAccent : nil })
                    .overlay {
                        if model.messages.isEmpty {
                            ContentUnavailableView("No messages yet", systemImage: "dot.radiowaves.left.and.right",
                                                   description: Text(model.subscriptions.isEmpty && model.patterns.isEmpty ? "Subscribe to a channel or pattern." : "Waiting for messages…"))
                        }
                    }
                    Divider()
                    publishBar
                }
                .frame(minWidth: 480)
                channelList.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            }
        }
    }

    private var subscribeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Channels or patterns (news.*, orders)", text: $model.subscribeText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.subscribe(pattern: model.subscribeText.contains("*") || model.subscribeText.contains("?")) }
                Button("Subscribe") { model.subscribe(pattern: false) }
                Button("Pattern") { model.subscribe(pattern: true) }
                Button { model.clearMessages() } label: { Image(systemName: "trash") }.help("Clear messages")
            }
            if !model.subscriptions.isEmpty || !model.patterns.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.subscriptions, id: \.self) { chip($0, pattern: false) }
                        ForEach(model.patterns, id: \.self) { chip($0, pattern: true) }
                    }
                }
            }
        }
        .padding(12)
    }

    private func chip(_ name: String, pattern: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: pattern ? "asterisk" : "number").imageScale(.small)
            Text(name).font(.caption.monospaced())
            Button { model.unsubscribe(name, pattern: pattern) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.12), in: Capsule())
        .foregroundStyle(Theme.accent)
    }

    private var publishBar: some View {
        HStack {
            TextField("Channel", text: $model.publishChannel).textFieldStyle(.roundedBorder).frame(width: 180)
            TextField("Message", text: $model.publishMessage).textFieldStyle(.roundedBorder).onSubmit { model.publish() }
            Button("Publish") { model.publish() }
                .buttonStyle(.borderedProminent)
                .disabled(model.publishChannel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Active channels").font(.headline)
                Spacer()
                Button { model.refreshChannels() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            if !model.workspace.capabilities.supports(.pubsubIntrospection) {
                NoticeBanner(message: model.workspace.capabilities[.pubsubIntrospection].reason ?? "PUBSUB is unavailable").padding(10)
            }
            List(model.channels, id: \.channel) { entry in
                HStack {
                    Text(entry.channel).font(.callout.monospaced()).lineLimit(1)
                    Spacer()
                    Text("\(entry.subscribers)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.publishChannel = entry.channel }
            }
            .listStyle(.plain)
        }
    }
}
