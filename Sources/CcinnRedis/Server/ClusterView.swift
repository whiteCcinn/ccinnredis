import CcinnRedisKit
import RedisKit
import SwiftUI

@MainActor
@Observable
final class ClusterModel {
    let workspace: WorkspaceModel
    private(set) var nodes: [ClusterNodeInfo] = []
    private(set) var info: [String: String] = [:]
    private(set) var error: String?
    private(set) var isLoading = false

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        load()
    }

    var isCluster: Bool { workspace.deployment.isCluster }

    func load() {
        guard isCluster else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                async let nodes = workspace.client.clusterNodes()
                async let info = workspace.client.clusterInfo()
                self.nodes = try await nodes
                self.info = try await info
                try? await workspace.client.refreshTopology(force: true)
                error = nil
            } catch {
                self.error = describe(error)
            }
        }
    }

    var masters: [ClusterNodeInfo] {
        nodes.filter { $0.role == .master }.sorted { ($0.slotRanges.first?.lowerBound ?? .max) < ($1.slotRanges.first?.lowerBound ?? .max) }
    }

    func replicas(of master: ClusterNodeInfo) -> [ClusterNodeInfo] {
        nodes.filter { $0.masterID == master.id }.sorted { ($0.endpoint?.description ?? "") < ($1.endpoint?.description ?? "") }
    }

    var coveredSlots: Int { masters.reduce(0) { $0 + $1.slotCount } }
}

struct ClusterView: View {
    @Bindable var model: ClusterModel
    private static let palette: [Color] = [.red, .teal, .orange, .purple, .blue, .pink, .green, .indigo, .mint, .brown]

    var body: some View {
        if !model.isCluster {
            UnavailableView(title: "Not a cluster", reason: "This connection is \(model.workspace.deployment.displayName.lowercased()). The cluster view needs Redis Cluster.",
                            systemImage: "circle.hexagongrid")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Cluster").font(.title2.weight(.semibold))
                        Badge(text: model.info["cluster_state"] == "ok" ? "state ok" : "state \(model.info["cluster_state"] ?? "?")",
                              color: model.info["cluster_state"] == "ok" ? .green : .red, systemImage: "heart.fill")
                        Spacer()
                        if model.isLoading { ProgressView().controlSize(.small) }
                        Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    }
                    if let error = model.error { ErrorBanner(message: error) }
                    summary
                    coverage
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(Array(model.masters.enumerated()), id: \.element.id) { index, master in
                            masterCard(master, color: Self.palette[index % Self.palette.count])
                        }
                    }
                    let orphans = model.nodes.filter { node in node.role != .master && !model.masters.contains { $0.id == node.masterID } }
                    if !orphans.isEmpty {
                        Card(title: "Other nodes", systemImage: "questionmark.circle") {
                            ForEach(orphans) { node in nodeRow(node) }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            StatTile(title: "Masters", value: "\(model.masters.count)", systemImage: "crown", tint: .orange)
            StatTile(title: "Replicas", value: "\(model.nodes.filter { $0.role == .replica }.count)", systemImage: "doc.on.doc", tint: .teal)
            StatTile(title: "Slots assigned", value: "\(model.info["cluster_slots_assigned"] ?? String(model.coveredSlots)) / 16384", systemImage: "square.grid.4x3.fill")
            StatTile(title: "Failing", value: "\(model.nodes.filter(\.isFailing).count)", systemImage: "exclamationmark.triangle", tint: .red)
            StatTile(title: "Epoch", value: model.info["cluster_current_epoch"] ?? "—", systemImage: "number", tint: .gray)
        }
    }

    private var coverage: some View {
        Card(title: "Slot coverage", systemImage: "rectangle.split.3x1") {
            Canvas { context, size in
                let scale = size.width / 16384
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red.opacity(0.18)))
                for (index, master) in model.masters.enumerated() {
                    for range in master.slotRanges {
                        let rect = CGRect(x: CGFloat(range.lowerBound) * scale, y: 0, width: max(1, CGFloat(range.count) * scale), height: size.height)
                        context.fill(Path(rect), with: .color(Self.palette[index % Self.palette.count].opacity(0.75)))
                    }
                }
            }
            .frame(height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack {
                Text("0").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(model.coveredSlots == 16384 ? "all 16384 slots covered" : "\(16384 - model.coveredSlots) slots uncovered")
                    .font(.caption).foregroundStyle(model.coveredSlots == 16384 ? Color.secondary : Color.red)
                Spacer()
                Text("16383").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func masterCard(_ master: ClusterNodeInfo, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(master.endpoint?.description ?? "(no address)").font(.headline.monospaced())
                    Text(String(master.id.prefix(12))).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
                Badge(text: "master", color: .orange, systemImage: "crown.fill")
                if master.isFailing { Badge(text: "failing", color: .red) }
            }
            Text(master.slotRanges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
                 + "  ·  \(master.slotCount) slots")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !master.migratingSlots.isEmpty || !master.importingSlots.isEmpty {
                Text("migrating \(master.migratingSlots.count) · importing \(master.importingSlots.count) slots").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            let replicas = model.replicas(of: master)
            if replicas.isEmpty {
                Label("No replicas", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            ForEach(replicas) { replica in nodeRow(replica) }
        }
        .padding(Theme.Metrics.cardPadding)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }

    private func nodeRow(_ node: ClusterNodeInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.role == .replica ? "arrow.turn.down.right" : "circle")
                .foregroundStyle(.secondary)
            Text(node.endpoint?.description ?? "(no address)").font(.callout.monospaced())
            Spacer()
            Circle().fill(node.isConnected && !node.isFailing ? Color.green : Color.red).frame(width: 7, height: 7)
            Text(node.isFailing ? "failing" : node.linkState).font(.caption).foregroundStyle(.secondary)
            if node.isMyself { Badge(text: "seed", color: .blue) }
        }
    }
}
