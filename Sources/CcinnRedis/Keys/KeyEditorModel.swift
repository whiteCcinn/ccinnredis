import CcinnRedisKit
import Foundation
import Observation
import RedisKit

/// One key editor tab: metadata plus a paged view of the value for its type.
@MainActor
@Observable
final class KeyEditorModel {
    private(set) var key: RedisKey
    unowned let workspace: WorkspaceModel

    private(set) var details: KeyDetails?
    private(set) var isLoading = false
    var error: String?
    /// Pinned tabs are not replaced when another key is opened.
    var isPinned = false
    private(set) var revision = 0

    // String
    private(set) var stringValue: StringValue?
    var stringFormat: ValueFormat = .text
    var stringDraft = ""
    var stringDirty = false

    // Hash / Set / ZSet scans
    var filter = ""
    private(set) var hashEntries: [FieldValue] = []
    private(set) var setMembers: [[UInt8]] = []
    private(set) var zsetMembers: [ScoredMember] = []
    private(set) var cursor = "0"
    private(set) var isComplete = false
    var zsetDescending = false

    // List (window)
    private(set) var listItems: [[UInt8]] = []
    private(set) var listStart = 0
    static let listPage = 500

    // Stream
    private(set) var streamEntries: [StreamEntry] = []
    private(set) var streamInfo: StreamInfo?
    private(set) var streamGroups: [StreamGroup] = []
    var selectedGroup: String?
    private(set) var consumers: [StreamConsumer] = []
    private(set) var pending: [PendingEntry] = []
    var streamSection: StreamSection = .entries

    // JSON
    var jsonDraft = ""
    private(set) var jsonOriginal = ""

    var selection: Set<Int> = []

    enum StreamSection: String, CaseIterable, Identifiable {
        case entries = "Entries"
        case groups = "Consumer Groups"
        var id: String { rawValue }
    }

    static let pageSize = 500
    private var loadTask: Task<Void, Never>?

    init(key: RedisKey, workspace: WorkspaceModel) {
        self.key = key
        self.workspace = workspace
    }

    var client: RedisClient { workspace.client }
    var type: KeyType { details?.type ?? workspace.browser.metadata[key]?.type ?? .none }
    var isReadOnly: Bool { workspace.isReadOnly }
    var canEditString: Bool { !isReadOnly && !(stringValue?.isTruncated ?? false) }

    func close() { loadTask?.cancel() }

    // MARK: Loading

    func load() {
        loadTask?.cancel()
        isLoading = true
        error = nil
        loadTask = Task {
            defer { isLoading = false }
            do {
                let details = try await client.details(for: key)
                guard !Task.isCancelled else { return }
                self.details = details
                guard details.type.exists else {
                    error = "This key no longer exists."
                    return
                }
                try await loadValue(reset: true)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = describe(error)
            }
        }
    }

    func reload() { load() }

    private func loadValue(reset: Bool) async throws {
        switch type {
        case .string:
            let value = try await client.stringValue(key, maxBytes: 1 << 20)
            stringValue = value
            stringFormat = ValueFormatter.detect(value.bytes)
            stringDraft = ValueFormatter.render(value.bytes, as: stringFormat)
            stringDirty = false
        case .hash, .set, .zset:
            if reset {
                hashEntries = []
                setMembers = []
                zsetMembers = []
                cursor = "0"
                isComplete = false
            }
            if type == .zset, filter.isEmpty {
                try await loadZSetRange(reset: reset)
            } else {
                try await loadNextScanPage()
            }
        case .list:
            listStart = reset ? 0 : listStart
            listItems = try await client.listRange(key, start: listStart, stop: listStart + Self.listPage - 1)
        case .stream:
            streamInfo = try? await client.streamInfo(key)
            streamEntries = try await client.streamRange(key, count: Self.pageSize, descending: true)
            streamGroups = (try? await client.streamGroups(key)) ?? []
            if selectedGroup == nil || !streamGroups.contains(where: { $0.name == selectedGroup }) { selectedGroup = streamGroups.first?.name }
            try await loadGroupDetails()
        default:
            if type.isJSON, client.hasJSONModule {
                let text = try await client.jsonGet(key)
                jsonOriginal = JSONPrettyPrinter.format(text) ?? text
                jsonDraft = jsonOriginal
            }
        }
        selection = []
        revision &+= 1
    }

    private func loadZSetRange(reset: Bool) async throws {
        let start = reset ? 0 : zsetMembers.count
        let page = try await client.zsetRange(key, start: start, stop: start + Self.pageSize - 1, descending: zsetDescending)
        zsetMembers = reset ? page : zsetMembers + page
        isComplete = page.count < Self.pageSize
    }

    private func loadNextScanPage() async throws {
        guard !isComplete else { return }
        let match = filter.isEmpty ? nil : (filter.contains("*") || filter.contains("?") ? filter : "*\(filter)*")
        var collected = 0
        // SCAN pages may be empty with a MATCH; keep going until something arrives or the scan ends.
        repeat {
            switch type {
            case .hash:
                let page = try await client.hashScan(key, cursor: cursor, match: match, count: Self.pageSize)
                hashEntries += page.elements
                collected += page.elements.count
                cursor = page.cursor
            case .set:
                let page = try await client.setScan(key, cursor: cursor, match: match, count: Self.pageSize)
                setMembers += page.elements
                collected += page.elements.count
                cursor = page.cursor
            case .zset:
                let page = try await client.zsetScan(key, cursor: cursor, match: match, count: Self.pageSize)
                zsetMembers += page.elements
                collected += page.elements.count
                cursor = page.cursor
            default:
                return
            }
            isComplete = cursor == "0"
        } while !isComplete && collected < Self.pageSize / 2 && !Task.isCancelled
    }

    func loadMore() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                if type == .zset, filter.isEmpty { try await loadZSetRange(reset: false) } else { try await loadNextScanPage() }
                revision &+= 1
            } catch {
                self.error = describe(error)
            }
        }
    }

    func applyFilter() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do { try await loadValue(reset: true) } catch { self.error = describe(error) }
        }
    }

    func pageList(by delta: Int) {
        let total = Int(details?.length ?? 0)
        let next = max(0, min(listStart + delta * Self.listPage, max(0, total - 1)))
        guard next != listStart || delta == 0 else { return }
        listStart = next
        Task {
            do {
                listItems = try await client.listRange(key, start: listStart, stop: listStart + Self.listPage - 1)
                revision &+= 1
            } catch { self.error = describe(error) }
        }
    }

    func selectGroup(_ name: String?) {
        selectedGroup = name
        Task {
            try? await loadGroupDetails()
            revision &+= 1
        }
    }

    private func loadGroupDetails() async throws {
        guard let group = selectedGroup else {
            consumers = []
            pending = []
            return
        }
        consumers = (try? await client.streamConsumers(key, group: group)) ?? []
        pending = (try? await client.streamPending(key, group: group, count: 200)) ?? []
    }

    // MARK: Mutations

    private func mutate(_ success: String, reload: Bool = true, _ operation: @escaping @MainActor () async throws -> Void) {
        workspace.perform(success) {
            try await operation()
            if reload { self.load() }
            self.workspace.browser.refreshMetadata(for: self.key)
        }
    }

    func saveString() {
        guard canEditString else { return }
        do {
            let bytes = try ValueFormatter.parse(stringDraft, as: stringFormat)
            mutate("Saved \(key.display)") { try await self.client.setString(self.key, bytes, keepTTL: true) }
        } catch {
            workspace.showToast(describe(error), isError: true)
        }
    }

    func changeStringFormat(_ format: ValueFormat) {
        guard let value = stringValue else { return }
        if stringDirty, let bytes = try? ValueFormatter.parse(stringDraft, as: stringFormat) {
            stringDraft = ValueFormatter.render(bytes, as: format)
        } else {
            stringDraft = ValueFormatter.render(value.bytes, as: format)
        }
        stringFormat = format
    }

    func setHashField(field: [UInt8], value: [UInt8], replacing old: [UInt8]? = nil) {
        mutate("Saved field") {
            try await self.client.hashSet(self.key, field: field, value: value)
            if let old, old != field { try await self.client.hashDelete(self.key, fields: [old]) }
        }
    }

    func deleteHashFields(_ fields: [[UInt8]]) {
        mutate("Deleted \(fields.count) field\(fields.count == 1 ? "" : "s")") { try await self.client.hashDelete(self.key, fields: fields) }
    }

    func setListItem(index: Int, value: [UInt8]) {
        mutate("Saved item") { try await self.client.listSet(self.key, index: index, value: value) }
    }

    func pushListItem(_ value: [UInt8], atHead: Bool) {
        mutate("Added item") { try await self.client.listPush(self.key, values: [value], atHead: atHead) }
    }

    func removeListItem(index: Int) {
        mutate("Removed item") { try await self.client.listRemove(self.key, index: index) }
    }

    func addSetMember(_ member: [UInt8]) {
        mutate("Added member") { try await self.client.setAdd(self.key, members: [member]) }
    }

    func removeSetMembers(_ members: [[UInt8]]) {
        mutate("Removed \(members.count) member\(members.count == 1 ? "" : "s")") { try await self.client.setRemove(self.key, members: members) }
    }

    func setZSetMember(_ member: [UInt8], score: Double, replacing old: [UInt8]? = nil) {
        mutate("Saved member") {
            try await self.client.zsetAdd(self.key, member: member, score: score)
            if let old, old != member { try await self.client.zsetRemove(self.key, members: [old]) }
        }
    }

    func removeZSetMembers(_ members: [[UInt8]]) {
        mutate("Removed \(members.count) member\(members.count == 1 ? "" : "s")") { try await self.client.zsetRemove(self.key, members: members) }
    }

    func addStreamEntry(id: String, fields: [FieldValue]) {
        mutate("Added entry") { try await self.client.streamAdd(self.key, id: id, fields: fields) }
    }

    func deleteStreamEntries(_ ids: [String]) {
        mutate("Deleted \(ids.count) entr\(ids.count == 1 ? "y" : "ies")") { try await self.client.streamDelete(self.key, ids: ids) }
    }

    func createGroup(name: String, startID: String) {
        mutate("Created group \(name)") { try await self.client.groupCreate(self.key, group: name, startID: startID) }
    }

    func destroyGroup(_ name: String) {
        mutate("Destroyed group \(name)") { try await self.client.groupDestroy(self.key, group: name) }
    }

    func saveJSON() {
        guard JSONPrettyPrinter.format(jsonDraft) != nil else {
            workspace.showToast("The document is not valid JSON", isError: true)
            return
        }
        let compact = JSONPrettyPrinter.minify(jsonDraft) ?? jsonDraft
        mutate("Saved JSON document") { try await self.client.jsonSet(self.key, json: compact) }
    }

    func setTTL(seconds: Int64?) {
        mutate(seconds == nil ? "Removed expiration" : "TTL set to \(Format.duration(seconds: Double(seconds ?? 0)))") {
            try await self.client.setTTL(self.key, seconds: seconds)
        }
    }

    func rename(to newName: String) {
        let newKey = RedisKey(newName)
        guard newKey != key, !newName.isEmpty else { return }
        let oldKey = key
        workspace.perform("Renamed to \(newName)") {
            try await self.client.rename(oldKey, to: newKey, overwrite: false)
            self.key = newKey
            self.workspace.browser.remove([oldKey])
            self.workspace.browser.add(newKey)
            self.load()
        }
    }

    func deleteKey() {
        KeyActions.confirmDelete([key], in: workspace)
    }
}
