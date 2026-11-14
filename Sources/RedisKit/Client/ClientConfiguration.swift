import Foundation
import RESPWire

/// Everything needed to reach a deployment.
public struct ClientConfiguration: Sendable {
    public enum SentinelRole: String, Sendable, Codable, CaseIterable, Identifiable {
        case master, replica
        public var id: String { rawValue }
    }

    public enum Mode: Sendable, Equatable {
        case standalone(Endpoint)
        case sentinel(sentinels: [Endpoint], masterName: String, role: SentinelRole)
        case cluster(seeds: [Endpoint])
    }

    /// What the user told us about proxies.
    public enum ProxyHint: Sendable, Equatable {
        /// Detect from behaviour.
        case auto
        /// Behind a proxy of this flavor (probes still refine what works).
        case proxy(ProxyFlavor)
    }

    public var mode: Mode
    public var credentials: Credentials
    /// Credentials of the sentinels themselves (Sentinel `requirepass` / ACL).
    public var sentinelCredentials: Credentials
    public var database: Int
    public var protocolPreference: ProtocolPreference
    public var tls: TLSOptions?
    public var clientCertificatePassword: String?
    public var ssh: SSHTunnelConfiguration?
    public var sshSecret: String?
    public var addressMap: AddressMap
    public var connectTimeout: Double
    /// Per-command reply timeout (blocking console commands use their own connection without it).
    public var commandTimeout: Double
    /// Block write commands before they are sent.
    public var readOnly: Bool
    public var proxyHint: ProxyHint
    /// In a cluster, scan replicas instead of masters (offloads production masters).
    public var scanReplicas: Bool
    public var poolSize: Int
    public var clientName: String?
    public var limits: RESPLimits

    public init(mode: Mode, credentials: Credentials = Credentials(), sentinelCredentials: Credentials = Credentials(),
                database: Int = 0, protocolPreference: ProtocolPreference = .auto, tls: TLSOptions? = nil,
                clientCertificatePassword: String? = nil, ssh: SSHTunnelConfiguration? = nil, sshSecret: String? = nil,
                addressMap: AddressMap = AddressMap(), connectTimeout: Double = 10, commandTimeout: Double = 30,
                readOnly: Bool = false, proxyHint: ProxyHint = .auto, scanReplicas: Bool = false, poolSize: Int = 4,
                clientName: String? = "ccinnredis", limits: RESPLimits = RESPLimits()) {
        self.mode = mode
        self.credentials = credentials
        self.sentinelCredentials = sentinelCredentials
        self.database = max(0, database)
        self.protocolPreference = protocolPreference
        self.tls = tls
        self.clientCertificatePassword = clientCertificatePassword
        self.ssh = ssh
        self.sshSecret = sshSecret
        self.addressMap = addressMap
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        self.readOnly = readOnly
        self.proxyHint = proxyHint
        self.scanReplicas = scanReplicas
        self.poolSize = max(1, poolSize)
        self.clientName = clientName
        self.limits = limits
    }

    var basePlan: HandshakePlan {
        HandshakePlan(credentials: credentials, protocolPreference: protocolPreference, database: database, clientName: clientName,
                      sendHello: protocolPreference != .resp2)
    }
}
