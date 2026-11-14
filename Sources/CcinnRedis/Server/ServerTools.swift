import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Header row shared by the server tools.
private struct ToolHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct FilterField: View {
    @Binding var text: String
    var prompt = "Filter"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 220)
    }
}

// MARK: - INFO

@MainActor
@Observable
final class ServerInfoModel {
    unowned let workspace: WorkspaceModel
    var node: Endpoint? { didSet { if oldValue != node { load() } } }
    var filter = ""
    private(set) var info: InfoSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        load()
    }

    var unavailableReason: String? { workspace.capabilities.supports(.info) ? nil : workspace.capabilities[.info].reason }

    func load() {
        guard unavailableReason == nil else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                info = try await workspace.client.info(section: "all", node: node)
                error = nil
            } catch {
                self.error = describe(error)
            }
        }
    }

    var sections: [InfoSnapshot.Section] {
        guard let info else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return info.sections }
        return info.sections.compactMap { section in
            if section.name.localizedCaseInsensitiveContains(needle) { return section }
            let entries = section.entries.filter { $0.key.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle) }
            return entries.isEmpty ? nil : InfoSnapshot.Section(name: section.name, entries: entries)
        }
    }
}

struct ServerInfoView: View {
    @Bindable var model: ServerInfoModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "INFO is unavailable", reason: reason, systemImage: "info.circle")
        } else {
            VStack(spacing: 0) {
                ToolHeader(title: "Server Info", subtitle: "INFO all") {
                    FilterField(text: $model.filter)
                    if model.workspace.deployment.isCluster { NodePicker(selection: $model.node, endpoints: model.workspace.client.nodeEndpoints(.all)) }
                    Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = model.error { ErrorBanner(message: error) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], spacing: 14) {
                            ForEach(model.sections) { section in
                                Card(title: section.name, systemImage: icon(for: section.name)) {
                                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                        ForEach(Array(section.entries.prefix(200).enumerated()), id: \.offset) { _, entry in
                                            GridRow {
                                                Text(entry.key).foregroundStyle(.secondary).lineLimit(1)
                                                Text(entry.value).font(Theme.monospacedSmall).textSelection(.enabled).lineLimit(2)
                                            }
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func icon(for section: String) -> String {
        switch section.lowercased() {
        case "server": "server.rack"
        case "clients": "person.2"
        case "memory": "memorychip"
        case "persistence": "externaldrive"
        case "stats": "chart.xyaxis.line"
        case "replication": "doc.on.doc"
        case "cpu": "cpu"
        case "cluster": "circle.hexagongrid"
        case "keyspace": "cylinder"
        case "modules": "puzzlepiece.extension"
        default: "list.bullet.rectangle"
        }
    }
}

// MARK: - Slowlog

@MainActor
@Observable
final class SlowlogModel {
    unowned let workspace: WorkspaceModel
    var count = 128 { didSet { load() } }
    private(set) var entries: [SlowlogEntry] = []
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var threshold: String?
    private(set) var revision = 0
    var selection: Set<Int> = []

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        load()
    }

    var unavailableReason: String? { workspace.capabilities.supports(.slowlog) ? nil : workspace.capabilities[.slowlog].reason }

    func load() {
        guard unavailableReason == nil else { return }
        isLoading = true
        let client = workspace.client
        let count = count
        Task {
            defer { isLoading = false }
            var collected: [SlowlogEntry] = []
            var failures: [String] = []
            for endpoint in client.masterEndpoints {
                do { collected += try await client.slowlog(count: count, node: endpoint) } catch { failures.append("\(endpoint): \(describe(error))") }
            }
            entries = collected.sorted { $0.timestamp > $1.timestamp }
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
            if client.capabilities.supports(.config), let value = try? await client.config(pattern: "slowlog-log-slower-than").first?.value {
                threshold = "logs commands slower than \(Format.microseconds(Int64(value) ?? 0))"
            }
            revision &+= 1
        }
    }

    func reset() {
        let client = workspace.client
        workspace.confirm(Confirmation(title: "Reset the slow log?", message: "SLOWLOG RESET clears the slow log on \(client.masterEndpoints.count == 1 ? "the server" : "every master").",
                                       confirmTitle: "Reset") { [weak self] in
            self?.workspace.perform("Slow log cleared") {
                for endpoint in client.masterEndpoints { try await client.slowlogReset(node: endpoint) }
                self?.load()
            }
        })
    }
}

struct SlowlogView: View {
    @Bindable var model: SlowlogModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "Slow log is unavailable", reason: reason, systemImage: "tortoise")
        } else {
            VStack(spacing: 0) {
                ToolHeader(title: "Slow Log", subtitle: model.threshold) {
                    Picker("Entries", selection: $model.count) {
                        ForEach([32, 128, 512], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .frame(width: 130)
                    Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    Button("Reset…", role: .destructive) { model.reset() }.disabled(model.workspace.isReadOnly)
                }
                if let error = model.error { ErrorBanner(message: error).padding(.horizontal, 14).padding(.bottom, 8) }
                Divider()
                DataTable(columns: [
                    TableColumnSpec(id: "id", title: "ID", width: 60, alignment: .right),
                    TableColumnSpec(id: "time", title: "Time", width: 150),
                    TableColumnSpec(id: "duration", title: "Duration", width: 90, alignment: .right),
                    TableColumnSpec(id: "command", title: "Command", width: 420, monospaced: true),
                    TableColumnSpec(id: "client", title: "Client", width: 150, monospaced: true),
                    TableColumnSpec(id: "name", title: "Name", width: 100),
                    TableColumnSpec(id: "node", title: "Node", width: 130, flexible: true),
                ], rowCount: model.entries.count, revision: model.revision, cell: { row, column in
                    let entry = model.entries[row]
                    switch column {
                    case 0: return String(entry.id)
                    case 1: return entry.timestamp.formatted(date: .abbreviated, time: .standard)
                    case 2: return Format.microseconds(entry.durationMicroseconds)
                    case 3: return entry.commandLine
                    case 4: return entry.clientAddress ?? "—"
                    case 5: return entry.clientName ?? ""
                    default: return entry.node?.description ?? ""
                    }
                }, cellColor: { row, column in
                    guard column == 2, model.entries.indices.contains(row) else { return nil }
                    return model.entries[row].durationMicroseconds > 100_000 ? .systemRed : .systemOrange
                }, selection: $model.selection, onDoubleClick: { row in
                    guard model.entries.indices.contains(row) else { return }
                    Pasteboard.copy(model.entries[row].commandLine)
                    model.workspace.showToast("Command copied")
                })
                .overlay {
                    if model.entries.isEmpty, !model.isLoading {
                        ContentUnavailableView("Slow log is empty", systemImage: "tortoise", description: Text("No command exceeded the threshold."))
                    }
                }
            }
        }
    }
}

// MARK: - Clients

@MainActor
@Observable
final class ClientsModel {
    unowned let workspace: WorkspaceModel
    var node: Endpoint? { didSet { if oldValue != node { load() } } }
    var filter = "" { didSet { revision &+= 1 } }
    private(set) var clients: [ClientInfo] = []
    private(set) var error: String?
    private(set) var revision = 0
    var selection: Set<Int> = []

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        load()
    }

    var unavailableReason: String? { workspace.capabilities.supports(.clientList) ? nil : workspace.capabilities[.clientList].reason }

    var visible: [ClientInfo] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return clients }
        return clients.filter { $0.address.contains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
            || $0.lastCommand.localizedCaseInsensitiveContains(needle) || ($0.user ?? "").localizedCaseInsensitiveContains(needle) }
    }

    func load() {
        guard unavailableReason == nil else { return }
        Task {
            do {
                clients = try await workspace.client.clients(node: node)
                error = nil
            } catch {
                self.error = describe(error)
            }
            selection = []
            revision &+= 1
        }
    }

    func killSelected() {
        let targets = selection.sorted().compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        guard !targets.isEmpty else { return }
        workspace.confirm(Confirmation(title: "Kill \(targets.count) client\(targets.count == 1 ? "" : "s")?",
                                       message: targets.prefix(5).map { "\($0.address) \($0.name)" }.joined(separator: "\n") + "\nThe connections are closed by the server.",
                                       confirmTitle: "Kill") { [weak self] in
            guard let self else { return }
            self.workspace.perform("Killed \(targets.count) client\(targets.count == 1 ? "" : "s")") {
                for client in targets { try await self.workspace.client.kill(client) }
                self.load()
            }
        })
    }
}

struct ClientsView: View {
    @Bindable var model: ClientsModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "Client list is unavailable", reason: reason, systemImage: "person.2.slash")
        } else {
            VStack(spacing: 0) {
                ToolHeader(title: "Clients", subtitle: "\(model.clients.count) connected") {
                    FilterField(text: $model.filter, prompt: "Filter address, name, command")
                    if model.workspace.deployment.isCluster { NodePicker(selection: $model.node, endpoints: model.workspace.client.nodeEndpoints(.all)) }
                    Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    Button("Kill…", role: .destructive) { model.killSelected() }
                        .disabled(model.selection.isEmpty || model.workspace.isReadOnly || !model.workspace.capabilities.supports(.clientKill))
                }
                if let error = model.error { ErrorBanner(message: error).padding(.horizontal, 14).padding(.bottom, 8) }
                Divider()
                let rows = model.visible
                DataTable(columns: [
                    TableColumnSpec(id: "id", title: "ID", width: 60, alignment: .right),
                    TableColumnSpec(id: "addr", title: "Address", width: 160, monospaced: true),
                    TableColumnSpec(id: "name", title: "Name", width: 120),
                    TableColumnSpec(id: "user", title: "User", width: 80),
                    TableColumnSpec(id: "db", title: "DB", width: 40, alignment: .right),
                    TableColumnSpec(id: "age", title: "Age", width: 80, alignment: .right),
                    TableColumnSpec(id: "idle", title: "Idle", width: 80, alignment: .right),
                    TableColumnSpec(id: "cmd", title: "Last command", width: 130, monospaced: true),
                    TableColumnSpec(id: "flags", title: "Flags", width: 60),
                    TableColumnSpec(id: "lib", title: "Library", width: 120, flexible: true),
                ], rowCount: rows.count, revision: model.revision, cell: { row, column in
                    let client = rows[row]
                    switch column {
                    case 0: return client.clientID ?? ""
                    case 1: return client.address
                    case 2: return client.name
                    case 3: return client.user ?? ""
                    case 4: return String(client.database)
                    case 5: return Format.duration(seconds: Double(client.ageSeconds))
                    case 6: return Format.duration(seconds: Double(client.idleSeconds))
                    case 7: return client.lastCommand
                    case 8: return client.flags
                    default: return [client.libraryName, client.fields["lib-ver"]].compactMap { $0 }.joined(separator: " ")
                    }
                }, cellColor: { row, column in
                    guard column == 2, rows.indices.contains(row) else { return nil }
                    return rows[row].name.hasPrefix("ccinnredis") ? NSColor.appAccent : nil
                }, selection: $model.selection)
            }
        }
    }
}

// MARK: - Config

@MainActor
@Observable
final class ConfigModel {
    unowned let workspace: WorkspaceModel
    var node: Endpoint? { didSet { if oldValue != node { load() } } }
    var filter = "" { didSet { revision &+= 1 } }
    private(set) var entries: [ConfigEntry] = []
    private(set) var error: String?
    private(set) var revision = 0
    var editing: ConfigEntry?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        load()
    }

    var unavailableReason: String? { workspace.capabilities.supports(.config) ? nil : workspace.capabilities[.config].reason }

    var visible: [ConfigEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.value.localizedCaseInsensitiveContains(needle) }
    }

    func load() {
        guard unavailableReason == nil else { return }
        Task {
            do {
                entries = try await workspace.client.config(node: node)
                error = nil
            } catch let error as RedisError where error.isCommandUnavailable {
                workspace.client.markUnavailable(.config, reason: "CONFIG is disabled on this server: \(error.message)")
            } catch {
                self.error = describe(error)
            }
            revision &+= 1
        }
    }

    func set(_ name: String, value: String) {
        workspace.confirm(Confirmation(title: "Change \(name)?", message: "CONFIG SET \(name) \(value)\nThe change applies immediately and is lost on restart unless CONFIG REWRITE is run.",
                                       confirmTitle: "Apply") { [weak self] in
            guard let self else { return }
            self.workspace.perform("\(name) updated") {
                try await self.workspace.client.setConfig(name, value: value, node: self.node)
                self.load()
            }
        })
    }
}

struct ConfigView: View {
    @Bindable var model: ConfigModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "Configuration is unavailable", reason: reason, systemImage: "slider.horizontal.3")
        } else {
            VStack(spacing: 0) {
                ToolHeader(title: "Configuration", subtitle: "\(model.entries.count) parameters · double-click to edit") {
                    FilterField(text: $model.filter, prompt: "Filter parameters")
                    if model.workspace.deployment.isCluster { NodePicker(selection: $model.node, endpoints: model.workspace.client.nodeEndpoints(.all)) }
                    Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                }
                if let error = model.error { ErrorBanner(message: error).padding(.horizontal, 14).padding(.bottom, 8) }
                Divider()
                let rows = model.visible
                DataTable(columns: [
                    TableColumnSpec(id: "name", title: "Parameter", width: 280, monospaced: true),
                    TableColumnSpec(id: "value", title: "Value", width: 480, monospaced: true, flexible: true),
                ], rowCount: rows.count, revision: model.revision, cell: { row, column in
                    column == 0 ? rows[row].name : rows[row].value
                }, onDoubleClick: { row in
                    guard rows.indices.contains(row), !model.workspace.isReadOnly else { return }
                    model.editing = rows[row]
                })
            }
            .sheet(item: $model.editing) { entry in
                ConfigEditSheet(entry: entry) { model.set(entry.name, value: $0) }
            }
        }
    }
}

private struct ConfigEditSheet: View {
    let entry: ConfigEntry
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.name).font(.headline.monospaced())
            TextField("Value", text: $value).textFieldStyle(.roundedBorder).font(Theme.monospaced)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onSave(value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value == entry.value)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { value = entry.value }
    }
}
