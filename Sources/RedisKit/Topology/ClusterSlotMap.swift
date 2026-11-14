import Foundation
import RESPWire

/// A cluster node as announced by the cluster (before any address mapping).
public struct ClusterNodeAddress: Sendable, Hashable {
    public var id: String?
    public var endpoint: Endpoint
    public var hostname: String?
    /// `online`, `failed`, `loading` (CLUSTER SHARDS) when known.
    public var health: String?

    public init(id: String? = nil, endpoint: Endpoint, hostname: String? = nil, health: String? = nil) {
        self.id = id
        self.endpoint = endpoint
        self.hostname = hostname
        self.health = health
    }
}

public struct ClusterShard: Sendable, Hashable {
    public var master: ClusterNodeAddress
    public var replicas: [ClusterNodeAddress]
    public var ranges: [ClosedRange<Int>]

    public var slotCount: Int { ranges.reduce(0) { $0 + $1.count } }

    public init(master: ClusterNodeAddress, replicas: [ClusterNodeAddress], ranges: [ClosedRange<Int>]) {
        self.master = master
        self.replicas = replicas
        self.ranges = ClusterSlotMap.merged(ranges)
    }
}

/// Slot → owning shard (design D7).
public struct ClusterSlotMap: Sendable {
    public let shards: [ClusterShard]
    /// Shard index per slot, -1 when uncovered.
    private let owners: [Int16]

    public init(shards: [ClusterShard]) {
        var merged: [ClusterShard] = []
        for shard in shards {
            if let index = merged.firstIndex(where: { $0.master.endpoint == shard.master.endpoint }) {
                merged[index].ranges += shard.ranges
                for replica in shard.replicas where !merged[index].replicas.contains(where: { $0.endpoint == replica.endpoint }) {
                    merged[index].replicas.append(replica)
                }
            } else {
                merged.append(shard)
            }
        }
        var owners = [Int16](repeating: -1, count: HashSlot.count)
        for (index, shard) in merged.enumerated() {
            for range in shard.ranges {
                let lower = max(0, range.lowerBound)
                let upper = min(HashSlot.count - 1, range.upperBound)
                guard lower <= upper else { continue }
                for slot in lower...upper { owners[slot] = Int16(clamping: index) }
            }
        }
        self.shards = merged
        self.owners = owners
    }

    public static let empty = ClusterSlotMap(shards: [])

    public var masters: [ClusterNodeAddress] { shards.map(\.master) }

    public func shardIndex(forSlot slot: Int) -> Int? {
        guard owners.indices.contains(slot) else { return nil }
        let owner = Int(owners[slot])
        return owner >= 0 ? owner : nil
    }

    public func master(forSlot slot: Int) -> ClusterNodeAddress? {
        shardIndex(forSlot: slot).map { shards[$0].master }
    }

    public func replicas(ofMasterAt endpoint: Endpoint) -> [ClusterNodeAddress] {
        shards.first { $0.master.endpoint == endpoint }?.replicas ?? []
    }

    public var uncoveredSlotCount: Int { owners.reduce(0) { $0 + ($1 < 0 ? 1 : 0) } }
    public var isFullyCovered: Bool { uncoveredSlotCount == 0 }

    /// Every distinct node (masters first).
    public var allNodes: [ClusterNodeAddress] { shards.map(\.master) + shards.flatMap(\.replicas) }

    /// Applies a `MOVED` redirect: the slot now belongs to `endpoint`.
    public func reassigning(slot: Int, to endpoint: Endpoint) -> ClusterSlotMap {
        var shards = self.shards
        for index in shards.indices {
            shards[index].ranges = shards[index].ranges.flatMap { range -> [ClosedRange<Int>] in
                guard range.contains(slot) else { return [range] }
                var parts: [ClosedRange<Int>] = []
                if range.lowerBound < slot { parts.append(range.lowerBound...(slot - 1)) }
                if slot < range.upperBound { parts.append((slot + 1)...range.upperBound) }
                return parts
            }
        }
        if let target = shards.firstIndex(where: { $0.master.endpoint == endpoint }) {
            shards[target].ranges.append(slot...slot)
        } else {
            shards.append(ClusterShard(master: ClusterNodeAddress(endpoint: endpoint), replicas: [], ranges: [slot...slot]))
        }
        return ClusterSlotMap(shards: shards)
    }

    // MARK: Parsing

    /// `CLUSTER SLOTS` (3.0+): `[[start, end, [host, port, id, …], replicas…], …]`.
    public init(clusterSlots reply: RESPValue, queriedNode: Endpoint) throws {
        guard let entries = reply.array else { throw RedisError(.protocolViolation, "Unexpected CLUSTER SLOTS reply") }
        var shards: [ClusterShard] = []
        for entry in entries {
            guard let fields = entry.array, fields.count >= 3,
                  let start = fields[0].int, let end = fields[1].int, let range = Self.slotRange(start, end),
                  let master = Self.slotsNode(fields[2], queriedNode: queriedNode) else { continue }
            let replicas = fields.dropFirst(3).compactMap { Self.slotsNode($0, queriedNode: queriedNode) }
            shards.append(ClusterShard(master: master, replicas: replicas, ranges: [range]))
        }
        self.init(shards: shards)
    }

    private static func slotsNode(_ value: RESPValue, queriedNode: Endpoint) -> ClusterNodeAddress? {
        guard let fields = value.array, fields.count >= 2, let port = fields[1].int.flatMap({ Int(exactly: $0) }), port > 0 else { return nil }
        let rawHost = fields[0].string ?? ""
        guard rawHost != "?" else { return nil }
        let host = rawHost.isEmpty ? queriedNode.host : rawHost
        guard let endpoint = Endpoint.announced(host: host, port: port) else { return nil }
        let id = fields.count > 2 ? fields[2].string : nil
        var hostname: String?
        if fields.count > 3 { hostname = fields[3]["hostname"]?.string }
        return ClusterNodeAddress(id: id, endpoint: endpoint, hostname: hostname)
    }

    /// `CLUSTER SHARDS` (7.0+), RESP2 flat arrays or RESP3 maps.
    public init(clusterShards reply: RESPValue, queriedNode: Endpoint, preferTLSPort: Bool = false) throws {
        guard let entries = reply.array else { throw RedisError(.protocolViolation, "Unexpected CLUSTER SHARDS reply") }
        var shards: [ClusterShard] = []
        for entry in entries {
            let slots = (entry["slots"]?.array ?? []).compactMap(\.int)
            var ranges: [ClosedRange<Int>] = []
            var index = 0
            while index + 1 < slots.count {
                if let range = Self.slotRange(slots[index], slots[index + 1]) { ranges.append(range) }
                index += 2
            }
            var master: ClusterNodeAddress?
            var replicas: [ClusterNodeAddress] = []
            for node in entry["nodes"]?.array ?? [] {
                guard let address = Self.shardNode(node, queriedNode: queriedNode, preferTLSPort: preferTLSPort) else { continue }
                if node["role"]?.string == "master" {
                    master = address
                } else {
                    replicas.append(address)
                }
            }
            guard let master else { continue }
            shards.append(ClusterShard(master: master, replicas: replicas, ranges: ranges))
        }
        self.init(shards: shards)
    }

    private static func shardNode(_ node: RESPValue, queriedNode: Endpoint, preferTLSPort: Bool) -> ClusterNodeAddress? {
        let plainPort = node["port"]?.int.flatMap { Int(exactly: $0) }
        let tlsPort = node["tls-port"]?.int.flatMap { Int(exactly: $0) }
        guard let port = (preferTLSPort ? tlsPort ?? plainPort : plainPort ?? tlsPort), port > 0 else { return nil }
        var host = node["endpoint"]?.string ?? ""
        if host.isEmpty || host == "?" { host = node["ip"]?.string ?? "" }
        if host.isEmpty || host == "?" { host = queriedNode.host }
        guard let endpoint = Endpoint.announced(host: host, port: port) else { return nil }
        return ClusterNodeAddress(id: node["id"]?.string, endpoint: endpoint, hostname: node["hostname"]?.string, health: node["health"]?.string)
    }

    /// Sorted, non-overlapping ranges, so slot counts never exceed 16384 even for hostile replies.
    static func merged(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        guard ranges.count > 1 else { return ranges }
        var result: [ClosedRange<Int>] = []
        result.reserveCapacity(ranges.count)
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Slot range clamped to 0...16383, or nil when empty/out of range (never trusts server numbers).
    static func slotRange(_ start: Int64, _ end: Int64) -> ClosedRange<Int>? {
        let maxSlot = Int64(HashSlot.count - 1)
        let lower = max(0, start)
        let upper = min(maxSlot, end)
        guard lower <= upper, lower <= maxSlot else { return nil }
        return Int(lower)...Int(upper)
    }

    /// From parsed `CLUSTER NODES` lines (works on every cluster version).
    public init(clusterNodes nodes: [ClusterNodeInfo]) throws {
        var shards: [ClusterShard] = []
        for node in nodes where node.role == .master && !node.slotRanges.isEmpty {
            guard let endpoint = node.endpoint else { continue }
            let replicas = nodes.filter { $0.role == .replica && $0.masterID == node.id }.compactMap { replica -> ClusterNodeAddress? in
                guard let endpoint = replica.endpoint else { return nil }
                return ClusterNodeAddress(id: replica.id, endpoint: endpoint, hostname: replica.hostname, health: replica.isFailing ? "failed" : "online")
            }
            shards.append(ClusterShard(master: ClusterNodeAddress(id: node.id, endpoint: endpoint, hostname: node.hostname,
                                                                  health: node.isFailing ? "failed" : "online"),
                                       replicas: replicas, ranges: node.slotRanges))
        }
        self.init(shards: shards)
    }
}

/// One line of `CLUSTER NODES`.
public struct ClusterNodeInfo: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, Hashable {
        case master, replica, unknown
    }

    public var id: String
    /// `nil` for `noaddr` nodes.
    public var endpoint: Endpoint?
    public var busPort: Int?
    public var hostname: String?
    public var flags: [String]
    public var role: Role
    public var masterID: String?
    public var pingSent: Int64
    public var pongReceived: Int64
    public var configEpoch: Int64
    public var linkState: String
    public var slotRanges: [ClosedRange<Int>]
    public var migratingSlots: [Int]
    public var importingSlots: [Int]

    public var isMyself: Bool { flags.contains("myself") }
    public var isFailing: Bool { flags.contains("fail") || flags.contains("fail?") }
    public var isConnected: Bool { linkState == "connected" }
    public var slotCount: Int { slotRanges.reduce(0) { $0 + $1.count } }

    public static func parse(clusterNodes text: String, queriedNode: Endpoint) -> [ClusterNodeInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { parse(line: String($0), queriedNode: queriedNode) }
    }

    static func parse(line: String, queriedNode: Endpoint) -> ClusterNodeInfo? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 8 else { return nil }
        let flags = fields[2].split(separator: ",").map(String.init)

        // ip:port@cport[,hostname] — or ip:port before 4.0. IPv6 addresses are not bracketed.
        var addressField = fields[1]
        var hostname: String?
        if let comma = addressField.firstIndex(of: ",") {
            let name = String(addressField[addressField.index(after: comma)...])
            hostname = name.isEmpty ? nil : name
            addressField = String(addressField[..<comma])
        }
        var busPort: Int?
        if let at = addressField.firstIndex(of: "@") {
            busPort = Int(addressField[addressField.index(after: at)...])
            addressField = String(addressField[..<at])
        }
        var endpoint: Endpoint?
        if let colon = addressField.lastIndex(of: ":"), let port = Int(addressField[addressField.index(after: colon)...]), port > 0,
           !flags.contains("noaddr") {
            var host = String(addressField[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if host.isEmpty { host = queriedNode.host }
            endpoint = Endpoint.announced(host: host, port: port)
        }

        let role: Role = flags.contains("master") ? .master : (flags.contains("slave") || flags.contains("replica")) ? .replica : .unknown
        var ranges: [ClosedRange<Int>] = []
        var migrating: [Int] = []
        var importing: [Int] = []
        for token in fields.dropFirst(8) {
            if token.hasPrefix("[") {
                // [slot->-id] migrating, [slot-<-id] importing
                let body = token.dropFirst().prefix { $0.isNumber }
                guard let slot = Int(body), (0..<HashSlot.count).contains(slot) else { continue }
                if token.contains("->-") { migrating.append(slot) } else if token.contains("-<-") { importing.append(slot) }
                continue
            }
            let bounds = token.split(separator: "-", maxSplits: 1).compactMap { Int64($0) }
            if bounds.count == 2, let range = ClusterSlotMap.slotRange(bounds[0], bounds[1]) {
                ranges.append(range)
            } else if bounds.count == 1, !token.contains("-"), let range = ClusterSlotMap.slotRange(bounds[0], bounds[0]) {
                ranges.append(range)
            }
        }
        return ClusterNodeInfo(id: fields[0], endpoint: endpoint, busPort: busPort, hostname: hostname, flags: flags, role: role,
                               masterID: fields[3] == "-" ? nil : fields[3], pingSent: Int64(fields[4]) ?? 0,
                               pongReceived: Int64(fields[5]) ?? 0, configEpoch: Int64(fields[6]) ?? 0, linkState: fields[7],
                               slotRanges: ClusterSlotMap.merged(ranges), migratingSlots: migrating, importingSlots: importing)
    }
}

/// `-MOVED slot host:port` / `-ASK slot host:port`.
public enum Redirect: Sendable, Equatable {
    case moved(slot: Int, Endpoint)
    case ask(slot: Int, Endpoint)

    public init?(message: String, fallbackHost: String? = nil) {
        let parts = message.split(separator: " ")
        guard parts.count >= 3, let slot = Int(parts[1]), (0..<HashSlot.count).contains(slot) else { return nil }
        let address = String(parts[2])
        let endpoint: Endpoint
        if address.hasPrefix(":"), let port = Int(address.dropFirst()), let fallbackHost,
           let fallback = Endpoint.announced(host: fallbackHost, port: port) {
            endpoint = fallback
        } else if let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]), port > 0 {
            var host = String(address[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard let announced = Endpoint.announced(host: host, port: port) else { return nil }
            endpoint = announced
        } else {
            return nil
        }
        switch parts[0].uppercased() {
        case "MOVED": self = .moved(slot: slot, endpoint)
        case "ASK": self = .ask(slot: slot, endpoint)
        default: return nil
        }
    }
}
