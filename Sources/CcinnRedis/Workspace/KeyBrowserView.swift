import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Sidebar: filter, type and database pickers, scan progress and the virtualised key tree.
struct KeyBrowserView: View {
    @Bindable var browser: KeyBrowserModel
    let workspace: WorkspaceModel
    @State private var showNewKey = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if browser.scanAvailable {
                ZStack {
                    KeyTableView(browser: browser, revision: browser.rowsRevision, onOpen: { workspace.openKey($0) }, menu: contextMenu)
                    if browser.rows.isEmpty {
                        emptyState
                    }
                }
                Divider()
                statusBar
            } else {
                noScanView
            }
        }
        .placedBelowWindowToolbar()
        .sheet(isPresented: $showNewKey) {
            NewKeySheet(workspace: workspace)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter keys (glob, e.g. user:*)", text: $browser.patternDraft)
                    .textFieldStyle(.plain)
                    .onSubmit { browser.applyFilter() }
                if !browser.patternDraft.isEmpty {
                    Button {
                        browser.patternDraft = ""
                        browser.applyFilter()
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 6) {
                typeMenu
                if browser.canSelectDatabase { databaseMenu }
                Spacer(minLength: 0)
                Picker("", selection: $browser.viewMode) {
                    Image(systemName: "list.bullet.indent").tag(KeyBrowserModel.ViewMode.tree)
                    Image(systemName: "list.bullet").tag(KeyBrowserModel.ViewMode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 70)
                .help("Tree grouped by “\(browser.delimiter)” or flat list")
                Menu {
                    Button("Reload Keys") { browser.rescan() }
                    Button("Collapse All") { browser.collapseAll() }
                    Divider()
                    Picker("Group by", selection: $browser.delimiter) {
                        ForEach([":", ".", "/", "|", "-", "_", "::", "#"], id: \.self) { Text("“\($0)”").tag($0) }
                        Text("No grouping").tag("")
                    }
                    Divider()
                    Button("New Key…") { showNewKey = true }.disabled(workspace.isReadOnly)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button { showNewKey = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(workspace.isReadOnly)
                    .help(workspace.isReadOnly ? "Read-only connection" : "New key")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var typeMenu: some View {
        Menu {
            Button { browser.typeFilter = nil } label: {
                if browser.typeFilter == nil { Label("All types", systemImage: "checkmark") } else { Text("All types") }
            }
            Divider()
            ForEach(KeyType.filterable, id: \.self) { type in
                if !type.isJSON || workspace.client.hasJSONModule {
                    Button { browser.typeFilter = type } label: {
                        if browser.typeFilter == type { Label(type.displayName, systemImage: "checkmark") } else { Text(type.displayName) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(browser.typeFilter?.displayName ?? "All types")
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(workspace.capabilities.supports(.scanType) ? "Filter by type (server-side SCAN TYPE)" : "Filter by type (checked client-side on this server version)")
    }

    private var databaseMenu: some View {
        Menu {
            ForEach(0..<browser.databaseCount, id: \.self) { index in
                let keys = browser.keyspace.first { $0.database == index }?.keys
                Button {
                    browser.selectDatabase(index)
                } label: {
                    Text("db\(index)" + (keys.map { "  ·  \(Format.count($0)) keys" } ?? ""))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cylinder")
                Text("db\(browser.database)")
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Database")
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = browser.scanError {
            ErrorBanner(message: error).padding()
        } else if browser.isScanning {
            ProgressView().controlSize(.small)
        } else {
            ContentUnavailableView(browser.pattern.isEmpty ? "No Keys" : "No Matching Keys", systemImage: "key",
                                   description: Text(browser.pattern.isEmpty ? "This database is empty." : "Nothing matches “\(browser.pattern)”."))
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if browser.isScanning, let total = browser.totalKeys, total > 0, browser.pattern.isEmpty, browser.typeFilter == nil {
                ProgressView(value: min(1, Double(browser.collection.count) / Double(max(total, 1))))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            HStack(spacing: 6) {
                if browser.isScanning { ProgressView().controlSize(.mini) }
                Text(browser.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if browser.scannedNodes.total > 1 {
                    Text("· \(browser.scannedNodes.done)/\(browser.scannedNodes.total) nodes").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if browser.isScanning {
                    Button("Stop") { browser.stopScanning() }.buttonStyle(.link).font(.caption)
                } else if browser.hasMore {
                    Button("More") { browser.loadMore() }.buttonStyle(.link).font(.caption)
                    Button("All") { browser.loadAll() }.buttonStyle(.link).font(.caption)
                        .help("Scan the whole keyspace (incremental SCAN; the UI stays responsive)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var noScanView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NoticeBanner(message: browser.scanUnavailableReason + " Keys can still be opened by name.",
                             systemImage: "arrow.triangle.branch", color: .orange)
                HStack {
                    TextField("Key name", text: $browser.openByName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { browser.openTypedKey() }
                    Button("Open") { browser.openTypedKey() }
                        .disabled(browser.openByName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !browser.recentKeys.isEmpty {
                    Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    ForEach(browser.recentKeys, id: \.self) { key in
                        Button {
                            workspace.openKey(key)
                        } label: {
                            HStack {
                                if let type = browser.metadata[key]?.type { TypeBadge(type: type) }
                                Text(key.display).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
    }

    private func contextMenu(key: RedisKey?, folder: Int32?) -> NSMenu? {
        let menu = NSMenu()
        if let key {
            menu.addItem(ClosureMenuItem("Open") { workspace.openKey(key) })
            menu.addItem(ClosureMenuItem("Copy Name") { Pasteboard.copy(key.display) })
            menu.addItem(ClosureMenuItem("Open in Console") { workspace.openConsole(initial: "TYPE \(CLITokenizer.quote(key.bytes))") })
            if !workspace.isReadOnly {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Delete…") { KeyActions.confirmDelete([key], in: workspace) })
            }
        } else if let folder, let prefix = browser.snapshot.prefix(of: folder) {
            let text = RedisKey(bytes: prefix).display
            let count = browser.snapshot.leafCount(of: folder)
            menu.addItem(ClosureMenuItem(browser.isExpanded(folder) ? "Collapse" : "Expand") { browser.toggle(folder) })
            menu.addItem(ClosureMenuItem("Filter to “\(text)*”") {
                browser.patternDraft = text + "*"
                browser.applyFilter()
            })
            menu.addItem(ClosureMenuItem("Copy Prefix") { Pasteboard.copy(text) })
            if !workspace.isReadOnly {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Delete \(Format.count(count)) Loaded Keys…") {
                    KeyActions.confirmDelete(browser.snapshot.keys(under: folder), in: workspace, label: "all \(Format.count(count)) loaded keys under “\(text)”")
                })
            }
        } else {
            menu.addItem(ClosureMenuItem("Reload Keys") { browser.rescan() })
        }
        return menu
    }
}

/// NSMenuItem with a closure action.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc private func run() {
        handler()
    }
}

/// Shared destructive key actions with confirmation.
@MainActor
enum KeyActions {
    static func confirmDelete(_ keys: [RedisKey], in workspace: WorkspaceModel, label: String? = nil) {
        guard !keys.isEmpty else { return }
        let description = label ?? (keys.count == 1 ? "“\(keys[0].display)”" : "\(keys.count) keys")
        let method = workspace.capabilities.supports(.unlink) ? "UNLINK (non-blocking)" : "DEL"
        workspace.confirm(Confirmation(title: "Delete \(description)?",
                                       message: "The keys are removed from the server with \(method). This cannot be undone.",
                                       confirmTitle: "Delete") {
            workspace.perform(keys.count == 1 ? "Deleted \(keys[0].display)" : "Deleted \(keys.count) keys") {
                try await workspace.client.delete(keys)
                workspace.keysDeleted(keys)
            }
        })
    }
}
