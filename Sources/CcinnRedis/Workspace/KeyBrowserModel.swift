import CcinnRedisKit
import Foundation
import Observation
import RedisKit

/// Key browser state (design D11): SCAN pages appended to a deduplicated collection, an immutable tree
/// snapshot rebuilt off the main actor on a debounce, flattened rows for a virtualised table, and type/TTL
/// metadata fetched lazily for visible rows.
@MainActor
@Observable
final class KeyBrowserModel {
    enum ViewMode: String, CaseIterable, Identifiable {
        case tree = "Tree"
        case list = "List"
        var id: String { rawValue }
    }

    let client: RedisClient
    weak var workspace: WorkspaceModel?

    var patternDraft = ""
    private(set) var pattern = ""
    var typeFilter: KeyType? {
        didSet { if oldValue != typeFilter { rescan() } }
    }
    var delimiter: String {
        didSet { if oldValue != delimiter { scheduleRebuild(immediately: true) } }
    }
    var viewMode: ViewMode = .tree {
        didSet { if oldValue != viewMode { scheduleRebuild(immediately: true) } }
    }

    private(set) var collection = KeyCollection()
    private(set) var snapshot = KeyTreeSnapshot.empty
    private(set) var rows: [KeyTreeRow] = []
    private var flatRowsCache: [KeyTreeRow] = []
    /// Bumped whenever `rows` changes (cheap change detection for the table).
    private(set) var rowsRevision = 0
    private(set) var expanded: Set<[UInt8]> = []
    var selectedKey: RedisKey?

    private(set) var isScanning = false
    private(set) var scanError: String?
    private(set) var scanComplete = false
    private(set) var totalKeys: Int64?
    private(set) var scannedNodes = (done: 0, total: 1)
    private(set) var targetCount: Int
    private(set) var metadata: [RedisKey: KeyMetadata] = [:]
    private var pendingMetadata: Set<RedisKey> = []

    private(set) var database: Int
    private(set) var keyspace: [KeyspaceEntry] = []
    private(set) var databaseCount = 16
    private(set) var recentKeys: [RedisKey] = []
    var openByName = ""

    private var scanTask: Task<Void, Never>?
    /// Bumped by every rescan; results of an older scan are ignored.
    private var scanGeneration = 0
    private var rebuildTask: Task<Void, Never>?
    private var buildGeneration = 0
    /// One tree build at a time; requests arriving meanwhile coalesce into one follow-up build.
    private var isBuilding = false
    private var rebuildPending = false
    private var rebuildPendingImmediately = false
    /// Bumped when the collection is replaced (rescan), so a build of the old keys is never shown.
    private var collectionEpoch = 0

    var pageSize: Int { max(100, UserDefaults.standard.integer(forKey: "scanPageSize").nonZero ?? 1000) }
    var initialLimit: Int { max(1000, UserDefaults.standard.integer(forKey: "initialKeyLimit").nonZero ?? 20_000) }

    init(client: RedisClient, delimiter: String) {
        self.client = client
        self.delimiter = delimiter
        database = client.database
        targetCount = 20_000
    }

    var scanAvailable: Bool { client.capabilities.supports(.scan) }
    var scanUnavailableReason: String { client.capabilities[.scan].reason ?? "SCAN is not available on this server." }
    var canSelectDatabase: Bool { !client.deployment.isCluster && client.capabilities.supports(.select) }

    // MARK: Lifecycle

    func start() {
        targetCount = initialLimit
        refreshKeyspace()
        rescan()
    }

    func stop() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        rebuildTask?.cancel()
    }

    func refreshKeyspace() {
        let client = client
        Task {
            if client.capabilities.supports(.dbsize) {
                totalKeys = try? await client.dbSize()
            }
            if client.capabilities.supports(.info), let info = try? await client.info(section: "keyspace") {
                keyspace = info.keyspace
            }
            if client.capabilities.supports(.config), canSelectDatabase,
               let entry = try? await client.config(pattern: "databases").first, let count = Int(entry.value) {
                databaseCount = max(1, min(count, 1024))
            }
        }
    }

    // MARK: Scanning

    func applyFilter() {
        pattern = patternDraft.trimmingCharacters(in: .whitespaces)
        rescan()
    }

    func rescan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        collectionEpoch &+= 1
        collection.removeAll()
        metadata.removeAll()
        pendingMetadata.removeAll()
        scanComplete = false
        scanError = nil
        targetCount = max(targetCount, initialLimit)
        scheduleRebuild(immediately: true)
        guard scanAvailable else {
            scanError = nil
            return
        }
        continueScanning(with: KeyScanner(client: client, pattern: pattern.isEmpty ? nil : pattern, type: typeFilter, count: pageSize))
    }

    private var scanner: KeyScanner?

    /// Runs the scan loop until `targetCount` keys are loaded. A running loop re-reads the target after
    /// every batch, so More/All only raise it and Stop lowers it (soft stop: the in-flight batch finishes
    /// instead of being cancelled, which would close the pooled connection).
    private func continueScanning(with scanner: KeyScanner) {
        self.scanner = scanner
        guard scanTask == nil else { return }
        let generation = scanGeneration
        isScanning = true
        scanTask = Task { [weak self] in
            var failure: String?
            var complete = false
            do {
                while true {
                    guard let model = self, model.scanGeneration == generation, !Task.isCancelled,
                          model.collection.count < model.targetCount else { break }
                    guard let batch = try await scanner.next() else {
                        complete = true
                        break
                    }
                    guard let model = self, model.scanGeneration == generation, !Task.isCancelled else { return }
                    if model.collection.append(contentsOf: batch.keys) > 0 { model.scheduleRebuild() }
                    model.scannedNodes = (batch.completedNodes, batch.totalNodes)
                }
            } catch {
                failure = describe(error)
            }
            guard let model = self, model.scanGeneration == generation else { return }
            if complete { model.scanComplete = true }
            if let failure, !Task.isCancelled { model.scanError = failure }
            model.isScanning = false
            model.scanTask = nil
            model.scheduleRebuild(immediately: true)
        }
    }

    func loadMore() {
        guard !scanComplete, let scanner else { return }
        targetCount = max(targetCount, collection.count + max(initialLimit, 10_000))
        continueScanning(with: scanner)
    }

    func loadAll() {
        targetCount = .max
        if !scanComplete, let scanner { continueScanning(with: scanner) }
    }

    /// Soft stop: the loop ends after the batch in flight.
    func stopScanning() {
        targetCount = collection.count
        scheduleRebuild(immediately: true)
    }

    var hasMore: Bool { !scanComplete && scanAvailable }

    // MARK: Tree

    private func scheduleRebuild(immediately: Bool = false) {
        buildGeneration &+= 1
        if isBuilding {
            rebuildPending = true
            rebuildPendingImmediately = rebuildPendingImmediately || immediately
            return
        }
        rebuildTask?.cancel() // only ever cancels a debounce sleep, never a running build
        rebuildTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
            }
            await self?.runBuild()
        }
    }

    /// Builds the tree off the main actor; at most one build runs at a time.
    private func runBuild() async {
        isBuilding = true
        let generation = buildGeneration
        let epoch = collectionEpoch
        let keys = collection.keys
        let delimiter = viewMode == .tree ? delimiter : ""
        let flat = viewMode == .list
        let built = await Task.detached(priority: .userInitiated) { () -> (KeyTreeSnapshot, [KeyTreeRow]) in
            let tree = KeyTreeSnapshot.build(keys: keys, delimiter: delimiter)
            return (tree, flat ? tree.flatRows() : [])
        }.value
        isBuilding = false
        // Show progress even when newer keys arrived meanwhile, unless the view settings or the key set changed.
        let currentDelimiter = viewMode == .tree ? self.delimiter : ""
        if epoch == collectionEpoch, delimiter == currentDelimiter, flat == (viewMode == .list) {
            snapshot = built.0
            flatRowsCache = built.1
            recomputeRows()
        }
        if rebuildPending || generation != buildGeneration {
            let immediately = rebuildPendingImmediately || epoch != collectionEpoch
            rebuildPending = false
            rebuildPendingImmediately = false
            scheduleRebuild(immediately: immediately)
        }
    }

    private func recomputeRows() {
        rows = viewMode == .list ? flatRowsCache : snapshot.rows(expanded: expanded)
        rowsRevision &+= 1
    }

    func toggle(_ node: Int32) {
        guard let prefix = snapshot.prefix(of: node) else { return }
        setExpanded(prefix, !expanded.contains(prefix))
    }

    func setExpanded(_ prefix: [UInt8], _ isExpanded: Bool) {
        if isExpanded { expanded.insert(prefix) } else { expanded.remove(prefix) }
        recomputeRows()
    }

    func collapseAll() {
        expanded.removeAll()
        recomputeRows()
    }

    func isExpanded(_ node: Int32) -> Bool {
        snapshot.prefix(of: node).map { expanded.contains($0) } ?? false
    }

    // MARK: Metadata

    /// Fetches TYPE/TTL for keys in the visible rows (batched, deduplicated).
    func requestMetadata(rows range: Range<Int>) {
        let lower = max(0, range.lowerBound - 20)
        let upper = min(rows.count, range.upperBound + 40)
        guard lower < upper else { return }
        var wanted: [RedisKey] = []
        for index in lower..<upper {
            guard let key = snapshot.key(of: rows[index].node), metadata[key] == nil, !pendingMetadata.contains(key) else { continue }
            wanted.append(key)
            if wanted.count >= 400 { break }
        }
        guard !wanted.isEmpty else { return }
        pendingMetadata.formUnion(wanted)
        let client = client
        Task { [weak self] in
            let result = try? await client.metadata(for: wanted)
            guard let self else { return }
            self.pendingMetadata.subtract(wanted)
            for entry in result ?? [] { self.metadata[entry.key] = entry }
            self.rowsRevision &+= 1
        }
    }

    func refreshMetadata(for key: RedisKey) {
        metadata[key] = nil
        let client = client
        Task { [weak self] in
            if let entry = try? await client.metadata(for: [key]).first {
                self?.metadata[key] = entry
                self?.rowsRevision &+= 1
            }
        }
    }

    // MARK: Mutations

    func remove(_ keys: [RedisKey]) {
        collection.remove(keys)
        for key in keys { metadata[key] = nil }
        if let selectedKey, keys.contains(selectedKey) { self.selectedKey = nil }
        recentKeys.removeAll { keys.contains($0) }
        totalKeys = totalKeys.map { max(0, max(0, $0) - Int64(keys.count)) }
        scheduleRebuild(immediately: true)
    }

    func add(_ key: RedisKey) {
        if collection.append(contentsOf: [key]) > 0 {
            totalKeys = totalKeys.map { $0 == .max ? $0 : $0 + 1 }
            scheduleRebuild(immediately: true)
        }
    }

    func noteRecent(_ key: RedisKey) {
        recentKeys.removeAll { $0 == key }
        recentKeys.insert(key, at: 0)
        if recentKeys.count > 30 { recentKeys.removeLast(recentKeys.count - 30) }
    }

    /// Opens a key typed by name (works without SCAN, e.g. through twemproxy).
    func openTypedKey() {
        let name = openByName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let key = RedisKey(name)
        let client = client
        Task {
            do {
                let type = try await client.type(of: key)
                guard type.exists else {
                    workspace?.showToast("“\(name)” does not exist", isError: true)
                    return
                }
                metadata[key] = KeyMetadata(key: key, type: type, ttlMilliseconds: nil)
                add(key)
                workspace?.openKey(key)
                openByName = ""
            } catch {
                workspace?.showToast(describe(error), isError: true)
            }
        }
    }

    func selectDatabase(_ index: Int) {
        guard index != database else { return }
        let client = client
        Task {
            do {
                try await client.selectDatabase(index)
                database = index
                workspace?.tabs.filter { if case .key = $0.kind { true } else { false } }.forEach { workspace?.close($0) }
                refreshKeyspace()
                rescan()
            } catch {
                workspace?.showToast(describe(error), isError: true)
            }
        }
    }

    /// Keys for console completion.
    func keys(withPrefix prefix: String, limit: Int) -> [RedisKey] {
        collection.keys(withPrefix: prefix, limit: limit)
    }

    var statusText: String {
        let loaded = Format.count(collection.count)
        if !scanAvailable { return "Key scanning unavailable" }
        if let totalKeys, pattern.isEmpty, typeFilter == nil {
            return scanComplete ? "\(loaded) keys" : "\(loaded) of \(Format.count(totalKeys)) keys"
        }
        return scanComplete ? "\(loaded) matching keys" : "\(loaded) matching keys so far"
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
