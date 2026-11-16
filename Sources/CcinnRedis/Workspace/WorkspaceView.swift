import CcinnRedisKit
import RedisKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let session: WindowSession
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            KeyBrowserView(browser: workspace.browser, workspace: workspace)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.tabs.isEmpty {
                    TabBarView(workspace: workspace)
                    Divider()
                }
                ZStack {
                    if let tab = workspace.selectedTab {
                        TabContentView(tab: tab)
                            .id(tab.id)
                    } else {
                        WorkspaceHome(workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) { ToastView(toast: workspace.toast) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionBadge(workspace: workspace)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("New Window with This Connection", action: openDuplicateWindow)
                    Button("New Window") { openWindow(id: RootView.windowGroupID) }
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                } primaryAction: {
                    openDuplicateWindow()
                }
                .help("Open this connection in another window (⇧⌘N); each window has its own connection")
                Button { workspace.openConsole() } label: { Label("Console", systemImage: "terminal") }
                    .help("New console (⌘T)")
                Button { workspace.open(.dashboard) } label: { Label("Dashboard", systemImage: WorkspaceModel.Tool.dashboard.icon) }
                    .help("Live server dashboard")
                if workspace.deployment.isCluster {
                    Button { workspace.open(.cluster) } label: { Label("Cluster", systemImage: WorkspaceModel.Tool.cluster.icon) }
                        .help("Cluster topology and slots")
                }
                Menu {
                    ForEach(WorkspaceModel.Tool.allCases) { tool in
                        Button { workspace.open(tool) } label: { Label(tool.title, systemImage: tool.icon) }
                    }
                } label: {
                    Label("Tools", systemImage: "square.grid.2x2")
                }
                .help("Server tools")
                Button { workspace.showConnectionInfo = true } label: { Label("Connection", systemImage: "info.circle") }
                    .help("Connection details and capabilities (⌥⌘I)")
                Button { session.disconnect() } label: { Label("Disconnect", systemImage: "eject") }
                    .help("Disconnect (⇧⌘D)")
            }
        }
        .sheet(item: $workspace.confirmation) { confirmation in
            ConfirmationSheet(confirmation: confirmation) { workspace.confirmation = nil }
        }
        .sheet(isPresented: $workspace.showConnectionInfo) {
            ConnectionInfoView(workspace: workspace)
        }
    }

    private func openDuplicateWindow() {
        if let request = session.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
    }
}

private struct ConnectionBadge: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.color(for: workspace.profile.color).gradient)
                .frame(width: 10, height: 10)
            Text(workspace.profile.displayName).font(.headline).lineLimit(1)
            Badge(text: workspace.versionLabel, color: Theme.accent)
            Badge(text: workspace.deployment.displayName, color: Theme.color(for: workspace.deployment), systemImage: Theme.icon(for: workspace.deployment))
            Badge(text: "RESP\(workspace.client.protocolVersion)", color: workspace.client.protocolVersion == 3 ? .green : .secondary)
            if workspace.isReadOnly { Badge(text: "Read-only", color: .orange, systemImage: "lock") }
            if workspace.client.usesTLS { Badge(text: "TLS", color: .green, systemImage: "lock.shield") }
            if workspace.client.isTunnelled { Badge(text: "SSH", color: .purple, systemImage: "network") }
        }
        .padding(.horizontal, 4)
        .onTapGesture { workspace.showConnectionInfo = true }
    }
}

/// Content of the selected tab.
struct TabContentView: View {
    let tab: WorkspaceTab

    var body: some View {
        switch tab.kind {
        case let .key(model): KeyEditorView(model: model)
        case let .console(model): ConsoleView(model: model)
        case let .dashboard(model): DashboardView(model: model)
        case let .info(model): ServerInfoView(model: model)
        case let .slowlog(model): SlowlogView(model: model)
        case let .clients(model): ClientsView(model: model)
        case let .config(model): ConfigView(model: model)
        case let .cluster(model): ClusterView(model: model)
        case let .pubsub(model): PubSubView(model: model)
        case let .analysis(model): AnalysisView(model: model)
        }
    }
}

struct ToastView: View {
    let toast: Toast?

    var body: some View {
        Group {
            if let toast {
                Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .foregroundStyle(toast.isError ? Color.red : Color.primary)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .frame(maxWidth: 640)
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.35), value: toast)
    }
}

/// Shown when no tab is open: server summary and shortcuts.
private struct WorkspaceHome: View {
    let workspace: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                AppLogo(size: 72)
                VStack(spacing: 6) {
                    Text(workspace.profile.displayName).font(.title.weight(.semibold))
                    Text([workspace.versionLabel, workspace.deployment.displayName, workspace.client.primaryEndpoint.description,
                          workspace.serverInfo.operatingSystem].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                ForEach(workspace.client.notes, id: \.self) { note in
                    NoticeBanner(message: note, systemImage: "lightbulb", color: .accentColor).frame(maxWidth: 560)
                }
                if workspace.deployment.isProxy, !workspace.capabilities.unavailable.isEmpty {
                    NoticeBanner(message: "\(workspace.capabilities.unavailable.count) features are unavailable through this proxy. Open Connection Details to see which and why.",
                                 systemImage: "arrow.triangle.branch", color: .orange)
                        .frame(maxWidth: 560)
                }
                Text("Pick a key in the sidebar to inspect and edit it, or open a tool.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190))], spacing: 12) {
                    shortcut("Console", "terminal") { workspace.openConsole() }
                    ForEach(WorkspaceModel.Tool.allCases) { tool in
                        shortcut(tool.title, tool.icon) { workspace.open(tool) }
                    }
                }
                .frame(maxWidth: 820)
                HStack(spacing: 14) {
                    ForEach([KeyType.string, .hash, .list, .set, .zset, .stream, .json], id: \.self) { type in
                        HStack(spacing: 4) {
                            TypeBadge(type: type)
                            Text(type.displayName)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func shortcut(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Tab strip with close buttons, option-click close and drag reordering.
struct TabBarView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var hovered: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    TabButton(tab: tab, isSelected: workspace.selectedTabID == tab.id, isHovered: hovered == tab.id,
                              onSelect: { workspace.selectedTabID = tab.id },
                              onClose: { withAnimation(.snappy) { workspace.close(tab) } })
                        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                            withAnimation(.snappy) { workspace.moveTab(id, to: tab.id) }
                            return true
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

private struct TabButton: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
                .imageScale(.small)
            Text(tab.title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minWidth: 110, maxWidth: 240, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(isHovered ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 1.5, y: 0.5)
        }
        .overlay {
            if isSelected { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onClose))
        .help(tab.title)
    }
}

/// Confirmation for destructive actions; typed confirmation for FLUSHDB/FLUSHALL.
struct ConfirmationSheet: View {
    let confirmation: Confirmation
    let dismiss: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: confirmation.isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(confirmation.isDestructive ? .orange : Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmation.title).font(.headline)
                    Text(confirmation.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let expected = confirmation.expectedText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type **\(expected)** to confirm:").font(.callout)
                    TextField(expected, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if typed == expected { run() } }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation.expectedText.map { typed != $0 } ?? false)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func run() {
        dismiss()
        confirmation.action()
    }
}

/// Server, deployment, protocol, notes and every capability with the reason when unavailable.
struct ConnectionInfoView: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection Details").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Server", systemImage: "server.rack") {
                        KeyValueList(items: serverItems)
                    }
                    ForEach(workspace.client.notes, id: \.self) { note in
                        NoticeBanner(message: note, systemImage: "lightbulb", color: .accentColor)
                    }
                    if !workspace.client.modules.isEmpty {
                        Card(title: "Modules", systemImage: "puzzlepiece.extension") {
                            KeyValueList(items: workspace.client.modules.map { ($0.displayName, $0.versionString.isEmpty ? $0.name : "\($0.name) \($0.versionString)") })
                        }
                    }
                    Card(title: "Capabilities", systemImage: "checklist") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Capabilities.Feature.allCases, id: \.self) { feature in
                                let capability = workspace.capabilities[feature]
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: capability.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(capability.isAvailable ? .green : .red.opacity(0.8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(feature.title)
                                        if let reason = capability.reason {
                                            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 640)
    }

    private var serverItems: [(String, String)] {
        let client = workspace.client
        var items: [(String, String)] = [
            ("Server", client.serverInfo.displayName),
            ("Deployment", client.deployment.displayName),
            ("Endpoint", client.primaryEndpoint.description),
            ("Protocol", "RESP\(client.protocolVersion)"),
        ]
        if let sentinel = client.sentinelEndpoint { items.append(("Sentinel", sentinel.description)) }
        if client.deployment.isCluster {
            items.append(("Shards", "\(client.slotMap.shards.count) masters, \(client.slotMap.shards.reduce(0) { $0 + $1.replicas.count }) replicas"))
        }
        if let os = client.serverInfo.operatingSystem { items.append(("OS", os)) }
        if let uptime = client.serverInfo.uptimeSeconds { items.append(("Uptime", Format.duration(seconds: Double(uptime)))) }
        items.append(("Database", client.deployment.isCluster ? "0 (cluster)" : "db\(client.database)"))
        items.append(("Mode", client.isReadOnly ? "Read-only" : "Read/write"))
        if client.usesTLS { items.append(("Transport", "TLS")) }
        if client.isTunnelled { items.append(("Tunnel", "SSH via \(workspace.profile.ssh?.host ?? "")")) }
        return items
    }
}
