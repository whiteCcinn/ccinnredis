import Charts
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Node selector for per-node views in a cluster.
struct NodePicker: View {
    @Binding var selection: Endpoint?
    let endpoints: [Endpoint]
    var allowsAll = false

    var body: some View {
        Picker("Node", selection: $selection) {
            Text(allowsAll ? "All masters" : "Primary").tag(Endpoint?.none)
            ForEach(endpoints, id: \.self) { Text($0.description).tag(Endpoint?.some($0)) }
        }
        .frame(width: 210)
    }
}

@MainActor
@Observable
final class DashboardModel {
    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let opsPerSecond: Double
        let usedMemory: Double
        let clients: Double
        let inputKbps: Double
        let outputKbps: Double
        let hitRatio: Double?
    }

    let workspace: WorkspaceModel
    var node: Endpoint? {
        didSet { if oldValue != node { samples.removeAll(); info = nil; restart() } }
    }
    private(set) var info: InfoSnapshot?
    private(set) var samples: [Sample] = []
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var previousHits: (hits: Double, misses: Double)?
    static let interval: Duration = .seconds(2)
    static let maxSamples = 180

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        restart()
    }

    var unavailableReason: String? {
        workspace.capabilities.supports(.info) ? nil : workspace.capabilities[.info].reason
    }

    func restart() {
        task?.cancel()
        guard unavailableReason == nil else { return }
        let client = workspace.client
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let snapshot = try await client.info(node: self.node)
                    self.ingest(snapshot)
                    self.error = nil
                } catch {
                    self.error = describe(error)
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() { task?.cancel() }

    /// INFO numbers are untrusted: NaN/inf/negative values become 0 so charts and tiles never misbehave.
    private static func metric(_ snapshot: InfoSnapshot, _ name: String) -> Double {
        max(0, SafeNumber.finite(snapshot.double(name)) ?? 0)
    }

    private func ingest(_ snapshot: InfoSnapshot) {
        info = snapshot
        let hits = Self.metric(snapshot, "keyspace_hits")
        let misses = Self.metric(snapshot, "keyspace_misses")
        var ratio: Double?
        if let previous = previousHits {
            let deltaHits = hits - previous.hits
            let deltaMisses = misses - previous.misses
            if deltaHits >= 0, deltaMisses >= 0, deltaHits + deltaMisses > 0 {
                ratio = deltaHits / (deltaHits + deltaMisses) * 100
            } else if hits + misses > 0 {
                ratio = hits / (hits + misses) * 100 // idle interval: lifetime ratio
            }
        } else if hits + misses > 0 {
            ratio = hits / (hits + misses) * 100
        }
        previousHits = (hits, misses)
        samples.append(Sample(time: Date(), opsPerSecond: Self.metric(snapshot, "instantaneous_ops_per_sec"),
                              usedMemory: Self.metric(snapshot, "used_memory"), clients: Self.metric(snapshot, "connected_clients"),
                              inputKbps: Self.metric(snapshot, "instantaneous_input_kbps"), outputKbps: Self.metric(snapshot, "instantaneous_output_kbps"),
                              hitRatio: ratio.flatMap { SafeNumber.finite($0) }.map { min(max($0, 0), 100) }))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }
}

struct DashboardView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "Server statistics are unavailable", reason: reason, systemImage: "gauge.with.dots.needle.0percent")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let error = model.error { ErrorBanner(message: error) }
                    if let info = model.info {
                        tiles(info)
                        charts
                        HStack(alignment: .top, spacing: 16) {
                            keyspace(info)
                            serverDetails(info)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(18)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Dashboard").font(.title2.weight(.semibold))
            Text("live · every 2 s").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.workspace.deployment.isCluster {
                NodePicker(selection: $model.node, endpoints: model.workspace.client.nodeEndpoints(.all))
            }
        }
    }

    private func tiles(_ info: InfoSnapshot) -> some View {
        let used = info.int("used_memory")
        let peak = info.int("used_memory_peak")
        let max = info.int("maxmemory").flatMap { $0 > 0 ? $0 : nil }
        let keys = SafeNumber.sum(info.keyspace.map(\.keys))
        let hitRatio = model.samples.last?.hitRatio
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: "Ops / sec", value: Format.count(SafeNumber.int64(info.double("instantaneous_ops_per_sec") ?? 0)),
                     detail: "\(Format.count(info.int("total_commands_processed"))) total", systemImage: "bolt.fill")
            StatTile(title: "Memory", value: Format.bytes(used), detail: max.map { "of \(Format.bytes($0)) max" } ?? "peak \(Format.bytes(peak))",
                     systemImage: "memorychip", tint: .purple)
            StatTile(title: "Clients", value: Format.count(info.int("connected_clients")),
                     detail: "\(Format.count(info.int("blocked_clients"))) blocked", systemImage: "person.2.fill", tint: .blue)
            StatTile(title: "Keys", value: Format.count(keys), detail: "\(info.keyspace.count) database\(info.keyspace.count == 1 ? "" : "s")",
                     systemImage: "key.fill", tint: .orange)
            StatTile(title: "Hit ratio", value: Format.percent(hitRatio),
                     detail: "\(Format.count(info.int("keyspace_hits"))) hits", systemImage: "scope", tint: .green)
            StatTile(title: "Evicted / expired", value: "\(Format.count(info.int("evicted_keys"))) / \(Format.count(info.int("expired_keys")))",
                     detail: info["maxmemory_policy"].map { "policy \($0)" }, systemImage: "trash", tint: .red)
            StatTile(title: "Fragmentation", value: info["mem_fragmentation_ratio"] ?? "—", detail: info["mem_allocator"],
                     systemImage: "square.split.2x2", tint: .teal)
            StatTile(title: "Uptime", value: Format.duration(seconds: info.double("uptime_in_seconds") ?? 0),
                     detail: [info["role"], info["redis_mode"]].compactMap { $0 }.joined(separator: " · "), systemImage: "clock", tint: .gray)
        }
    }

    private var charts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
            chartCard("Operations per second", systemImage: "bolt") {
                Chart(model.samples) { sample in
                    AreaMark(x: .value("Time", sample.time), y: .value("Ops", sample.opsPerSecond))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.time), y: .value("Ops", sample.opsPerSecond))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                }
            }
            chartCard("Memory used", systemImage: "memorychip") {
                Chart(model.samples) { sample in
                    AreaMark(x: .value("Time", sample.time), y: .value("Bytes", sample.usedMemory))
                        .foregroundStyle(LinearGradient(colors: [Color.purple.opacity(0.35), Color.purple.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", sample.time), y: .value("Bytes", sample.usedMemory)).foregroundStyle(.purple)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Format.bytes(SafeNumber.int64(value.as(Double.self) ?? 0))) }
                    }
                }
            }
            chartCard("Connected clients", systemImage: "person.2") {
                Chart(model.samples) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value("Clients", sample.clients))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.stepEnd)
                }
            }
            chartCard("Network (KB/s)", systemImage: "arrow.up.arrow.down") {
                Chart {
                    ForEach(model.samples) { sample in
                        LineMark(x: .value("Time", sample.time), y: .value("KB/s", sample.inputKbps), series: .value("Direction", "In"))
                            .foregroundStyle(by: .value("Direction", "In"))
                        LineMark(x: .value("Time", sample.time), y: .value("KB/s", sample.outputKbps), series: .value("Direction", "Out"))
                            .foregroundStyle(by: .value("Direction", "Out"))
                    }
                }
                .chartForegroundStyleScale(["In": Color.teal, "Out": Color.orange])
            }
        }
    }

    private func chartCard<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        Card(title: title, systemImage: systemImage) {
            content()
                .chartXAxis(.hidden)
                .frame(height: 150)
        }
    }

    private func keyspace(_ info: InfoSnapshot) -> some View {
        Card(title: "Keyspace", systemImage: "cylinder") {
            if info.keyspace.isEmpty {
                Text("No keys").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("DB").foregroundStyle(.secondary)
                        Text("Keys").foregroundStyle(.secondary)
                        Text("Expires").foregroundStyle(.secondary)
                        Text("Avg TTL").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    ForEach(info.keyspace) { entry in
                        GridRow {
                            Text("db\(entry.database)").font(.callout.monospaced())
                            Text(Format.count(entry.keys)).monospacedDigit()
                            Text(Format.count(entry.expires)).monospacedDigit()
                            Text(entry.averageTTL > 0 ? Format.duration(seconds: Double(entry.averageTTL) / 1000) : "—").monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func serverDetails(_ info: InfoSnapshot) -> some View {
        Card(title: "Server", systemImage: "server.rack") {
            KeyValueList(items: [
                ("Version", info["valkey_version"].map { "Valkey \($0)" } ?? info["redis_version"].map { "Redis \($0)" } ?? "—"),
                ("Mode", info["redis_mode"] ?? "—"),
                ("Role", info["role"].map { $0 + (info["connected_slaves"].map { " · \($0) replicas" } ?? "") } ?? "—"),
                ("OS", info["os"] ?? "—"),
                ("Port", info["tcp_port"] ?? "—"),
                ("Persistence", "RDB \(info["rdb_last_bgsave_status"] ?? "?") · AOF \(info["aof_enabled"] == "1" ? "on" : "off")"),
                ("Config", info["config_file"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
            ])
        }
    }
}
