import CcinnRedisKit
import Foundation
import Observation
import RedisKit

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// A destructive action waiting for the user's confirmation (optionally typed).
struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var confirmTitle = "Confirm"
    /// When set, the user must type exactly this text (database index or connection name).
    var expectedText: String?
    var isDestructive = true
    let action: @MainActor () -> Void
}

/// One tab in the workspace.
struct WorkspaceTab: Identifiable, Equatable {
    enum Kind {
        case key(KeyEditorModel)
        case console(ConsoleModel)
        case dashboard(DashboardModel)
        case info(ServerInfoModel)
        case slowlog(SlowlogModel)
        case clients(ClientsModel)
        case config(ConfigModel)
        case cluster(ClusterModel)
        case pubsub(PubSubModel)
        case analysis(AnalysisModel)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool { lhs.id == rhs.id }

    @MainActor var title: String {
        switch kind {
        case let .key(model): model.key.display
        case let .console(model): model.title
        case .dashboard: WorkspaceModel.Tool.dashboard.title
        case .info: WorkspaceModel.Tool.info.title
        case .slowlog: WorkspaceModel.Tool.slowlog.title
        case .clients: WorkspaceModel.Tool.clients.title
        case .config: WorkspaceModel.Tool.config.title
        case .cluster: WorkspaceModel.Tool.cluster.title
        case .pubsub: WorkspaceModel.Tool.pubsub.title
        case .analysis: WorkspaceModel.Tool.analysis.title
        }
    }

    @MainActor var icon: String {
        switch kind {
        case let .key(model): Theme.icon(for: model.type)
        case .console: "terminal"
        case .dashboard: WorkspaceModel.Tool.dashboard.icon
        case .info: WorkspaceModel.Tool.info.icon
        case .slowlog: WorkspaceModel.Tool.slowlog.icon
        case .clients: WorkspaceModel.Tool.clients.icon
        case .config: WorkspaceModel.Tool.config.icon
        case .cluster: WorkspaceModel.Tool.cluster.icon
        case .pubsub: WorkspaceModel.Tool.pubsub.icon
        case .analysis: WorkspaceModel.Tool.analysis.icon
        }
    }

    var tool: WorkspaceModel.Tool? {
        switch kind {
        case .dashboard: .dashboard
        case .info: .info
        case .slowlog: .slowlog
        case .clients: .clients
        case .config: .config
        case .cluster: .cluster
        case .pubsub: .pubsub
        case .analysis: .analysis
        case .key, .console: nil
        }
    }
}

/// Everything a connected window shows: key browser, open tabs, capabilities and feedback.
@MainActor
@Observable
final class WorkspaceModel {
    enum Tool: String, CaseIterable, Identifiable {
        case dashboard, info, slowlog, clients, config, cluster, pubsub, analysis
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: "Dashboard"
            case .info: "Server Info"
            case .slowlog: "Slow Log"
            case .clients: "Clients"
            case .config: "Configuration"
            case .cluster: "Cluster"
            case .pubsub: "Pub/Sub"
            case .analysis: "Memory Analysis"
            }
        }

        var icon: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .info: "info.circle"
            case .slowlog: "tortoise"
            case .clients: "person.2"
            case .config: "slider.horizontal.3"
            case .cluster: "circle.hexagongrid"
            case .pubsub: "dot.radiowaves.left.and.right"
            case .analysis: "chart.pie"
            }
        }
    }

    let profile: ConnectionProfile
    let client: RedisClient
    let browser: KeyBrowserModel

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var toast: Toast?
    var confirmation: Confirmation?
    var showConnectionInfo = false
    /// Bumped when capabilities change so views re-read them.
    private(set) var capabilityRevision = 0
    private(set) var primaryEndpoint: Endpoint

    private var toastTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var consoleCounter = 0

    init(profile: ConnectionProfile, client: RedisClient) {
        self.profile = profile
        self.client = client
        primaryEndpoint = client.primaryEndpoint
        browser = KeyBrowserModel(client: client, delimiter: profile.delimiter)
        browser.workspace = self
    }

    var capabilities: Capabilities {
        _ = capabilityRevision
        return client.capabilities
    }

    var serverInfo: ServerInfo { client.serverInfo }
    var deployment: Deployment { client.deployment }
    var isReadOnly: Bool { client.isReadOnly }
    var connectionName: String { profile.displayName }

    var versionLabel: String {
        if client.serverInfo.versionString.isEmpty, client.deployment.isProxy { return "Backend version hidden" }
        return client.serverInfo.displayName
    }

    // MARK: Lifecycle

    func start() {
        browser.start()
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .failover(from, to):
                    self.primaryEndpoint = to
                    self.showToast("Sentinel failover: now connected to \(to) (was \(from))")
                case .topologyRefreshed:
                    self.capabilityRevision += 1
                case .capabilityChanged:
                    self.capabilityRevision += 1
                }
            }
        }
    }

    func shutdown() {
        eventTask?.cancel()
        browser.stop()
        for tab in tabs { closeResources(of: tab) }
        tabs.removeAll()
        let client = client
        Task.detached { await client.close() }
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var analysisModel: AnalysisModel? {
        for tab in tabs { if case let .analysis(model) = tab.kind { return model } }
        return nil
    }

    func openKey(_ key: RedisKey) {
        if let existing = tabs.first(where: { if case let .key(model) = $0.kind { model.key == key } else { false } }) {
            selectedTabID = existing.id
            return
        }
        // Replace an untouched key tab instead of piling up tabs while browsing.
        let model = KeyEditorModel(key: key, workspace: self)
        let tab = WorkspaceTab(kind: .key(model))
        if let selected = selectedTab, case let .key(current) = selected.kind, !current.isPinned,
           let index = tabs.firstIndex(of: selected) {
            closeResources(of: selected)
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        browser.noteRecent(key)
        model.load()
    }

    func openConsole(initial: String? = nil) {
        consoleCounter += 1
        let model = ConsoleModel(workspace: self, title: consoleCounter == 1 ? "Console" : "Console \(consoleCounter)")
        let tab = WorkspaceTab(kind: .console(model))
        tabs.append(tab)
        selectedTabID = tab.id
        model.start(initialCommands: initial)
    }

    func open(_ tool: Tool) {
        if let existing = tabs.first(where: { $0.tool == tool }) {
            selectedTabID = existing.id
            return
        }
        let kind: WorkspaceTab.Kind
        switch tool {
        case .dashboard: kind = .dashboard(DashboardModel(workspace: self))
        case .info: kind = .info(ServerInfoModel(workspace: self))
        case .slowlog: kind = .slowlog(SlowlogModel(workspace: self))
        case .clients: kind = .clients(ClientsModel(workspace: self))
        case .config: kind = .config(ConfigModel(workspace: self))
        case .cluster: kind = .cluster(ClusterModel(workspace: self))
        case .pubsub: kind = .pubsub(PubSubModel(workspace: self))
        case .analysis: kind = .analysis(AnalysisModel(workspace: self))
        }
        let tab = WorkspaceTab(kind: kind)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        closeResources(of: tab)
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    /// Closes editors of keys that no longer exist.
    func keysDeleted(_ keys: [RedisKey]) {
        let doomed = Set(keys)
        for tab in tabs {
            if case let .key(model) = tab.kind, doomed.contains(model.key) { close(tab) }
        }
        browser.remove(keys)
    }

    private func closeResources(of tab: WorkspaceTab) {
        switch tab.kind {
        case let .key(model): model.close()
        case let .console(model): model.close()
        case let .dashboard(model): model.stop()
        case let .pubsub(model): model.close()
        case let .analysis(model): model.cancel()
        case .info, .slowlog, .clients, .config, .cluster: break
        }
    }

    // MARK: Feedback

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func confirm(_ confirmation: Confirmation) {
        self.confirmation = confirmation
    }

    /// Runs an async operation, reporting failures as an error toast.
    func perform(_ success: String? = nil, _ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                if let success { showToast(success) }
            } catch {
                showToast(describe(error), isError: true)
            }
        }
    }
}
