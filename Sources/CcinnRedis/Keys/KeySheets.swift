import CcinnRedisKit
import RedisKit
import SwiftUI

/// What an element edit sheet edits.
struct ElementDraft: Identifiable {
    enum Kind { case hashField, listItem, setMember, zsetMember }
    let id = UUID()
    let kind: Kind
    var name: [UInt8] = []
    var value: [UInt8] = []
    var score: Double = 0
    var index: Int?
    var atHead = false

    struct Result {
        var name: [UInt8]
        var value: [UInt8]
        var score: Double
    }
}

/// Edits a hash field, list item, set member or sorted-set member with text/JSON/hex views of the value.
struct ElementEditSheet: View {
    let draft: ElementDraft
    let isReadOnly: Bool
    let onSave: (ElementDraft.Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var score = ""
    @State private var format: ValueFormat = .text
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            switch draft.kind {
            case .hashField:
                TextField("Field", text: $name).textFieldStyle(.roundedBorder).font(Theme.monospaced)
                valueEditor
            case .listItem, .setMember:
                valueEditor
            case .zsetMember:
                TextField("Score", text: $score, prompt: Text("e.g. 42, -1.5, +inf")).textFieldStyle(.roundedBorder).font(Theme.monospaced)
                Text("Member").font(.caption).foregroundStyle(.secondary)
                PlainTextEditor(text: $name, isEditable: !isReadOnly)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isReadOnly)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            name = String(decoding: draft.name, as: UTF8.self)
            format = draft.value.isEmpty ? .text : ValueFormatter.detect(draft.value)
            value = ValueFormatter.render(draft.value, as: format)
            score = String(decoding: RedisArgument.double(draft.score).bytes, as: UTF8.self)
        }
    }

    private var title: String {
        switch draft.kind {
        case .hashField: draft.name.isEmpty ? "Add Field" : "Edit Field"
        case .listItem: draft.index.map { "Edit Item \($0)" } ?? (draft.atHead ? "Push to Head" : "Push to Tail")
        case .setMember: "Add Member"
        case .zsetMember: draft.name.isEmpty ? "Add Member" : "Edit Member"
        }
    }

    private var valueEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { format }, set: { newFormat in
                    if let bytes = try? ValueFormatter.parse(value, as: format) { value = ValueFormatter.render(bytes, as: newFormat) }
                    format = newFormat
                })) {
                    ForEach(ValueFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            PlainTextEditor(text: $value, isEditable: !isReadOnly)
                .frame(minHeight: 160, maxHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private func save() {
        do {
            switch draft.kind {
            case .zsetMember:
                guard let parsed = Double(score.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+inf", with: "inf")), !parsed.isNaN else {
                    error = "Enter a numeric score"
                    return
                }
                guard !name.isEmpty else {
                    error = "Enter a member"
                    return
                }
                onSave(ElementDraft.Result(name: Array(name.utf8), value: [], score: parsed))
            case .hashField:
                guard !name.isEmpty else {
                    error = "Enter a field name"
                    return
                }
                onSave(ElementDraft.Result(name: Array(name.utf8), value: try ValueFormatter.parse(value, as: format), score: 0))
            default:
                onSave(ElementDraft.Result(name: [], value: try ValueFormatter.parse(value, as: format), score: 0))
            }
            dismiss()
        } catch {
            self.error = describe(error)
        }
    }
}

struct TTLSheet: View {
    let model: KeyEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time to Live").font(.headline)
            Text("Current: \(Format.ttl(milliseconds: model.details?.ttlMilliseconds))").foregroundStyle(.secondary)
            HStack {
                TextField("Seconds", text: $seconds).textFieldStyle(.roundedBorder).frame(width: 140)
                ForEach([("1m", 60), ("1h", 3600), ("1d", 86_400), ("7d", 604_800)], id: \.0) { label, value in
                    Button(label) { seconds = String(value) }
                }
            }
            HStack {
                Button("Remove Expiration") {
                    model.setTTL(seconds: nil)
                    dismiss()
                }
                .disabled(model.details?.ttlMilliseconds == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set TTL") {
                    if let value = Int64(seconds), value > 0 {
                        model.setTTL(seconds: value)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((Int64(seconds) ?? 0) <= 0)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { seconds = model.details?.ttlMilliseconds.map { String($0 / 1000) } ?? "" }
    }
}

struct RenameSheet: View {
    let model: KeyEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Key").font(.headline)
            TextField("New name", text: $name).textFieldStyle(.roundedBorder).font(Theme.monospaced)
            if model.client.deployment.isCluster {
                Text("In a cluster both names must hash to the same slot (keep the {hashtag} part identical).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("RENAMENX is used, so an existing key is never overwritten.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.rename(to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || name == model.key.string)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { name = model.key.string }
    }
}

struct StreamEntrySheet: View {
    let onAdd: (String, [FieldValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id = "*"
    @State private var pairs: [(field: String, value: String)] = [("", "")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Stream Entry").font(.headline)
            TextField("ID", text: $id, prompt: Text("* (auto)")).textFieldStyle(.roundedBorder).font(Theme.monospaced)
            ForEach(pairs.indices, id: \.self) { index in
                HStack {
                    TextField("Field", text: Binding(get: { pairs[index].field }, set: { pairs[index].field = $0 })).textFieldStyle(.roundedBorder)
                    TextField("Value", text: Binding(get: { pairs[index].value }, set: { pairs[index].value = $0 })).textFieldStyle(.roundedBorder)
                    Button { if pairs.count > 1 { pairs.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button { pairs.append(("", "")) } label: { Label("Add field", systemImage: "plus") }.buttonStyle(.link)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let fields = pairs.filter { !$0.field.isEmpty }.map { FieldValue(field: Array($0.field.utf8), value: Array($0.value.utf8)) }
                    onAdd(id, fields)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pairs.contains { !$0.field.isEmpty })
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct GroupSheet: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = "$"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Consumer Group").font(.headline)
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Start at", selection: $start) {
                Text("New entries only ($)").tag("$")
                Text("Beginning of the stream (0)").tag("0")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(name, start)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Creates a key of any type with a first element.
struct NewKeySheet: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: KeyType = .string
    @State private var field = ""
    @State private var value = ""
    @State private var score = "0"
    @State private var ttl = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Key").font(.headline)
            TextField("Key name", text: $name).textFieldStyle(.roundedBorder).font(Theme.monospaced)
            Picker("Type", selection: $type) {
                ForEach(KeyType.filterable.filter { availableTypes.contains($0) }, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            switch type {
            case .hash, .stream:
                TextField("Field", text: $field).textFieldStyle(.roundedBorder)
            case .zset:
                TextField("Score", text: $score).textFieldStyle(.roundedBorder)
            default:
                EmptyView()
            }
            Text(type == .zset || type == .set ? "Member" : type.isJSON ? "JSON document" : "Value").font(.caption).foregroundStyle(.secondary)
            PlainTextEditor(text: $value)
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            TextField("TTL in seconds (optional)", text: $ttl).textFieldStyle(.roundedBorder).frame(width: 220)
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var availableTypes: Set<KeyType> {
        var types: Set<KeyType> = [.string, .hash, .list, .set, .zset]
        if workspace.capabilities.supports(.streams) { types.insert(.stream) }
        if workspace.client.hasJSONModule { types.insert(.json) }
        return types
    }

    private func create() {
        let key = RedisKey(name)
        let client = workspace.client
        let bytes = Array(value.utf8)
        let fieldBytes = Array(field.utf8)
        let scoreValue = Double(score) ?? 0
        let ttlValue = Int64(ttl)
        let type = type
        Task {
            do {
                guard try await !client.exists(key) else {
                    error = "A key named “\(name)” already exists"
                    return
                }
                switch type {
                case .string: try await client.setString(key, bytes, keepTTL: false)
                case .hash: try await client.hashSet(key, field: fieldBytes.isEmpty ? Array("field".utf8) : fieldBytes, value: bytes)
                case .list: try await client.listPush(key, values: [bytes], atHead: false)
                case .set: try await client.setAdd(key, members: [bytes])
                case .zset: try await client.zsetAdd(key, member: bytes, score: scoreValue)
                case .stream: try await client.streamAdd(key, fields: [FieldValue(field: fieldBytes.isEmpty ? Array("field".utf8) : fieldBytes, value: bytes)])
                default: try await client.jsonSet(key, json: value.isEmpty ? "{}" : value)
                }
                if let ttlValue, ttlValue > 0 { try await client.setTTL(key, seconds: ttlValue) }
                workspace.browser.add(key)
                workspace.openKey(key)
                workspace.showToast("Created \(name)")
                dismiss()
            } catch {
                self.error = describe(error)
            }
        }
    }
}
