import Foundation

/// How the client reaches the data.
public enum Deployment: Sendable, Hashable {
    case standalone
    /// Directly connected to a replica (read-only).
    case replica
    /// Master (or replica) resolved through Sentinel.
    case sentinel(masterName: String)
    case cluster
    case proxy(ProxyFlavor)

    public var displayName: String {
        switch self {
        case .standalone: "Standalone"
        case .replica: "Replica"
        case .sentinel: "Sentinel"
        case .cluster: "Cluster"
        case let .proxy(flavor): flavor == .unknown ? "Proxy" : "Proxy · \(flavor.displayName)"
        }
    }

    public var isProxy: Bool { if case .proxy = self { true } else { false } }
    public var isCluster: Bool { self == .cluster }
}

public enum ProxyFlavor: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case twemproxy
    case codis
    case predixy
    case envoy
    case cloud
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .twemproxy: "twemproxy"
        case .codis: "Codis"
        case .predixy: "Predixy"
        case .envoy: "Envoy"
        case .cloud: "cloud proxy"
        case .unknown: "proxy"
        }
    }
}

/// Whether one feature can be used, and if not, why (shown verbatim in the UI).
public struct Capability: Sendable, Equatable {
    public var isAvailable: Bool
    public var reason: String?

    public static let available = Capability(isAvailable: true, reason: nil)
    public static func unavailable(_ reason: String) -> Capability { Capability(isAvailable: false, reason: reason) }
}

/// One flag per feature the UI depends on (design D5). Derived from the version table, then refined
/// by the server's command list and by errors observed at runtime.
public struct Capabilities: Sendable, Equatable {
    public enum Feature: String, CaseIterable, Sendable {
        case info, scan, scanType, keys, dbsize, select, unlink, memoryUsage, memoryStats, objectEncoding, objectFreq
        case streams, streamGroupLag, resp3, acl, clientTracking, clusterShards, functions, commandInfo, commandDocs
        case config, clientList, clientKill, clientKillByID, slowlog, slowlogClientInfo, pubsub, pubsubIntrospection
        case shardedPubSub, latency, modules, getdel, copy, lpos, zrangeUnified, setKeepTTL, expireTime, hashFieldTTL
        case xautoclaim, role, monitor, flushAsync, rename

        public var title: String {
            switch self {
            case .info: "Server statistics (INFO)"
            case .scan: "Key scanning (SCAN)"
            case .scanType: "Server-side type filter (SCAN TYPE)"
            case .keys: "KEYS"
            case .dbsize: "Key count (DBSIZE)"
            case .select: "Database selection (SELECT)"
            case .unlink: "Non-blocking delete (UNLINK)"
            case .memoryUsage: "Memory usage per key (MEMORY USAGE)"
            case .memoryStats: "MEMORY STATS"
            case .objectEncoding: "Encoding (OBJECT ENCODING)"
            case .objectFreq: "Access frequency (OBJECT FREQ)"
            case .streams: "Streams"
            case .streamGroupLag: "Consumer group lag"
            case .resp3: "RESP3"
            case .acl: "ACL users"
            case .clientTracking: "Client tracking"
            case .clusterShards: "CLUSTER SHARDS"
            case .functions: "Functions"
            case .commandInfo: "Command table (COMMAND)"
            case .commandDocs: "Command docs (COMMAND DOCS)"
            case .config: "Configuration (CONFIG)"
            case .clientList: "Client list (CLIENT LIST)"
            case .clientKill: "Kill clients (CLIENT KILL)"
            case .clientKillByID: "CLIENT KILL ID"
            case .slowlog: "Slow log (SLOWLOG)"
            case .slowlogClientInfo: "Client address in slow log"
            case .pubsub: "Pub/Sub"
            case .pubsubIntrospection: "Channel list (PUBSUB)"
            case .shardedPubSub: "Sharded Pub/Sub"
            case .latency: "Latency monitor"
            case .modules: "Modules (MODULE LIST)"
            case .getdel: "GETDEL"
            case .copy: "COPY"
            case .lpos: "LPOS"
            case .zrangeUnified: "Unified ZRANGE"
            case .setKeepTTL: "SET … KEEPTTL"
            case .expireTime: "EXPIRETIME"
            case .hashFieldTTL: "Hash field expiration"
            case .xautoclaim: "XAUTOCLAIM"
            case .role: "ROLE"
            case .monitor: "MONITOR"
            case .flushAsync: "FLUSHDB ASYNC"
            case .rename: "RENAME"
            }
        }

        /// First Redis version with the feature.
        var minimumRedis: ServerVersion? {
            switch self {
            case .scan: ServerVersion(2, 8, 0)
            case .scanType: ServerVersion(6, 0, 0)
            case .unlink, .memoryUsage, .memoryStats, .objectFreq, .modules, .flushAsync: ServerVersion(4, 0, 0)
            case .objectEncoding: ServerVersion(2, 2, 3)
            case .streams: ServerVersion(5, 0, 0)
            case .streamGroupLag, .clusterShards, .functions, .commandDocs, .expireTime, .shardedPubSub: ServerVersion(7, 0, 0)
            case .resp3, .acl, .clientTracking, .setKeepTTL: ServerVersion(6, 0, 0)
            case .commandInfo, .latency: ServerVersion(2, 8, 13)
            case .clientKillByID, .role: ServerVersion(2, 8, 12)
            case .slowlog: ServerVersion(2, 2, 12)
            case .slowlogClientInfo: ServerVersion(4, 0, 0)
            case .pubsubIntrospection: ServerVersion(2, 8, 0)
            case .getdel, .copy, .zrangeUnified, .xautoclaim: ServerVersion(6, 2, 0)
            case .lpos: ServerVersion(6, 0, 6)
            case .hashFieldTTL: ServerVersion(7, 4, 0)
            default: nil
            }
        }

        /// First Valkey version, for features Redis added after the fork (7.2.4).
        var minimumValkey: ServerVersion? {
            switch self {
            case .hashFieldTTL: ServerVersion(9, 0, 0)
            default: minimumRedis.map { $0 <= ServerVersion(7, 2, 4) ? ServerVersion(7, 2, 0) : ServerVersion(99, 0, 0) }
            }
        }

        /// Command whose presence in `COMMAND` proves the feature (nil = cannot be told from the list).
        var probeCommand: String? {
            switch self {
            case .info: "info"
            case .scan: "scan"
            case .keys: "keys"
            case .dbsize: "dbsize"
            case .select: "select"
            case .unlink: "unlink"
            case .memoryUsage, .memoryStats: "memory"
            case .objectEncoding, .objectFreq: "object"
            case .streams, .streamGroupLag: "xadd"
            case .acl: "acl"
            case .functions: "function"
            case .config: "config"
            case .clientList, .clientKill, .clientKillByID, .clientTracking: "client"
            case .slowlog, .slowlogClientInfo: "slowlog"
            case .pubsub: "subscribe"
            case .pubsubIntrospection: "pubsub"
            case .shardedPubSub: "ssubscribe"
            case .latency: "latency"
            case .modules: "module"
            case .getdel: "getdel"
            case .copy: "copy"
            case .lpos: "lpos"
            case .expireTime: "expiretime"
            case .hashFieldTTL: "hexpire"
            case .xautoclaim: "xautoclaim"
            case .role: "role"
            case .monitor: "monitor"
            case .rename: "rename"
            case .resp3: "hello"
            default: nil
            }
        }

        /// Features proxies typically refuse until a probe proves otherwise.
        var restrictedByProxies: Bool {
            switch self {
            case .info, .scan, .scanType, .keys, .dbsize, .select, .config, .clientList, .clientKill, .clientKillByID,
                 .slowlog, .slowlogClientInfo, .pubsub, .pubsubIntrospection, .shardedPubSub, .latency, .modules, .acl,
                 .functions, .commandInfo, .commandDocs, .monitor, .memoryStats, .clientTracking, .clusterShards, .role,
                 .resp3, .memoryUsage, .objectEncoding, .objectFreq, .rename, .flushAsync:
                true
            default:
                false
            }
        }
    }

    private var table: [Feature: Capability]

    public init(table: [Feature: Capability] = [:]) {
        self.table = table
    }

    public subscript(feature: Feature) -> Capability { table[feature] ?? .available }

    public func supports(_ feature: Feature) -> Bool { self[feature].isAvailable }

    /// Unavailable features with their reasons, in declaration order.
    public var unavailable: [(feature: Feature, reason: String)] {
        Feature.allCases.compactMap { feature in
            let capability = self[feature]
            return capability.isAvailable ? nil : (feature, capability.reason ?? "Not available")
        }
    }

    public static func derive(server: ServerInfo, deployment: Deployment = .standalone) -> Capabilities {
        var table: [Feature: Capability] = [:]
        for feature in Feature.allCases {
            table[feature] = versionCapability(feature, server: server)
        }
        switch deployment {
        case let .proxy(flavor):
            for feature in Feature.allCases where feature.restrictedByProxies {
                table[feature] = .unavailable("Not available through \(flavor == .unknown ? "this proxy" : flavor.displayName): it does not forward \(feature.title).")
            }
        case .cluster:
            table[.select] = .unavailable("Redis Cluster only has database 0.")
        default:
            break
        }
        return Capabilities(table: table)
    }

    private static func versionCapability(_ feature: Feature, server: ServerInfo) -> Capability {
        guard let version = server.version else { return .available }
        let minimum: ServerVersion?
        switch server.family {
        case .valkey: minimum = feature.minimumValkey
        default: minimum = feature.minimumRedis
        }
        guard let minimum, version < minimum else { return .available }
        let family = server.family == .valkey ? "Valkey" : "Redis"
        let shown = minimum.major >= 99 ? "a later \(family) release" : "\(family) \(minimum.shortDescription) or later"
        return .unavailable("Requires \(shown) (server is \(server.displayName)).")
    }

    /// Refines availability with the server's command names (lower-case), e.g. from `COMMAND LIST`.
    /// Commands absent from the list are renamed or disabled (`rename-command`, managed services).
    public mutating func apply(commandNames: Set<String>) {
        guard !commandNames.isEmpty else { return }
        let names = Set(commandNames.map { $0.lowercased() })
        for feature in Feature.allCases {
            guard let command = feature.probeCommand else { continue }
            if !names.contains(command) {
                if self[feature].isAvailable {
                    table[feature] = .unavailable("\(command.uppercased()) is renamed or disabled on this server.")
                }
            }
        }
    }

    public mutating func markUnavailable(_ feature: Feature, reason: String) {
        table[feature] = .unavailable(reason)
    }

    public mutating func markAvailable(_ feature: Feature) {
        table[feature] = .available
    }
}
