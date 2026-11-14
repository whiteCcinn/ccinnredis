import AppKit
import Charts
import CcinnRedisKit
import RedisKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AnalysisModel {
    unowned let workspace: WorkspaceModel
    var pattern = ""
    var maxKeys = 50_000
    var keysPerSecond = 5_000
    var prefixDepth = 1
    private(set) var isRunning = false
    private(set) var progress: MemoryAnalyzer.Progress?
    private(set) var report: AnalysisReport?
    private(set) var error: String?
    private(set) var revision = 0
    private var task: Task<Void, Never>?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    var unavailableReason: String? { workspace.capabilities.supports(.scan) ? nil : workspace.capabilities[.scan].reason }

    func start() {
        guard !isRunning, unavailableReason == nil else { return }
        isRunning = true
        error = nil
        progress = nil
        let options = MemoryAnalyzer.Options(pattern: pattern.isEmpty ? nil : pattern, maxKeys: maxKeys, keysPerSecond: keysPerSecond,
                                             batchSize: 200, delimiter: workspace.browser.delimiter, prefixDepth: prefixDepth, topCount: 200)
        let analyzer = MemoryAnalyzer(client: workspace.client, options: options)
        task = Task { [weak self] in
            do {
                let result = try await analyzer.run { progress in
                    Task { @MainActor in
                        self?.progress = progress
                        self?.report = progress.report
                        self?.revision &+= 1
                    }
                }
                self?.report = result
            } catch is CancellationError {
                // Partial results stay visible.
            } catch let error as RedisError where error.kind == .cancelled {
                _ = error
            } catch {
                self?.error = describe(error)
            }
            self?.isRunning = false
            self?.revision &+= 1
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }

    func exportCSV() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ccinnredis-memory-\(workspace.profile.displayName.replacingOccurrences(of: "/", with: "-")).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AnalysisExport.csv(report).write(to: url, atomically: true, encoding: .utf8)
            workspace.showToast("Exported \(report.topKeys.count) keys")
        } catch {
            workspace.showToast(describe(error), isError: true)
        }
    }
}

struct AnalysisView: View {
    @Bindable var model: AnalysisModel

    var body: some View {
        if let reason = model.unavailableReason {
            UnavailableView(title: "Memory analysis needs SCAN", reason: reason, systemImage: "chart.pie")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    if let error = model.error { ErrorBanner(message: error) }
                    if let report = model.report, report.sampledKeys > 0 {
                        results(report)
                    } else if !model.isRunning {
                        ContentUnavailableView("Find big keys", systemImage: "chart.pie",
                                               description: Text("Samples keys with SCAN and measures them with MEMORY USAGE (or estimates on older servers), rate-limited so production is not disturbed."))
                            .frame(minHeight: 260)
                    }
                }
                .padding(18)
            }
        }
    }

    private var controls: some View {
        Card(title: "Memory Analysis", systemImage: "chart.pie") {
            HStack(spacing: 14) {
                TextField("Pattern (optional)", text: $model.pattern).textFieldStyle(.roundedBorder).frame(width: 200)
                Picker("Sample", selection: $model.maxKeys) {
                    ForEach([10_000, 50_000, 200_000, 1_000_000], id: \.self) { Text("\($0.formatted()) keys").tag($0) }
                }
                .frame(width: 190)
                Picker("Rate", selection: $model.keysPerSecond) {
                    Text("1,000 keys/s").tag(1_000)
                    Text("5,000 keys/s").tag(5_000)
                    Text("20,000 keys/s").tag(20_000)
                    Text("Unlimited").tag(0)
                }
                .frame(width: 170)
                Stepper("Prefix depth \(model.prefixDepth)", value: $model.prefixDepth, in: 1...4)
                Spacer()
                if model.isRunning {
                    Button(role: .destructive) { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { model.start() } label: { Label("Analyze", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                }
                Button { model.exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(model.report == nil)
            }
            if let progress = model.progress {
                HStack(spacing: 10) {
                    if model.isRunning { ProgressView(value: Double(progress.sampled), total: Double(max(model.maxKeys, 1))).frame(width: 200) }
                    Text("\(Format.count(progress.sampled)) keys sampled · \(progress.completedNodes)/\(progress.totalNodes) nodes · \(Format.duration(seconds: progress.elapsed)) · \(progress.method)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func results(_ report: AnalysisReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: "Keys sampled", value: Format.count(report.sampledKeys), systemImage: "number")
            StatTile(title: report.usesEstimates ? "Estimated size" : "Measured size", value: Format.bytes(report.totalBytes), systemImage: "memorychip", tint: .purple)
            StatTile(title: "Average key", value: Format.bytes(report.sampledKeys > 0 ? report.totalBytes / Int64(report.sampledKeys) : 0), systemImage: "divide", tint: .blue)
            StatTile(title: "Biggest key", value: Format.bytes(report.topKeys.first?.bytes), detail: report.topKeys.first?.key.display, systemImage: "exclamationmark.triangle", tint: .orange)
        }
        if report.usesEstimates {
            NoticeBanner(message: "Sizes are estimates: MEMORY USAGE is unavailable here (\(model.workspace.capabilities[.memoryUsage].reason ?? "older server")).",
                         systemImage: "info.circle", color: .orange)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)], spacing: 12) {
            Card(title: "By type", systemImage: "square.stack.3d.up") {
                Chart(report.byType) { entry in
                    BarMark(x: .value("Bytes", entry.bytes), y: .value("Type", entry.type.displayName))
                        .foregroundStyle(Theme.color(for: entry.type))
                        .annotation(position: .trailing) {
                            Text("\(Format.bytes(entry.bytes)) · \(Format.count(entry.keys))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(max(report.byType.count, 1)) * 30 + 10)
            }
            Card(title: "TTL distribution", systemImage: "timer") {
                Chart(report.ttlBuckets) { entry in
                    BarMark(x: .value("Bucket", entry.bucket.rawValue), y: .value("Keys", entry.keys))
                        .foregroundStyle(entry.bucket == .persistent ? Color.gray.gradient : Theme.accent.gradient)
                }
                .frame(height: 160)
            }
            Card(title: "Top prefixes", systemImage: "folder") {
                Chart(Array(report.byPrefix.prefix(10))) { entry in
                    BarMark(x: .value("Bytes", entry.bytes), y: .value("Prefix", entry.prefix))
                        .foregroundStyle(Theme.accent.gradient)
                        .annotation(position: .trailing) {
                            Text("\(Format.bytes(entry.bytes)) · \(Format.count(entry.keys))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(min(report.byPrefix.count, 10)) * 26 + 10)
            }
        }
        Card(title: "Biggest keys", systemImage: "list.number") {
            DataTable(columns: [
                TableColumnSpec(id: "rank", title: "#", width: 40, alignment: .right),
                TableColumnSpec(id: "key", title: "Key", width: 360, monospaced: true),
                TableColumnSpec(id: "type", title: "Type", width: 90),
                TableColumnSpec(id: "size", title: report.usesEstimates ? "≈ Size" : "Size", width: 100, alignment: .right),
                TableColumnSpec(id: "elements", title: "Elements", width: 90, alignment: .right),
                TableColumnSpec(id: "ttl", title: "TTL", width: 100, alignment: .right),
                TableColumnSpec(id: "node", title: "Node", width: 140, flexible: true),
            ], rowCount: report.topKeys.count, revision: model.revision, cell: { row, column in
                let sample = report.topKeys[row]
                switch column {
                case 0: return String(row + 1)
                case 1: return sample.key.display
                case 2: return sample.type.displayName
                case 3: return Format.bytes(sample.bytes)
                case 4: return sample.elements.map { Format.count($0) } ?? ""
                case 5: return sample.ttlMilliseconds.map { Format.ttl(milliseconds: $0) } ?? "—"
                default: return sample.node?.description ?? ""
                }
            }, cellColor: { row, column in
                column == 2 && report.topKeys.indices.contains(row) ? Theme.nsColor(for: report.topKeys[row].type) : nil
            }, onDoubleClick: { row in
                guard report.topKeys.indices.contains(row) else { return }
                model.workspace.openKey(report.topKeys[row].key)
            })
            .frame(height: 320)
        }
    }
}
