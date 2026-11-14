import CcinnRedisKit
import Foundation
import Observation
import RedisKit

/// Editable copy of a connection profile plus its secrets, with "Test connection".
@MainActor
@Observable
final class ConnectionDraft {
    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    let profileID: UUID?
    var profile: ConnectionProfile
    var password: String
    var sentinelPassword: String
    var sshSecret: String
    var tlsCertificatePassword: String
    var tlsEnabled: Bool
    var tls: TLSOptions
    var sshEnabled: Bool
    var ssh: SSHTunnelConfiguration
    var testState: TestState = .idle

    private var testTask: Task<Void, Never>?

    init(profile existing: ConnectionProfile?, store: ProfileStore) {
        profileID = existing?.id
        let base = existing ?? ConnectionProfile(color: .red)
        profile = base
        let secrets = existing.map(store.secrets(for:)) ?? ProfileSecrets()
        password = secrets.password ?? ""
        sentinelPassword = secrets.sentinelPassword ?? ""
        sshSecret = secrets.sshSecret ?? ""
        tlsCertificatePassword = secrets.tlsCertificatePassword ?? ""
        tlsEnabled = base.tls != nil
        tls = base.tls ?? TLSOptions()
        sshEnabled = base.ssh != nil
        ssh = base.ssh ?? SSHTunnelConfiguration(host: "", username: NSUserName(), authentication: .agent)
    }

    /// Fills the form from a pasted URI.
    func apply(uri: String) throws {
        let parsed = try ConnectionURI.parse(uri)
        var imported = parsed.profile
        imported.id = profile.id
        imported.color = profile.color
        imported.createdAt = profile.createdAt
        if imported.name.isEmpty { imported.name = profile.name }
        profile = imported
        password = parsed.password ?? ""
        tlsEnabled = imported.tls != nil
        tls = imported.tls ?? TLSOptions()
    }

    func makeProfile() -> ConnectionProfile {
        var result = profile
        result.name = result.name.trimmingCharacters(in: .whitespaces)
        result.host = result.host.trimmingCharacters(in: .whitespaces)
        result.username = result.username.trimmingCharacters(in: .whitespaces)
        result.tls = tlsEnabled ? tls : nil
        result.ssh = sshEnabled ? ssh : nil
        result.connectTimeout = min(max(result.connectTimeout, 1), 120)
        result.commandTimeout = min(max(result.commandTimeout, 1), 600)
        if result.mode == .cluster { result.database = 0 }
        return result
    }

    var secrets: ProfileSecrets {
        ProfileSecrets(password: password, sentinelPassword: profile.mode == .sentinel ? sentinelPassword : nil,
                       sshSecret: sshEnabled ? sshSecret : nil, tlsCertificatePassword: tlsEnabled ? tlsCertificatePassword : nil)
    }

    var validationErrors: [String] { makeProfile().validationErrors }
    var isValid: Bool { validationErrors.isEmpty }

    func test() {
        testTask?.cancel()
        let profile = makeProfile()
        let secrets = secrets
        testState = .running("Connecting…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in
                if case .running = self.testState { self.testState = .running(status) }
            }
        }
        testTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, secrets: secrets, progress: report)
                var parts = [client.serverInfo.displayName, client.deployment.displayName, "RESP\(client.protocolVersion)"]
                if client.deployment.isCluster {
                    let map = client.slotMap
                    parts.append("\(map.shards.count) masters, \(map.shards.reduce(0) { $0 + $1.replicas.count }) replicas")
                }
                if client.capabilities.supports(.dbsize), let keys = try? await client.dbSize() {
                    parts.append("\(keys.formatted()) keys")
                }
                if client.isReadOnly { parts.append("read-only") }
                if case .proxy = client.deployment { parts.append("\(client.capabilities.unavailable.count) features unavailable through the proxy") }
                await client.close()
                guard !Task.isCancelled else { return }
                testState = .succeeded("Connected: " + parts.joined(separator: " · "))
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}
