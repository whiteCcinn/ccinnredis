import Foundation
import os
import RedisKit
import Security

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

public enum DeploymentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standalone, sentinel, cluster
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standalone: "Standalone / Replica / Proxy"
        case .sentinel: "Sentinel"
        case .cluster: "Cluster"
        }
    }
}

/// What the user says about a proxy in front of the server.
public enum ProxyChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, twemproxy, codis, predixy, envoy, cloud, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Detect automatically"
        case .twemproxy: "twemproxy / nutcracker"
        case .codis: "Codis"
        case .predixy: "Predixy"
        case .envoy: "Envoy"
        case .cloud: "Cloud proxy (Aliyun, Tencent, AWS…)"
        case .other: "Other proxy"
        }
    }

    var hint: ClientConfiguration.ProxyHint {
        switch self {
        case .auto: .auto
        case .twemproxy: .proxy(.twemproxy)
        case .codis: .proxy(.codis)
        case .predixy: .proxy(.predixy)
        case .envoy: .proxy(.envoy)
        case .cloud: .proxy(.cloud)
        case .other: .proxy(.unknown)
        }
    }
}

/// Whether AI clients may use a profile through the MCP server (opt-in per profile).
public enum MCPAccess: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case disabled
    case readOnly
    case readWrite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled: "Disabled"
        case .readOnly: "Read-only"
        case .readWrite: "Read & write"
        }
    }

    private var rank: Int {
        switch self {
        case .disabled: 0
        case .readOnly: 1
        case .readWrite: 2
        }
    }

    public static func < (lhs: MCPAccess, rhs: MCPAccess) -> Bool { lhs.rank < rhs.rank }
}

/// A saved connection. Never contains secrets: those live in a `SecretStore` (the Keychain).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var isFavorite: Bool
    public var mode: DeploymentMode
    public var host: String
    public var port: Int
    public var useUnixSocket: Bool
    public var sentinelNodes: String
    public var sentinelMasterName: String
    public var sentinelRole: ClientConfiguration.SentinelRole
    public var sentinelUsername: String
    public var clusterSeeds: String
    public var scanReplicas: Bool
    public var addressMapText: String
    public var proxy: ProxyChoice
    public var username: String
    public var database: Int
    public var protocolPreference: ProtocolPreference
    public var tls: TLSOptions?
    public var ssh: SSHTunnelConfiguration?
    public var readOnly: Bool
    /// Key-tree grouping delimiter.
    public var delimiter: String
    /// AI access through `CcinnRedis mcp` (default: disabled).
    public var mcpAccess: MCPAccess
    public var connectTimeout: Double
    public var commandTimeout: Double
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), name: String = "", host: String = "127.0.0.1", port: Int = 6379, color: ProfileColor = .none,
                mode: DeploymentMode = .standalone) {
        self.id = id
        self.name = name
        self.color = color
        isFavorite = false
        self.mode = mode
        self.host = host
        self.port = port
        useUnixSocket = false
        sentinelNodes = ""
        sentinelMasterName = ""
        sentinelRole = .master
        sentinelUsername = ""
        clusterSeeds = ""
        scanReplicas = false
        addressMapText = ""
        proxy = .auto
        username = ""
        database = 0
        protocolPreference = .auto
        tls = nil
        ssh = nil
        readOnly = false
        delimiter = ":"
        mcpAccess = .disabled
        connectTimeout = 10
        commandTimeout = 30
        createdAt = Date()
        lastConnectedAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, isFavorite, mode, host, port, useUnixSocket, sentinelNodes, sentinelMasterName, sentinelRole
        case sentinelUsername, clusterSeeds, scanReplicas, addressMapText, proxy, username, database, protocolPreference
        case tls, ssh, readOnly, delimiter, mcpAccess, connectTimeout, commandTimeout, createdAt, lastConnectedAt
    }

    /// Tolerant decoding: fields added in later versions get defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id))
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? container.decodeIfPresent(ProfileColor.self, forKey: .color)) ?? .none
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        mode = (try? container.decodeIfPresent(DeploymentMode.self, forKey: .mode)) ?? .standalone
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 6379
        useUnixSocket = try container.decodeIfPresent(Bool.self, forKey: .useUnixSocket) ?? false
        sentinelNodes = try container.decodeIfPresent(String.self, forKey: .sentinelNodes) ?? ""
        sentinelMasterName = try container.decodeIfPresent(String.self, forKey: .sentinelMasterName) ?? ""
        sentinelRole = (try? container.decodeIfPresent(ClientConfiguration.SentinelRole.self, forKey: .sentinelRole)) ?? .master
        sentinelUsername = try container.decodeIfPresent(String.self, forKey: .sentinelUsername) ?? ""
        clusterSeeds = try container.decodeIfPresent(String.self, forKey: .clusterSeeds) ?? ""
        scanReplicas = try container.decodeIfPresent(Bool.self, forKey: .scanReplicas) ?? false
        addressMapText = try container.decodeIfPresent(String.self, forKey: .addressMapText) ?? ""
        proxy = (try? container.decodeIfPresent(ProxyChoice.self, forKey: .proxy)) ?? .auto
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        database = try container.decodeIfPresent(Int.self, forKey: .database) ?? 0
        protocolPreference = (try? container.decodeIfPresent(ProtocolPreference.self, forKey: .protocolPreference)) ?? .auto
        tls = try container.decodeIfPresent(TLSOptions.self, forKey: .tls)
        ssh = try container.decodeIfPresent(SSHTunnelConfiguration.self, forKey: .ssh)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        delimiter = try container.decodeIfPresent(String.self, forKey: .delimiter) ?? ":"
        mcpAccess = (try? container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess)) ?? .disabled
        connectTimeout = try container.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 10
        commandTimeout = try container.decodeIfPresent(Double.self, forKey: .commandTimeout) ?? 30
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public static func recents(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    public var endpoint: Endpoint {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return useUnixSocket ? .unixSocket(trimmed) : Endpoint(host: trimmed, port: port)
    }

    public var sentinelEndpoints: [Endpoint] { Self.endpoints(in: sentinelNodes, defaultPort: 26379) }
    public var clusterEndpoints: [Endpoint] { Self.endpoints(in: clusterSeeds, defaultPort: 6379) }

    public static func endpoints(in text: String, defaultPort: Int) -> [Endpoint] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { Endpoint.parse(String($0), defaultPort: defaultPort) }
    }

    public var hostSummary: String {
        var base: String
        switch mode {
        case .standalone: base = endpoint.description
        case .sentinel: base = "\(sentinelMasterName.isEmpty ? "?" : sentinelMasterName) via \(sentinelEndpoints.count) sentinel\(sentinelEndpoints.count == 1 ? "" : "s")"
        case .cluster: base = "cluster · \(clusterEndpoints.first?.description ?? "no seeds")"
        }
        if !username.isEmpty { base = "\(username)@" + base }
        if database != 0, mode != .cluster { base += " /\(database)" }
        if let ssh { base += " via \(ssh.host)" }
        return base
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        switch mode {
        case .standalone: return endpoint.description
        case .sentinel: return sentinelMasterName.isEmpty ? "Sentinel" : sentinelMasterName
        case .cluster: return clusterEndpoints.first.map { "Cluster \($0)" } ?? "Cluster"
        }
    }

    /// Problems that prevent connecting, for inline form validation.
    public var validationErrors: [String] {
        var errors: [String] = []
        switch mode {
        case .standalone:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(useUnixSocket ? "Enter the socket path" : "Enter the host") }
            if useUnixSocket, !host.hasPrefix("/"), !host.hasPrefix("~/") { errors.append("The socket path must be absolute") }
            if !useUnixSocket, !(1...65_535).contains(port) { errors.append("Port must be between 1 and 65535") }
        case .sentinel:
            if sentinelMasterName.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the master name monitored by Sentinel") }
            if sentinelEndpoints.isEmpty { errors.append("Add at least one sentinel address (host:port)") }
        case .cluster:
            if clusterEndpoints.isEmpty { errors.append("Add at least one cluster seed node (host:port)") }
            if database != 0 { errors.append("Redis Cluster only has database 0") }
        }
        if !(0...100_000).contains(database) { errors.append("Database index must be 0 or more") }
        if (try? AddressMap(rules: addressMapText)) == nil { errors.append("Address map: use one 'from => to' rule per line") }
        if let ssh {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the SSH host") }
            if ssh.authentication == .privateKey, (ssh.privateKeyPath ?? "").isEmpty { errors.append("Choose an SSH private key") }
        }
        return errors
    }

    public func clientConfiguration(secrets: ProfileSecrets) throws -> ClientConfiguration {
        let mode: ClientConfiguration.Mode
        switch self.mode {
        case .standalone: mode = .standalone(endpoint)
        case .sentinel:
            mode = .sentinel(sentinels: sentinelEndpoints, masterName: sentinelMasterName.trimmingCharacters(in: .whitespaces), role: sentinelRole)
        case .cluster: mode = .cluster(seeds: clusterEndpoints)
        }
        return ClientConfiguration(
            mode: mode,
            credentials: Credentials(username: username, password: secrets.password),
            sentinelCredentials: Credentials(username: sentinelUsername, password: secrets.sentinelPassword),
            database: self.mode == .cluster ? 0 : database,
            protocolPreference: protocolPreference,
            tls: tls,
            clientCertificatePassword: secrets.tlsCertificatePassword,
            ssh: ssh,
            sshSecret: secrets.sshSecret,
            addressMap: try AddressMap(rules: addressMapText),
            connectTimeout: min(max(connectTimeout, 1), 120),
            commandTimeout: min(max(commandTimeout, 1), 600),
            readOnly: readOnly,
            proxyHint: proxy.hint,
            scanReplicas: scanReplicas
        )
    }
}

/// Secrets of one profile (Keychain only).
public struct ProfileSecrets: Sendable, Equatable {
    public var password: String?
    public var sentinelPassword: String?
    public var sshSecret: String?
    public var tlsCertificatePassword: String?

    public init(password: String? = nil, sentinelPassword: String? = nil, sshSecret: String? = nil, tlsCertificatePassword: String? = nil) {
        self.password = password
        self.sentinelPassword = sentinelPassword
        self.sshSecret = sshSecret
        self.tlsCertificatePassword = tlsCertificatePassword
    }

    /// The secrets a client was opened with (`ConnectionProfile.clientConfiguration(secrets:)` in reverse).
    public init(configuration: ClientConfiguration) {
        self.init(password: configuration.credentials.password, sentinelPassword: configuration.sentinelCredentials.password,
                  sshSecret: configuration.sshSecret, tlsCertificatePassword: configuration.clientCertificatePassword)
    }
}

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case password
        case sentinelPassword
        case sshSecret
        case tlsCertificatePassword
    }

    public let profileID: UUID
    public let kind: Kind

    public init(profileID: UUID, kind: Kind) {
        self.profileID = profileID
        self.kind = kind
    }

    var account: String { "\(profileID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil or empty.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnredis.connections") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError(message: "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnRedis connection secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(message: "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw SecretStoreError(message: "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value?.isEmpty == false ? value : nil }
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secretStore: any SecretStore

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnRedis", isDirectory: true)
    }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = KeychainSecretStore()) {
        self.directory = directory
        secretStore = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
    }

    public func storeSecrets(for profile: ConnectionProfile, secrets: ProfileSecrets) throws {
        try secretStore.setSecret(secrets.password, for: SecretKey(profileID: profile.id, kind: .password))
        try secretStore.setSecret(secrets.sentinelPassword, for: SecretKey(profileID: profile.id, kind: .sentinelPassword))
        try secretStore.setSecret(secrets.sshSecret, for: SecretKey(profileID: profile.id, kind: .sshSecret))
        try secretStore.setSecret(secrets.tlsCertificatePassword, for: SecretKey(profileID: profile.id, kind: .tlsCertificatePassword))
    }

    public func secrets(for profile: ConnectionProfile) -> ProfileSecrets {
        func read(_ kind: SecretKey.Kind) -> String? { try? secretStore.secret(for: SecretKey(profileID: profile.id, kind: kind)) }
        return ProfileSecrets(password: read(.password), sentinelPassword: read(.sentinelPassword), sshSecret: read(.sshSecret),
                              tlsCertificatePassword: read(.tlsCertificatePassword))
    }

    public func delete(_ profile: ConnectionProfile) throws {
        for kind in SecretKey.Kind.allCases {
            try secretStore.setSecret(nil, for: SecretKey(profileID: profile.id, kind: kind))
        }
    }
}
