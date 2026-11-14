import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Header with key metadata and actions, then the editor for the key's type.
struct KeyEditorView: View {
    @Bindable var model: KeyEditorModel
    @State private var showTTL = false
    @State private var showRename = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showTTL) { TTLSheet(model: model) }
        .sheet(isPresented: $showRename) { RenameSheet(model: model) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TypeBadge(type: model.type)
                Text(model.key.display)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button { Pasteboard.copy(model.key.display) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy key name")
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Button { showTTL = true } label: { Label("TTL", systemImage: "timer") }
                    .disabled(model.isReadOnly)
                Button { showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    .disabled(model.isReadOnly)
                Button(role: .destructive) { model.deleteKey() } label: { Label("Delete", systemImage: "trash") }
                    .disabled(model.isReadOnly)
                Toggle(isOn: $model.isPinned) { Image(systemName: model.isPinned ? "pin.fill" : "pin") }
                    .toggleStyle(.button)
                    .help("Keep this tab open when other keys are opened")
            }
            HStack(spacing: 16) {
                metric("TTL", Format.ttl(milliseconds: model.details?.ttlMilliseconds), icon: "timer")
                metric(model.type == .string ? "Length" : "Elements", lengthText, icon: "number")
                metric("Memory", memoryText, icon: "memorychip")
                metric("Encoding", model.details?.encoding ?? "—", icon: "square.stack.3d.up")
                if let idle = model.details?.idleSeconds { metric("Idle", Format.duration(seconds: Double(idle)), icon: "zzz") }
                Spacer()
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var lengthText: String {
        guard let length = model.details?.length else { return "—" }
        return model.type == .string ? Format.bytes(length) : Format.count(length)
    }

    private var memoryText: String {
        if let bytes = model.details?.memoryBytes { return Format.bytes(bytes) }
        return model.client.capabilities.supports(.memoryUsage) ? "—" : "n/a"
    }

    private func metric(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .help(title == "Memory" && !model.client.capabilities.supports(.memoryUsage) ? (model.client.capabilities[.memoryUsage].reason ?? "") : "")
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            VStack {
                ErrorBanner(message: error) { model.error = nil }
                Spacer()
            }
            .padding()
        } else if model.details == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.type {
            case .string: StringEditorView(model: model)
            case .hash: HashEditorView(model: model)
            case .list: ListEditorView(model: model)
            case .set: SetEditorView(model: model)
            case .zset: ZSetEditorView(model: model)
            case .stream: StreamEditorView(model: model)
            default:
                if model.type.isJSON, model.client.hasJSONModule {
                    JSONEditorView(model: model)
                } else {
                    UnavailableView(title: "\(model.type.displayName) values are not editable",
                                    reason: "CcinnRedis shows metadata for module types it does not know. Use the console for commands of this module.",
                                    systemImage: "puzzlepiece.extension")
                }
            }
        }
    }
}

// MARK: - String

private struct StringEditorView: View {
    @Bindable var model: KeyEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Format", selection: Binding(get: { model.stringFormat }, set: { model.changeStringFormat($0) })) {
                    ForEach(ValueFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .labelsHidden()
                if let value = model.stringValue, value.isTruncated {
                    Label("Showing the first \(Format.bytes(Int64(value.bytes.count))) of \(Format.bytes(value.totalLength)) — read-only", systemImage: "scissors")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Copy") { Pasteboard.copy(model.stringDraft) }
                Button("Revert") { model.changeStringFormat(model.stringFormat); model.stringDirty = false }
                    .disabled(!model.stringDirty)
                Button("Save") { model.saveString() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.stringDirty || !model.canEditString)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            PlainTextEditor(text: $model.stringDraft, isEditable: model.canEditString) { model.stringDirty = true }
        }
    }
}

// MARK: - Collections

/// Toolbar shared by collection editors: filter, counts, load more, add, delete.
private struct CollectionToolbar: View {
    @Bindable var model: KeyEditorModel
    let loaded: Int
    var filterPrompt = "Filter (glob or text)"
    var supportsFilter = true
    var onAdd: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if supportsFilter {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(filterPrompt, text: $model.filter).textFieldStyle(.plain).onSubmit { model.applyFilter() }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 280)
            }
            Text("\(Format.count(loaded)) loaded" + (model.details?.length.map { " of \(Format.count($0))" } ?? ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !model.isComplete {
                Button("Load more") { model.loadMore() }.buttonStyle(.link).font(.caption)
            }
            Spacer()
            if let onAdd {
                Button { onAdd() } label: { Label("Add", systemImage: "plus") }.disabled(model.isReadOnly)
            }
            if let onDelete {
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "minus") }
                    .disabled(model.isReadOnly || model.selection.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct HashEditorView: View {
    @Bindable var model: KeyEditorModel
    @State private var editing: ElementDraft?

    var body: some View {
        VStack(spacing: 0) {
            CollectionToolbar(model: model, loaded: model.hashEntries.count, onAdd: { editing = ElementDraft(kind: .hashField) }, onDelete: deleteSelected)
            Divider()
            DataTable(columns: [
                TableColumnSpec(id: "n", title: "#", width: 50, alignment: .right),
                TableColumnSpec(id: "field", title: "Field", width: 240, monospaced: true),
                TableColumnSpec(id: "value", title: "Value", width: 480, monospaced: true, flexible: true),
            ], rowCount: model.hashEntries.count, revision: model.revision, cell: { row, column in
                let entry = model.hashEntries[row]
                switch column {
                case 0: return String(row + 1)
                case 1: return Format.bytesText(entry.field)
                default: return Format.bytesText(entry.value)
                }
            }, cellColor: { _, column in column == 0 ? .tertiaryLabelColor : nil },
            selection: $model.selection, onDoubleClick: { row in
                guard model.hashEntries.indices.contains(row) else { return }
                let entry = model.hashEntries[row]
                editing = ElementDraft(kind: .hashField, name: entry.field, value: entry.value)
            }, menu: { rows in elementMenu(rows) }, onScrollNearEnd: { if !model.isComplete { model.loadMore() } })
        }
        .sheet(item: $editing) { draft in
            ElementEditSheet(draft: draft, isReadOnly: model.isReadOnly) { result in
                model.setHashField(field: result.name, value: result.value, replacing: draft.name.isEmpty ? nil : draft.name)
            }
        }
    }

    private func deleteSelected() {
        let fields = model.selection.sorted().compactMap { model.hashEntries.indices.contains($0) ? model.hashEntries[$0].field : nil }
        guard !fields.isEmpty else { return }
        model.workspace.confirm(Confirmation(title: "Delete \(fields.count) field\(fields.count == 1 ? "" : "s")?", message: "HDEL removes them from \(model.key.display).",
                                             confirmTitle: "Delete") { model.deleteHashFields(fields) })
    }

    private func elementMenu(_ rows: IndexSet) -> NSMenu {
        let menu = NSMenu()
        let entries = rows.compactMap { model.hashEntries.indices.contains($0) ? model.hashEntries[$0] : nil }
        menu.addItem(ClosureMenuItem("Copy Values") { Pasteboard.copy(entries.map { String(decoding: $0.value, as: UTF8.self) }.joined(separator: "\n")) })
        menu.addItem(ClosureMenuItem("Copy Fields") { Pasteboard.copy(entries.map { String(decoding: $0.field, as: UTF8.self) }.joined(separator: "\n")) })
        if !model.isReadOnly {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete…") { deleteSelected() })
        }
        return menu
    }
}

private struct ListEditorView: View {
    @Bindable var model: KeyEditorModel
    @State private var editing: ElementDraft?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.pageList(by: -1) } label: { Image(systemName: "chevron.left") }.disabled(model.listStart == 0)
                Text("Items \(Format.count(model.listStart))–\(Format.count(model.listStart + max(0, model.listItems.count - 1))) of \(Format.count(model.details?.length))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { model.pageList(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.listStart + KeyEditorModel.listPage >= Int(model.details?.length ?? 0))
                Spacer()
                Button { editing = ElementDraft(kind: .listItem, atHead: true) } label: { Label("Push Head", systemImage: "arrow.up.to.line") }
                    .disabled(model.isReadOnly)
                Button { editing = ElementDraft(kind: .listItem, atHead: false) } label: { Label("Push Tail", systemImage: "arrow.down.to.line") }
                    .disabled(model.isReadOnly)
                Button(role: .destructive) { removeSelected() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(model.isReadOnly || model.selection.count != 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            DataTable(columns: [
                TableColumnSpec(id: "index", title: "Index", width: 80, alignment: .right),
                TableColumnSpec(id: "value", title: "Value", width: 600, monospaced: true, flexible: true),
            ], rowCount: model.listItems.count, revision: model.revision, cell: { row, column in
                column == 0 ? String(model.listStart + row) : Format.bytesText(model.listItems[row])
            }, cellColor: { _, column in column == 0 ? .tertiaryLabelColor : nil },
            selection: $model.selection, onDoubleClick: { row in
                guard model.listItems.indices.contains(row) else { return }
                editing = ElementDraft(kind: .listItem, value: model.listItems[row], index: model.listStart + row)
            })
        }
        .sheet(item: $editing) { draft in
            ElementEditSheet(draft: draft, isReadOnly: model.isReadOnly) { result in
                if let index = draft.index {
                    model.setListItem(index: index, value: result.value)
                } else {
                    model.pushListItem(result.value, atHead: draft.atHead)
                }
            }
        }
    }

    private func removeSelected() {
        guard let row = model.selection.first, model.listItems.indices.contains(row) else { return }
        let index = model.listStart + row
        model.workspace.confirm(Confirmation(title: "Remove item \(index)?", message: "The element at index \(index) is removed from the list.",
                                             confirmTitle: "Remove") { model.removeListItem(index: index) })
    }
}

private struct SetEditorView: View {
    @Bindable var model: KeyEditorModel
    @State private var editing: ElementDraft?

    var body: some View {
        VStack(spacing: 0) {
            CollectionToolbar(model: model, loaded: model.setMembers.count, onAdd: { editing = ElementDraft(kind: .setMember) }, onDelete: deleteSelected)
            Divider()
            DataTable(columns: [
                TableColumnSpec(id: "n", title: "#", width: 60, alignment: .right),
                TableColumnSpec(id: "member", title: "Member", width: 600, monospaced: true, flexible: true),
            ], rowCount: model.setMembers.count, revision: model.revision, cell: { row, column in
                column == 0 ? String(row + 1) : Format.bytesText(model.setMembers[row])
            }, cellColor: { _, column in column == 0 ? .tertiaryLabelColor : nil },
            selection: $model.selection, onScrollNearEnd: { if !model.isComplete { model.loadMore() } })
        }
        .sheet(item: $editing) { draft in
            ElementEditSheet(draft: draft, isReadOnly: model.isReadOnly) { model.addSetMember($0.value) }
        }
    }

    private func deleteSelected() {
        let members = model.selection.sorted().compactMap { model.setMembers.indices.contains($0) ? model.setMembers[$0] : nil }
        guard !members.isEmpty else { return }
        model.workspace.confirm(Confirmation(title: "Remove \(members.count) member\(members.count == 1 ? "" : "s")?", message: "SREM removes them from the set.",
                                             confirmTitle: "Remove") { model.removeSetMembers(members) })
    }
}

private struct ZSetEditorView: View {
    @Bindable var model: KeyEditorModel
    @State private var editing: ElementDraft?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CollectionToolbar(model: model, loaded: model.zsetMembers.count, onAdd: { editing = ElementDraft(kind: .zsetMember) }, onDelete: deleteSelected)
                Toggle(isOn: Binding(get: { model.zsetDescending }, set: { model.zsetDescending = $0; model.applyFilter() })) {
                    Label("Highest first", systemImage: "arrow.down")
                }
                .toggleStyle(.button)
                .padding(.trailing, 12)
                .disabled(!model.filter.isEmpty)
            }
            Divider()
            DataTable(columns: [
                TableColumnSpec(id: "rank", title: "Rank", width: 60, alignment: .right),
                TableColumnSpec(id: "score", title: "Score", width: 140, monospaced: true, alignment: .right),
                TableColumnSpec(id: "member", title: "Member", width: 520, monospaced: true, flexible: true),
            ], rowCount: model.zsetMembers.count, revision: model.revision, cell: { row, column in
                let entry = model.zsetMembers[row]
                switch column {
                case 0: return model.filter.isEmpty ? String(row) : ""
                case 1: return RedisArgument.double(entry.score).bytes.isEmpty ? "" : String(decoding: RedisArgument.double(entry.score).bytes, as: UTF8.self)
                default: return Format.bytesText(entry.member)
                }
            }, cellColor: { _, column in column == 0 ? .tertiaryLabelColor : column == 1 ? NSColor.consoleNumber : nil },
            selection: $model.selection, onDoubleClick: { row in
                guard model.zsetMembers.indices.contains(row) else { return }
                let entry = model.zsetMembers[row]
                editing = ElementDraft(kind: .zsetMember, name: entry.member, score: entry.score)
            }, onScrollNearEnd: { if !model.isComplete { model.loadMore() } })
        }
        .sheet(item: $editing) { draft in
            ElementEditSheet(draft: draft, isReadOnly: model.isReadOnly) { result in
                model.setZSetMember(result.name, score: result.score, replacing: draft.name.isEmpty ? nil : draft.name)
            }
        }
    }

    private func deleteSelected() {
        let members = model.selection.sorted().compactMap { model.zsetMembers.indices.contains($0) ? model.zsetMembers[$0].member : nil }
        guard !members.isEmpty else { return }
        model.workspace.confirm(Confirmation(title: "Remove \(members.count) member\(members.count == 1 ? "" : "s")?", message: "ZREM removes them from the sorted set.",
                                             confirmTitle: "Remove") { model.removeZSetMembers(members) })
    }
}

// MARK: - Stream

private struct StreamEditorView: View {
    @Bindable var model: KeyEditorModel
    @State private var addingEntry = false
    @State private var creatingGroup = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.streamSection) {
                    ForEach(KeyEditorModel.StreamSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                if let info = model.streamInfo {
                    Text("last id \(info.lastGeneratedID ?? "—") · \(info.groups) groups").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if model.streamSection == .entries {
                    Button { addingEntry = true } label: { Label("Add Entry", systemImage: "plus") }.disabled(model.isReadOnly)
                    Button(role: .destructive) { deleteEntries() } label: { Label("Delete", systemImage: "minus") }
                        .disabled(model.isReadOnly || model.selection.isEmpty)
                } else {
                    Button { creatingGroup = true } label: { Label("New Group", systemImage: "plus") }.disabled(model.isReadOnly)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if model.streamSection == .entries {
                DataTable(columns: [
                    TableColumnSpec(id: "id", title: "ID", width: 190, monospaced: true),
                    TableColumnSpec(id: "fields", title: "Fields", width: 560, monospaced: true, flexible: true),
                ], rowCount: model.streamEntries.count, revision: model.revision, cell: { row, column in
                    let entry = model.streamEntries[row]
                    if column == 0 { return entry.id }
                    return entry.fields.map { "\(Format.bytesText($0.field, limit: 40))=\(Format.bytesText($0.value, limit: 80))" }.joined(separator: "  ")
                }, cellColor: { _, column in column == 0 ? NSColor.typeStream : nil }, selection: $model.selection)
            } else {
                groupsView
            }
        }
        .sheet(isPresented: $addingEntry) { StreamEntrySheet { id, fields in model.addStreamEntry(id: id, fields: fields) } }
        .sheet(isPresented: $creatingGroup) { GroupSheet { name, start in model.createGroup(name: name, startID: start) } }
    }

    private var groupsView: some View {
        VSplitView {
            DataTable(columns: [
                TableColumnSpec(id: "name", title: "Group", width: 160),
                TableColumnSpec(id: "consumers", title: "Consumers", width: 90, alignment: .right),
                TableColumnSpec(id: "pending", title: "Pending", width: 90, alignment: .right),
                TableColumnSpec(id: "last", title: "Last delivered", width: 180, monospaced: true),
                TableColumnSpec(id: "lag", title: "Lag", width: 80, alignment: .right),
                TableColumnSpec(id: "read", title: "Entries read", width: 110, alignment: .right, flexible: true),
            ], rowCount: model.streamGroups.count, revision: model.revision, cell: { row, column in
                let group = model.streamGroups[row]
                switch column {
                case 0: return group.name
                case 1: return String(group.consumers)
                case 2: return String(group.pending)
                case 3: return group.lastDeliveredID
                case 4: return group.lag.map(String.init) ?? "—"
                default: return group.entriesRead.map(String.init) ?? "—"
                }
            }, selection: Binding(get: { Set(model.streamGroups.indices.filter { model.streamGroups[$0].name == model.selectedGroup }) },
                                  set: { rows in if let row = rows.first, model.streamGroups.indices.contains(row) { model.selectGroup(model.streamGroups[row].name) } }),
            menu: { rows in
                let menu = NSMenu()
                if let row = rows.first, model.streamGroups.indices.contains(row), !model.isReadOnly {
                    let name = model.streamGroups[row].name
                    menu.addItem(ClosureMenuItem("Destroy Group “\(name)”…") {
                        model.workspace.confirm(Confirmation(title: "Destroy group \(name)?", message: "XGROUP DESTROY removes the group, its consumers and pending entries.",
                                                             confirmTitle: "Destroy") { model.destroyGroup(name) })
                    })
                }
                return menu
            })
            .frame(minHeight: 120)
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CONSUMERS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(6)
                    DataTable(columns: [
                        TableColumnSpec(id: "name", title: "Consumer", width: 140),
                        TableColumnSpec(id: "pending", title: "Pending", width: 70, alignment: .right),
                        TableColumnSpec(id: "idle", title: "Idle", width: 90, alignment: .right, flexible: true),
                    ], rowCount: model.consumers.count, revision: model.revision, cell: { row, column in
                        let consumer = model.consumers[row]
                        switch column {
                        case 0: return consumer.name
                        case 1: return String(consumer.pending)
                        default: return Format.duration(seconds: Double(consumer.idleMilliseconds) / 1000)
                        }
                    })
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("PENDING").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(6)
                    DataTable(columns: [
                        TableColumnSpec(id: "id", title: "Entry", width: 170, monospaced: true),
                        TableColumnSpec(id: "consumer", title: "Consumer", width: 110),
                        TableColumnSpec(id: "idle", title: "Idle", width: 80, alignment: .right),
                        TableColumnSpec(id: "deliveries", title: "Deliveries", width: 80, alignment: .right, flexible: true),
                    ], rowCount: model.pending.count, revision: model.revision, cell: { row, column in
                        let entry = model.pending[row]
                        switch column {
                        case 0: return entry.id
                        case 1: return entry.consumer
                        case 2: return Format.duration(seconds: Double(entry.idleMilliseconds) / 1000)
                        default: return String(entry.deliveries)
                        }
                    })
                }
            }
            .frame(minHeight: 140)
        }
    }

    private func deleteEntries() {
        let ids = model.selection.sorted().compactMap { model.streamEntries.indices.contains($0) ? model.streamEntries[$0].id : nil }
        guard !ids.isEmpty else { return }
        model.workspace.confirm(Confirmation(title: "Delete \(ids.count) entr\(ids.count == 1 ? "y" : "ies")?", message: "XDEL removes them from the stream.",
                                             confirmTitle: "Delete") { model.deleteStreamEntries(ids) })
    }
}

// MARK: - JSON

private struct JSONEditorView: View {
    @Bindable var model: KeyEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("RedisJSON document", systemImage: "curlybraces").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Format") { model.jsonDraft = JSONPrettyPrinter.format(model.jsonDraft) ?? model.jsonDraft }
                Button("Revert") { model.jsonDraft = model.jsonOriginal }.disabled(model.jsonDraft == model.jsonOriginal)
                Button("Save") { model.saveJSON() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isReadOnly || model.jsonDraft == model.jsonOriginal)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            PlainTextEditor(text: $model.jsonDraft, isEditable: !model.isReadOnly)
        }
    }
}
