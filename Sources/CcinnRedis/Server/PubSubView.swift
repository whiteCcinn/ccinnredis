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

    unowned let workspace: WorkspaceModel
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
    private var counter = 0
    static let maxMessages = 5000

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        refreshChannels()
    }

    var unavailableReason: String? { workspace.capabilities.supports(.pubsub) ? nil : workspace.capabilities[.pubsub].reason }

    func subscribe(pattern: Bool) {
        let names = subscribeText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        subscribeText = ""
        let command = RedisCommand(pattern ? "PSUBSCRIBE" : "SUBSCRIBE", names.map { RedisArgument($0) })
        Task {
            do {
                if let session {
                    try await session.send([command])
                } else {
                    let session = try await StreamingSession.open(client: workspace.client, initial: [command])
                    self.session = session
                    listen(session)
                }
                if pattern { patterns += names.filter { !patterns.contains($0) } } else { subscriptions += names.filter { !subscriptions.contains($0) } }
                error = nil
            } catch {
                self.error = describe(error)
            }
        }
    }

    func unsubscribe(_ name: String, pattern: Bool) {
        Task {
            try? await session?.send([RedisCommand(pattern ? "PUNSUBSCRIBE" : "UNSUBSCRIBE", [RedisArgument(name)])])
            if pattern { patterns.removeAll { $0 == name } } else { subscriptions.removeAll { $0 == name } }
            if subscriptions.isEmpty, patterns.isEmpty { close() }
        }
    }

    private func listen(_ session: StreamingSession) {
        listenTask = Task { [weak self] in
            for await frame in session.frames {
                guard let self else { return }
                if case let .message(channel, payload, pattern) = PubSubEvent.parse(frame) {
                    self.counter += 1
                    self.messages.append(Message(id: self.counter, time: Date(), channel: RedisKey(bytes: channel).display,
                                                 pattern: pattern.map { RedisKey(bytes: $0).display }, payload: payload))
                    if self.messages.count > Self.maxMessages { self.messages.removeFirst(self.messages.count - Self.maxMessages) }
                    self.revision &+= 1
                }
            }
            if let reason = await session.closeReason { self?.error = "Subscription connection closed: \(reason)" }
        }
    }

    func publish() {
        let channel = publishChannel.trimmingCharacters(in: .whitespaces)
        guard !channel.isEmpty else { return }
        let message = Array(publishMessage.utf8)
        Task {
            do {
                let receivers = try await workspace.client.publish(channel: channel, message: message)
                workspace.showToast("Published to \(channel) · \(receivers) receiver\(receivers == 1 ? "" : "s")")
                refreshChannels()
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    func refreshChannels() {
        guard workspace.capabilities.supports(.pubsubIntrospection) else { return }
        Task {
            channels = (try? await workspace.client.pubsubChannels()) ?? []
        }
    }

    func clearMessages() {
        messages.removeAll()
        revision &+= 1
    }

    func close() {
        listenTask?.cancel()
        let session = session
        self.session = nil
        subscriptions.removeAll()
        patterns.removeAll()
        Task { await session?.close() }
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
