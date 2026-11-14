import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

struct CcinnRedisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup("CcinnRedis", id: "main") {
            RootView()
                .frame(minWidth: 1080, minHeight: 660)
                .preferredColorScheme(LaunchArguments.appearanceOverride ?? AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Behave like a regular app when launched from `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        if let scheme = LaunchArguments.appearanceOverride {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        }
        SnapshotTool.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close SSH port forwards synchronously; detached cleanup tasks do not run during exit.
        SSHTunnel.terminateAll()
    }
}

/// Per-window root: connection manager, progress, or workspace.
struct RootView: View {
    @State private var session = WindowSession()
    private let store = AppServices.shared.profiles

    var body: some View {
        Group {
            switch session.phase {
            case .connections:
                ConnectionsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name, status):
                ConnectingView(name: name, status: status) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .onDisappear { session.disconnect() }
        .task { LaunchArguments.consume(into: session, store: store) }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .connections: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .connections: "CcinnRedis — Connections"
        case let .connecting(name, _): "Connecting to \(name)"
        case let .connected(workspace): workspace.profile.displayName
        }
    }
}

/// Full-window progress while a connection is being established.
struct ConnectingView: View {
    let name: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64).symbolEffect(.pulse)
            Text("Connecting to \(name)").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Developer conveniences and automated visual checks:
/// `CcinnRedis --connect host:port | --cluster h:p,h:p | --sentinel h:p,h:p --master name`
/// `  [--user u] [--password p] [--db n] [--tls-ca file] [--readonly] [--proxy twemproxy|envoy|…] [--profile name]`
/// `  [--open console|dashboard|info|slowlog|clients|config|cluster|pubsub|analysis|connection] [--key name]`
/// `  [--console "CMD; CMD"] [--pattern glob] [--type hash] [--load-all] [--expand prefix:] [--run-analysis]`
/// `  [--appearance light|dark] [--profiles-directory dir] [--demo-profiles] [--new-connection]`
@MainActor
enum LaunchArguments {
    private static var consumed = false
    private static let arguments = ProcessInfo.processInfo.arguments

    static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    static var appearanceOverride: ColorScheme? {
        switch value("--appearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    static func consume(into session: WindowSession, store: ProfileStore) {
        guard !consumed else { return }
        consumed = true
        if has("--demo-profiles") { DemoProfiles.install(into: store) }
        var profile: ConnectionProfile?
        var secrets = ProfileSecrets(password: value("--password"))
        if let name = value("--profile"), let saved = store.profiles.first(where: { $0.displayName == name }) {
            profile = saved
            secrets = store.secrets(for: saved)
        } else if let raw = value("--connect"), let endpoint = Endpoint.parse(raw) {
            var made = ConnectionProfile(name: value("--name") ?? raw, host: endpoint.host, port: endpoint.port, color: .red)
            made.useUnixSocket = endpoint.isUnixSocket
            profile = made
        } else if let raw = value("--cluster") {
            var made = ConnectionProfile(name: value("--name") ?? "Cluster \(raw.split(separator: ",").first ?? "")", color: .teal, mode: .cluster)
            made.clusterSeeds = raw
            profile = made
        } else if let raw = value("--sentinel") {
            var made = ConnectionProfile(name: value("--name") ?? "Sentinel", color: .purple, mode: .sentinel)
            made.sentinelNodes = raw
            made.sentinelMasterName = value("--master") ?? "mymaster"
            profile = made
        }
        guard var profile else { return }
        if let user = value("--user") { profile.username = user }
        if let db = value("--db").flatMap(Int.init) { profile.database = db }
        if let ca = value("--tls-ca") { profile.tls = TLSOptions(caFile: ca) }
        if has("--readonly") { profile.readOnly = true }
        if let proxy = value("--proxy").flatMap(ProxyChoice.init(rawValue:)) { profile.proxy = proxy }
        if let delimiter = value("--delimiter") { profile.delimiter = delimiter }
        session.connect(profile: profile, store: store, secrets: secrets) { workspace in
            Task { @MainActor in await applyWorkspaceArguments(workspace) }
        }
    }

    private static func applyWorkspaceArguments(_ workspace: WorkspaceModel) async {
        let browser = workspace.browser
        if let type = value("--type") { browser.typeFilter = KeyType.filterable.first { $0.rawValue == type || $0.badge.lowercased() == type.lowercased() } }
        if let pattern = value("--pattern") {
            browser.patternDraft = pattern
            browser.applyFilter()
        }
        if has("--load-all") { browser.loadAll() }
        if let prefix = value("--expand") {
            for _ in 0..<200 where browser.snapshot.keyCount == 0 || browser.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            var accumulated = ""
            for part in prefix.split(separator: Character(browser.delimiter.isEmpty ? ":" : browser.delimiter)) {
                accumulated += part + browser.delimiter
                browser.setExpanded(Array(accumulated.utf8), true)
            }
        }
        if let key = value("--key") { workspace.openKey(RedisKey(key)) }
        switch value("--open") {
        case "console": workspace.openConsole(initial: value("--console"))
        case "connection": workspace.showConnectionInfo = true
        case let raw?:
            if let tool = WorkspaceModel.Tool(rawValue: raw) {
                workspace.open(tool)
                if tool == .analysis, has("--run-analysis") {
                    try? await Task.sleep(for: .milliseconds(300))
                    workspace.analysisModel?.start()
                }
            }
        case nil:
            if let commands = value("--console") { workspace.openConsole(initial: commands) }
        }
    }
}

/// Sample profiles for screenshots (`--demo-profiles` with `--profiles-directory`).
@MainActor
enum DemoProfiles {
    static func install(into store: ProfileStore) {
        guard store.profiles.isEmpty else { return }
        func make(_ name: String, _ color: ProfileColor, _ configure: (inout ConnectionProfile) -> Void) -> ConnectionProfile {
            var profile = ConnectionProfile(name: name, color: color)
            configure(&profile)
            return profile
        }
        let profiles = [
            make("Local Redis 7.2 · 200k keys", .red) { $0.port = 17072; $0.isFavorite = true; $0.lastConnectedAt = Date() },
            make("Cluster 3×2", .teal) { $0.mode = .cluster; $0.clusterSeeds = "127.0.0.1:17101, 127.0.0.1:17102"; $0.isFavorite = true },
            make("Sentinel · mymaster", .purple) { $0.mode = .sentinel; $0.sentinelNodes = "127.0.0.1:17311, 127.0.0.1:17312, 127.0.0.1:17313"; $0.sentinelMasterName = "mymaster" },
            make("twemproxy (legacy shard pool)", .orange) { $0.port = 17201; $0.proxy = .auto; $0.lastConnectedAt = Date().addingTimeInterval(-3600) },
            make("Redis 2.8 (legacy)", .gray) { $0.port = 17028; $0.lastConnectedAt = Date().addingTimeInterval(-7200) },
            make("Valkey 8", .blue) { $0.port = 17088 },
            make("redis-stack (JSON, Search)", .green) { $0.port = 17095 },
            make("Production cache (read-only)", .pink) {
                $0.host = "cache.internal.example"
                $0.username = "reader"
                $0.readOnly = true
                $0.tls = TLSOptions()
                $0.ssh = SSHTunnelConfiguration(host: "bastion.example.com", username: "ops", authentication: .agent)
            },
        ]
        for profile in profiles { _ = try? store.save(profile, secrets: ProfileSecrets()) }
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot]`: renders the key window
/// into a PNG (used for automated visual checks; needs no screen-recording permission).
@MainActor
enum SnapshotTool {
    static func scheduleIfRequested() {
        guard let path = LaunchArguments.value("--snapshot") else { return }
        let delay = LaunchArguments.value("--snapshot-delay").flatMap(Double.init) ?? 6
        let quit = LaunchArguments.has("--quit-after-snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
               let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            MCPSettingsView(store: AppServices.shared.profiles)
                .tabItem { Label("AI Access", systemImage: "sparkles") }
        }
        .frame(width: 620)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("scanPageSize") private var scanPageSize = 1000
    @AppStorage("initialKeyLimit") private var initialKeyLimit = 20_000

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("SCAN page size (COUNT)", selection: $scanPageSize) {
                ForEach([100, 500, 1000, 2000, 5000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Keys loaded automatically", selection: $initialKeyLimit) {
                ForEach([5_000, 20_000, 50_000, 100_000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            LabeledContent("Saved connections") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppServices.shared.dataDirectory])
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

/// Settings → AI Access: per-profile MCP access and ready-to-paste client configuration.
struct MCPSettingsView: View {
    let store: ProfileStore
    @State private var copied: String?

    private var command: String { Bundle.main.executablePath ?? "/Applications/CcinnRedis.app/Contents/MacOS/CcinnRedis" }

    var body: some View {
        Form {
            Section {
                Text("CcinnRedis includes an MCP server so AI assistants can inspect your Redis data through the connections you enable here. It runs the same app binary in `mcp` mode over stdio, reads secrets from the Keychain, enforces read-only access itself (allow-listed commands, bounded results, timeouts) and logs every call to mcp-audit.jsonl.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Connections") {
                if store.profiles.isEmpty {
                    Text("No saved connections yet.").foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    Picker(selection: Binding(get: { profile.mcpAccess }, set: { store.setMCPAccess($0, for: profile) })) {
                        ForEach(MCPAccess.allCases) { Text($0.title).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName)
                            Text(profile.hostSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Command") {
                snippet("Executable", command)
            }
            Section("Client configuration") {
                snippet("Claude Code", "claude mcp add ccinnredis -- \"\(command)\" mcp")
                snippet("Codex (~/.codex/config.toml)", "[mcp_servers.ccinnredis]\ncommand = \"\(command)\"\nargs = [\"mcp\"]")
                snippet("Claude Desktop / JSON", "{\"mcpServers\": {\"ccinnredis\": {\"command\": \"\(command)\", \"args\": [\"mcp\"]}}}")
                Text("Add `--read-only` to the args to cap every connection at read-only, or `--profile <name>` to set a default connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(minHeight: 520)
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    Pasteboard.copy(text)
                    copied = title
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Console") { session?.workspace?.openConsole() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.workspace == nil)
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
        CommandMenu("Server") {
            Button("Reload Keys") { session?.workspace?.browser.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Divider()
            ForEach(WorkspaceModel.Tool.allCases) { tool in
                Button(tool.title) { session?.workspace?.open(tool) }
                    .disabled(session?.workspace == nil)
            }
            Divider()
            Button("Connection Details") { session?.workspace?.showConnectionInfo = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("Close Tab") { session?.workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedTab == nil)
            Button("Next Tab") { session?.workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Previous Tab") { session?.workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
    }
}
