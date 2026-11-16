import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Connection manager: saved profiles on the left, editor (or welcome) on the right.
struct ConnectionsView: View {
    @Bindable var session: WindowSession
    let store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    @State private var selection: UUID?
    @State private var draft: ConnectionDraft?
    @State private var search = ""
    @State private var pendingDelete: ConnectionProfile?

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: RootView.windowGroupID)
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                }
                .help("Open another window with its own connection (⌘N)")
            }
        }
        .onChange(of: selection) { _, newValue in
            if let profile = store.profile(id: newValue) { draft = ConnectionDraft(profile: profile, store: store) }
        }
        .onAppear {
            let launch = LaunchArguments.consumeConnectionScreenArguments()
            if launch, LaunchArguments.has("--new-connection") {
                newConnection()
            } else if launch, let name = LaunchArguments.value("--edit-profile"),
                      let profile = store.profiles.first(where: { $0.displayName == name }) {
                selection = profile.id
                draft = ConnectionDraft(profile: profile, store: store)
            } else if draft == nil, let first = store.favorites.first ?? store.recents.first ?? store.others.first {
                selection = first.id
                draft = ConnectionDraft(profile: first, store: store)
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete {
                    store.delete(profile)
                    if selection == profile.id {
                        selection = nil
                        draft = nil
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("The saved connection and its Keychain secrets will be removed.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter connections", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            List(selection: $selection) {
                if !store.favorites.isEmpty { Section("Favorites") { rows(filtered(store.favorites)) } }
                if !store.recents.isEmpty { Section("Recent") { rows(filtered(store.recents)) } }
                if !store.others.isEmpty { Section("Saved") { rows(filtered(store.others)) } }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.profiles.isEmpty {
                    ContentUnavailableView("No Saved Connections", systemImage: "bolt.horizontal", description: Text("Create a connection to get started."))
                }
            }
            Button {
                newConnection()
            } label: {
                Label("New Connection", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        .placedBelowWindowToolbar()
    }

    private func filtered(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        guard !search.isEmpty else { return profiles }
        return profiles.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.hostSummary.localizedCaseInsensitiveContains(search) }
    }

    private func rows(_ profiles: [ConnectionProfile]) -> some View {
        ForEach(profiles) { profile in
            ProfileRow(profile: profile)
                .tag(profile.id)
                .contextMenu {
                    Button("Connect") { session.connect(profile: profile, store: store) }
                    Button("Open in New Window") { openWindow(id: RootView.windowGroupID, value: WindowSession.request(opening: profile)) }
                    Divider()
                    Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(profile) }
                    Button("Duplicate") { if let copy = store.duplicate(profile) { selection = copy.id } }
                    Button("Copy URI (without password)") { Pasteboard.copy(ConnectionURI.string(for: profile)) }
                    Button("Copy redis-cli Command") { Pasteboard.copy(Self.cliCommand(for: profile)) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = profile }
                }
                .onTapGesture(count: 2) { session.connect(profile: profile, store: store) }
        }
    }

    static func cliCommand(for profile: ConnectionProfile) -> String {
        var parts = ["redis-cli"]
        switch profile.mode {
        case .standalone:
            if profile.useUnixSocket { parts += ["-s", profile.host] } else { parts += ["-h", profile.host, "-p", String(profile.port)] }
        case .cluster:
            if let seed = profile.clusterEndpoints.first { parts += ["-c", "-h", seed.host, "-p", String(seed.port)] }
        case .sentinel:
            if let sentinel = profile.sentinelEndpoints.first { parts += ["-h", sentinel.host, "-p", String(sentinel.port)] }
        }
        if !profile.username.isEmpty { parts += ["--user", profile.username] }
        if profile.database != 0, profile.mode != .cluster { parts += ["-n", String(profile.database)] }
        if profile.tls != nil { parts.append("--tls") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var detail: some View {
        if let draft {
            ConnectionEditorView(draft: draft, store: store, session: session) { saved in selection = saved.id }
                .id(draft.profileID ?? UUID())
        } else {
            WelcomeView(onNew: newConnection)
        }
    }

    private func newConnection() {
        selection = nil
        draft = ConnectionDraft(profile: nil, store: store)
    }
}

private struct ProfileRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.color(for: profile.color).gradient)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).lineLimit(1)
                Text(profile.hostSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            switch profile.mode {
            case .cluster: Image(systemName: "circle.hexagongrid").foregroundStyle(.teal).help("Cluster")
            case .sentinel: Image(systemName: "eye.trianglebadge.exclamationmark").foregroundStyle(.purple).help("Sentinel")
            case .standalone: EmptyView()
            }
            if profile.proxy != .auto { Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange).help("Behind a proxy") }
            if profile.ssh != nil { Image(systemName: "network").foregroundStyle(.secondary).help("SSH tunnel") }
            if profile.tls != nil { Image(systemName: "lock.shield").foregroundStyle(.green).help("TLS") }
            if profile.readOnly { Image(systemName: "lock").foregroundStyle(.orange).help("Read-only") }
            if profile.mcpAccess != .disabled { Image(systemName: "sparkles").foregroundStyle(.purple).help("AI access via MCP: \(profile.mcpAccess.title)") }
            if profile.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small) }
        }
        .padding(.vertical, 2)
    }
}

private struct WelcomeView: View {
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            AppLogo(size: 88)
            VStack(spacing: 6) {
                Text("Welcome to CcinnRedis").font(.largeTitle.weight(.semibold))
                Text("A native Redis & Valkey client for macOS — from Redis 2.8 to 8.x, standalone to cluster.").foregroundStyle(.secondary)
            }
            Button("New Connection…", action: onNew)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            HStack(spacing: 12) {
                FeaturePill(icon: "circle.hexagongrid", text: "Cluster & Sentinel")
                FeaturePill(icon: "arrow.triangle.branch", text: "Proxies")
                FeaturePill(icon: "key", text: "Millions of keys")
                FeaturePill(icon: "terminal", text: "Console")
                FeaturePill(icon: "chart.pie", text: "Memory analysis")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Edits one connection: mode-specific endpoints, credentials, TLS, SSH and safety options.
struct ConnectionEditorView: View {
    @Bindable var draft: ConnectionDraft
    let store: ProfileStore
    let session: WindowSession
    let onSaved: (ConnectionProfile) -> Void

    @State private var saveError: String?
    @State private var showPassword = false
    @State private var showURIImport = false
    @State private var uriText = ""
    @State private var uriError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    Picker("Deployment", selection: $draft.profile.mode) {
                        ForEach(DeploymentMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Form {
                        endpointSection
                        Section("Authentication") {
                            TextField("ACL user", text: $draft.profile.username, prompt: Text("default (leave empty for Redis < 6)"))
                            HStack {
                                Group {
                                    if showPassword {
                                        TextField("Password", text: $draft.password)
                                    } else {
                                        SecureField("Password", text: $draft.password)
                                    }
                                }
                                Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                            }
                            if draft.profile.mode != .cluster {
                                Stepper(value: $draft.profile.database, in: 0...1023) {
                                    LabeledContent("Database", value: "db\(draft.profile.database)")
                                }
                            }
                            Picker("Protocol", selection: $draft.profile.protocolPreference) {
                                Text("Auto (RESP3 when available)").tag(ProtocolPreference.auto)
                                Text("RESP2 only").tag(ProtocolPreference.resp2)
                                Text("RESP3 required").tag(ProtocolPreference.resp3)
                            }
                        }
                        Section("TLS") {
                            Toggle("Use TLS (rediss://)", isOn: $draft.tlsEnabled)
                            if draft.tlsEnabled { tlsFields }
                        }
                        Section("SSH Tunnel") {
                            Toggle("Connect through an SSH tunnel", isOn: $draft.sshEnabled)
                            if draft.sshEnabled { sshFields }
                        }
                        Section {
                            Picker("AI access via MCP", selection: $draft.profile.mcpAccess) {
                                ForEach(MCPAccess.allCases) { Text($0.title).tag($0) }
                            }
                        } header: {
                            Text("AI Access")
                        } footer: {
                            Text("Lets AI assistants (Claude Code, Codex, Claude Desktop…) use this connection through `CcinnRedis mcp`. Read-only allows bounded reads and an allow-listed read command; Read & write adds set/delete/expire tools. See Settings → AI Access.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Section("Safety & timeouts") {
                            Toggle("Read-only (block write commands before they are sent)", isOn: $draft.profile.readOnly)
                            Picker("Behind a proxy", selection: $draft.profile.proxy) {
                                ForEach(ProxyChoice.allCases) { Text($0.title).tag($0) }
                            }
                            TextField("Key group delimiter", text: $draft.profile.delimiter, prompt: Text(":"))
                            TextField("Connect timeout (seconds)", value: $draft.profile.connectTimeout, format: .number)
                            TextField("Command timeout (seconds)", value: $draft.profile.commandTimeout, format: .number)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)

                    testResult
                    ForEach(draft.validationErrors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                    if let saveError { ErrorBanner(message: saveError) { self.saveError = nil } }
                    if let error = session.connectError { ErrorBanner(message: error) { session.connectError = nil } }
                }
                .padding(28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actionBar
        }
        .sheet(isPresented: $showURIImport) { uriSheet }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(Theme.color(for: draft.profile.color).gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "bolt.fill").foregroundStyle(.white).font(.system(size: 15, weight: .semibold)))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Connection name", text: $draft.profile.name, prompt: Text(draft.profile.displayName.isEmpty ? "Untitled connection" : draft.profile.displayName))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(ProfileColor.allCases.filter { $0 != .none }) { color in
                        Button {
                            draft.profile.color = color
                        } label: {
                            Circle()
                                .fill(Theme.color(for: color))
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(.primary.opacity(draft.profile.color == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(color.rawValue.capitalized)
                    }
                }
            }
            Spacer()
            Button { showURIImport = true } label: { Label("Import URI", systemImage: "link") }
                .help("Fill the form from redis://, rediss://, unix://, redis-sentinel:// or redis-cluster://")
            Toggle(isOn: $draft.profile.isFavorite) { Image(systemName: draft.profile.isFavorite ? "star.fill" : "star") }
                .toggleStyle(.button)
                .help("Favorite")
        }
    }

    @ViewBuilder
    private var endpointSection: some View {
        switch draft.profile.mode {
        case .standalone:
            Section {
                Toggle("Unix domain socket", isOn: $draft.profile.useUnixSocket)
                if draft.profile.useUnixSocket {
                    TextField("Socket path", text: $draft.profile.host, prompt: Text("/var/run/redis/redis.sock"))
                } else {
                    HStack {
                        TextField("Host", text: $draft.profile.host, prompt: Text("127.0.0.1"))
                        TextField("Port", value: $draft.profile.port, format: .number.grouping(.never))
                            .frame(width: 90)
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Replicas are detected automatically (read-only). A cluster node is detected and switched to cluster routing. Proxies (twemproxy, Codis, Predixy, Envoy, cloud endpoints) are detected and their missing features explained.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .sentinel:
            Section {
                TextField("Master name", text: $draft.profile.sentinelMasterName, prompt: Text("mymaster"))
                TextField("Sentinels", text: $draft.profile.sentinelNodes, prompt: Text("10.0.0.1:26379, 10.0.0.2:26379"), axis: .vertical)
                    .lineLimit(1...4)
                Picker("Connect to", selection: $draft.profile.sentinelRole) {
                    Text("Master").tag(ClientConfiguration.SentinelRole.master)
                    Text("A replica (read-only)").tag(ClientConfiguration.SentinelRole.replica)
                }
                TextField("Sentinel user", text: $draft.profile.sentinelUsername, prompt: Text("optional"))
                SecureField("Sentinel password", text: $draft.sentinelPassword, prompt: Text("optional"))
                addressMapField
            } header: {
                Text("Sentinel")
            } footer: {
                Text("The master is resolved with SENTINEL get-master-addr-by-name and followed after failovers.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .cluster:
            Section {
                TextField("Seed nodes", text: $draft.profile.clusterSeeds, prompt: Text("10.0.0.1:7000, 10.0.0.2:7000"), axis: .vertical)
                    .lineLimit(1...4)
                Toggle("Scan replicas instead of masters", isOn: $draft.profile.scanReplicas)
                addressMapField
            } header: {
                Text("Cluster")
            } footer: {
                Text("Slots are loaded from CLUSTER SHARDS/SLOTS/NODES; MOVED and ASK redirects are followed; keys are scanned on every master.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var addressMapField: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("", text: $draft.profile.addressMapText, prompt: Text("172.18.0.5:6379 => 127.0.0.1:7001"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...5)
                    .font(Theme.monospacedSmall)
                    .multilineTextAlignment(.trailing)
                Text("Rewrites addresses announced by nodes (Docker, NAT). One rule per line; host-only rules keep the port.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Text("Address map")
        }
    }

    @ViewBuilder
    private var tlsFields: some View {
        fileField("CA certificate (PEM)", path: Binding(get: { draft.tls.caFile ?? "" }, set: { draft.tls.caFile = $0.isEmpty ? nil : $0 }), prompt: "system roots")
        fileField("Client certificate (.p12)", path: Binding(get: { draft.tls.clientCertificateFile ?? "" }, set: { draft.tls.clientCertificateFile = $0.isEmpty ? nil : $0 }), prompt: "optional")
        if draft.tls.clientCertificateFile != nil {
            SecureField("Certificate password", text: $draft.tlsCertificatePassword)
        }
        TextField("Server name (SNI)", text: Binding(get: { draft.tls.serverName ?? "" }, set: { draft.tls.serverName = $0.isEmpty ? nil : $0 }), prompt: Text("defaults to the host"))
        Toggle("Skip hostname verification", isOn: $draft.tls.allowInvalidHostnames)
        Toggle("Accept any certificate (insecure)", isOn: $draft.tls.allowInvalidCertificates)
        if draft.tls.allowInvalidCertificates {
            Label("The server's identity is not verified. Use only for test servers.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func fileField(_ title: String, path: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: path, prompt: Text(prompt)).labelsHidden()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
        }
    }

    @ViewBuilder
    private var sshFields: some View {
        TextField("SSH host", text: $draft.ssh.host, prompt: Text("bastion.example.com"))
        TextField("SSH port", value: $draft.ssh.port, format: .number.grouping(.never))
        TextField("SSH user", text: $draft.ssh.username)
        Picker("Authentication", selection: $draft.ssh.authentication) {
            Text("SSH agent / ~/.ssh/config").tag(SSHTunnelConfiguration.Authentication.agent)
            Text("Password").tag(SSHTunnelConfiguration.Authentication.password)
            Text("Private key").tag(SSHTunnelConfiguration.Authentication.privateKey)
        }
        switch draft.ssh.authentication {
        case .password:
            SecureField("SSH password", text: $draft.sshSecret)
        case .privateKey:
            fileField("Private key", path: Binding(get: { draft.ssh.privateKeyPath ?? "" }, set: { draft.ssh.privateKeyPath = $0 }), prompt: "~/.ssh/id_ed25519")
            SecureField("Passphrase (optional)", text: $draft.sshSecret)
        case .agent:
            EmptyView()
        }
        Text("Uses the system OpenSSH client (~/.ssh/config, known hosts, ssh-agent). Sentinel and cluster nodes discovered at runtime get their own forward through the same bastion.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var testResult: some View {
        switch draft.testState {
        case .idle:
            EmptyView()
        case let .running(status):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { draft.cancelTest() }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .succeeded(message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .failed(message):
            ErrorBanner(message: message) { draft.testState = .idle }
        }
    }

    private var actionBar: some View {
        HStack {
            Button { draft.test() } label: { Label("Test", systemImage: "bolt.horizontal.circle") }
                .disabled(!draft.isValid)
            Spacer()
            Button("Save") { _ = save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.isValid)
            Button {
                if let profile = save() { session.connect(profile: profile, store: store) }
            } label: {
                Text(draft.profileID == nil ? "Save & Connect" : "Connect").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var uriSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Connection URI").font(.headline)
            TextField("redis://user:password@host:6379/0", text: $uriText)
                .textFieldStyle(.roundedBorder)
                .font(Theme.monospaced)
            Text("Supported: redis://, rediss:// (TLS), unix:///path, redis-sentinel://h1,h2/0?master=name, redis-cluster://h1,h2. The password goes to the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if let uriError { ErrorBanner(message: uriError) }
            HStack {
                Spacer()
                Button("Cancel") { showURIImport = false }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    do {
                        try draft.apply(uri: uriText)
                        uriError = nil
                        showURIImport = false
                    } catch {
                        uriError = describe(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(uriText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() -> ConnectionProfile? {
        do {
            let saved = try store.save(draft.makeProfile(), secrets: draft.secrets)
            saveError = nil
            onSaved(saved)
            return saved
        } catch {
            saveError = describe(error)
            return nil
        }
    }
}
