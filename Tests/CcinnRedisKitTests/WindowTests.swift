import Foundation
import RedisKit
import Testing
@testable import CcinnRedisKit

@Suite("Window requests")
struct WindowRequestTests {
    @Test func everyRequestOpensItsOwnWindow() {
        let profile = UUID()
        // SwiftUI brings an existing window to the front when the value is equal, so two requests for the same
        // connection must differ.
        #expect(WindowRequest(profileID: profile) != WindowRequest(profileID: profile))
        #expect(WindowRequest(profileID: profile).profileID == profile)
    }

    @Test func roundTripsThroughCodable() throws {
        let request = WindowRequest(profileID: UUID())
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func decodesWithoutTheNonce() throws {
        let profile = UUID()
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"profileID":"\#(profile.uuidString)"}"#.utf8))
        #expect(decoded.profileID == profile)
    }

    @Test func carriesNoSecrets() throws {
        // SwiftUI persists the value for window restoration: it must hold ids only.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WindowRequest(profileID: UUID()))) as? [String: Any]
        #expect(encoded.map { Set($0.keys) } == ["profileID", "nonce"])
    }
}

@MainActor
@Suite("Window handoff")
struct WindowHandoffTests {
    @Test func aPayloadIsTakenExactlyOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "secret")
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(request) == "secret")
        #expect(handoff.take(request) == nil, "a second window must not reuse the connection")
        #expect(handoff.pendingCount == 0)
    }

    @Test func restoredRequestsCarryNothing() throws {
        // A request decoded after a relaunch (window restoration) was not created by this process.
        let handoff = WindowHandoff<String>()
        let original = handoff.request(profileID: UUID(), payload: "secret")
        let restored = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(original))
        #expect(WindowHandoff<String>().take(restored) == nil, "another process (a relaunch) has no payload for it")
        #expect(handoff.take(WindowRequest(profileID: original.profileID)) == nil, "same profile, different request")
        #expect(handoff.pendingCount == 1)
    }

    @Test func requestsForTheSameProfileAreIndependent() {
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let first = handoff.request(profileID: profile, payload: "a")
        let second = handoff.request(profileID: profile, payload: "b")
        #expect(first != second)
        #expect(first.profileID == profile && second.profileID == profile)
        #expect(handoff.take(second) == "b")
        #expect(handoff.take(first) == "a")
        #expect(handoff.pendingCount == 0)
    }
}

@Suite("Window connections")
struct WindowConnectionTests {
    private static let everySecret = ProfileSecrets(password: "redis-pw", sentinelPassword: "sentinel-pw", sshSecret: "ssh-pw",
                                                    tlsCertificatePassword: "p12-pw")

    private static func sentinelProfile() -> ConnectionProfile {
        var profile = ConnectionProfile(name: "prod", color: .purple, mode: .sentinel)
        profile.sentinelNodes = "127.0.0.1:17311"
        profile.sentinelMasterName = "mymaster"
        profile.username = "alice"
        profile.sentinelUsername = "watcher"
        profile.tls = TLSOptions(clientCertificateFile: "/tmp/client.p12")
        profile.ssh = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: .password)
        profile.readOnly = true
        return profile
    }

    @Test func aSavedConnectionReadsItsSecretsFromTheStore() {
        let profile = Self.sentinelProfile()
        let connection = WindowConnection.saved(profile)
        #expect(connection.profile == profile)
        #expect(connection.secrets == nil, "nil means: read the Keychain, as Connect does")
    }

    @Test func aDuplicateCarriesEverySecretInUse() throws {
        let profile = Self.sentinelProfile()
        let configuration = try profile.clientConfiguration(secrets: Self.everySecret)
        let duplicate = WindowConnection.duplicate(of: profile, configuration: configuration, database: profile.database)
        #expect(duplicate.secrets == Self.everySecret)
        #expect(duplicate.profile == profile)
    }

    @Test func aDuplicateWithoutSecretsDoesNotFallBackToTheStore() throws {
        // The source window connected without secrets; the duplicate must not pick up Keychain entries instead.
        let profile = Self.sentinelProfile()
        let configuration = try profile.clientConfiguration(secrets: ProfileSecrets())
        let duplicate = WindowConnection.duplicate(of: profile, configuration: configuration, database: 0)
        #expect(duplicate.secrets == ProfileSecrets())
    }

    @Test func aDuplicateOpensTheDatabaseBeingBrowsed() throws {
        var profile = ConnectionProfile(name: "local", port: 17050)
        profile.database = 1
        let configuration = try profile.clientConfiguration(secrets: ProfileSecrets(password: "pw"))
        let duplicate = WindowConnection.duplicate(of: profile, configuration: configuration, database: 3)
        #expect(duplicate.profile.database == 3)
        var expected = profile
        expected.database = 3
        #expect(duplicate.profile == expected, "only the database changes")
        #expect(try duplicate.profile.clientConfiguration(secrets: duplicate.secrets ?? ProfileSecrets()).database == 3)
    }

    @Test func aClusterDuplicateStaysOnDatabaseZero() throws {
        var profile = ConnectionProfile(name: "cluster", mode: .cluster)
        profile.clusterSeeds = "127.0.0.1:17101"
        let configuration = try profile.clientConfiguration(secrets: ProfileSecrets())
        #expect(WindowConnection.duplicate(of: profile, configuration: configuration, database: 5).profile.database == 0)
    }

    @Test func aNegativeDatabaseIsIgnored() throws {
        var profile = ConnectionProfile(name: "local")
        profile.database = 2
        let configuration = try profile.clientConfiguration(secrets: ProfileSecrets())
        #expect(WindowConnection.duplicate(of: profile, configuration: configuration, database: -1).profile.database == 2)
    }
}
