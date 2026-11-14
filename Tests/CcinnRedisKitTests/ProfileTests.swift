import Foundation
import RedisKit
import Testing
@testable import CcinnRedisKit

@Suite("Connection profiles")
struct ProfileTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ccinnredis-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func defaults() {
        let profile = ConnectionProfile()
        #expect(profile.mode == .standalone)
        #expect(profile.port == 6379)
        #expect(profile.database == 0)
        #expect(profile.protocolPreference == .auto)
        #expect(!profile.readOnly)
        #expect(profile.delimiter == ":")
    }

    @Test func secretsNeverReachTheProfileFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let repository = ProfileRepository(directory: directory, secrets: secrets)
        var profile = ConnectionProfile(name: "prod", host: "cache.example.com")
        profile.username = "alice"
        profile.ssh = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: .password)
        profile.tls = TLSOptions(clientCertificateFile: "/tmp/client.p12")
        try repository.save([profile])
        try repository.storeSecrets(for: profile, secrets: ProfileSecrets(password: "redis-secret-123", sentinelPassword: "sentinel-secret-456",
                                                                          sshSecret: "ssh-secret-789", tlsCertificatePassword: "p12-secret-000"))
        let text = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        for secret in ["redis-secret-123", "sentinel-secret-456", "ssh-secret-789", "p12-secret-000"] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains("cache.example.com"))
        let loaded = try repository.load()
        #expect(loaded == [profile])
        #expect(repository.secrets(for: profile).password == "redis-secret-123")
        #expect(repository.secrets(for: profile).sentinelPassword == "sentinel-secret-456")
        try repository.delete(profile)
        #expect(repository.secrets(for: profile).password == nil)
    }

    @Test func olderProfileFilesStillDecode() throws {
        let json = #"[{"id":"7C9F3C3E-1F5B-4B3C-9C55-7A1A0E1E2F11","name":"old","host":"h","port":6380,"createdAt":0}]"#
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        #expect(decoded.first?.port == 6380)
        #expect(decoded.first?.mode == .standalone)
        #expect(decoded.first?.delimiter == ":")
    }

    @Test func buildsClientConfigurationPerMode() throws {
        var profile = ConnectionProfile(name: "s", host: "127.0.0.1", port: 17072)
        profile.database = 3
        profile.readOnly = true
        let standalone = try profile.clientConfiguration(secrets: ProfileSecrets(password: "pw"))
        #expect(standalone.mode == .standalone(Endpoint(host: "127.0.0.1", port: 17072)))
        #expect(standalone.credentials.password == "pw")
        #expect(standalone.database == 3)
        #expect(standalone.readOnly)

        profile.mode = .sentinel
        profile.sentinelNodes = "127.0.0.1:17311, 127.0.0.1:17312\n127.0.0.1:17313"
        profile.sentinelMasterName = "mymaster"
        let sentinel = try profile.clientConfiguration(secrets: ProfileSecrets(sentinelPassword: "sp"))
        #expect(sentinel.mode == .sentinel(sentinels: [Endpoint(host: "127.0.0.1", port: 17311), Endpoint(host: "127.0.0.1", port: 17312),
                                                       Endpoint(host: "127.0.0.1", port: 17313)], masterName: "mymaster", role: .master))
        #expect(sentinel.sentinelCredentials.password == "sp")

        profile.mode = .cluster
        profile.clusterSeeds = "127.0.0.1:17101 127.0.0.1:17102"
        profile.addressMapText = "10.0.0.1 => 127.0.0.1"
        let cluster = try profile.clientConfiguration(secrets: ProfileSecrets())
        #expect(cluster.mode == .cluster(seeds: [Endpoint(host: "127.0.0.1", port: 17101), Endpoint(host: "127.0.0.1", port: 17102)]))
        #expect(cluster.addressMap.rules.count == 1)
    }

    @Test func validation() {
        var profile = ConnectionProfile(host: "")
        #expect(!profile.validationErrors.isEmpty)
        profile.host = "h"
        #expect(profile.validationErrors.isEmpty)
        profile.mode = .sentinel
        #expect(profile.validationErrors.contains { $0.contains("master name") })
        profile.sentinelMasterName = "m"
        #expect(profile.validationErrors.contains { $0.contains("sentinel") })
        profile.sentinelNodes = "127.0.0.1:26379"
        #expect(profile.validationErrors.isEmpty)
        profile.mode = .cluster
        #expect(!profile.validationErrors.isEmpty)
        profile.clusterSeeds = "127.0.0.1:7000"
        profile.database = 2
        #expect(profile.validationErrors.contains { $0.contains("database 0") })
        profile.database = 0
        profile.addressMapText = "garbage"
        #expect(profile.validationErrors.contains { $0.contains("Address map") })
    }

    @Test func unixSocketProfile() throws {
        var profile = ConnectionProfile(host: "/tmp/redis.sock")
        profile.useUnixSocket = true
        let configuration = try profile.clientConfiguration(secrets: ProfileSecrets())
        guard case let .standalone(endpoint) = configuration.mode else { Issue.record("wrong mode"); return }
        #expect(endpoint.isUnixSocket)
        #expect(profile.hostSummary.contains("/tmp/redis.sock"))
    }
}

@Suite("Connection URIs")
struct ConnectionURITests {
    @Test func plainAndTLS() throws {
        let parsed = try ConnectionURI.parse("rediss://alice:s%40cret@cache.example.com:6380/2")
        #expect(parsed.profile.host == "cache.example.com")
        #expect(parsed.profile.port == 6380)
        #expect(parsed.profile.database == 2)
        #expect(parsed.profile.username == "alice")
        #expect(parsed.profile.tls != nil)
        #expect(parsed.password == "s@cret")

        let simple = try ConnectionURI.parse("redis://localhost")
        #expect(simple.profile.port == 6379)
        #expect(simple.profile.tls == nil)
        #expect(simple.password == nil)

        let passwordOnly = try ConnectionURI.parse("redis://:pw@10.0.0.1:7000")
        #expect(passwordOnly.profile.username.isEmpty)
        #expect(passwordOnly.password == "pw")
    }

    @Test func queryOptionsAndUnix() throws {
        let query = try ConnectionURI.parse("redis://h:1/0?protocol=2&readonly=true&name=Prod")
        #expect(query.profile.protocolPreference == .resp2)
        #expect(query.profile.readOnly)
        #expect(query.profile.name == "Prod")
        let unix = try ConnectionURI.parse("unix:///var/run/redis.sock?db=4")
        #expect(unix.profile.useUnixSocket)
        #expect(unix.profile.host == "/var/run/redis.sock")
        #expect(unix.profile.database == 4)
        let ipv6 = try ConnectionURI.parse("redis://[::1]:6390")
        #expect(ipv6.profile.host == "::1")
        #expect(ipv6.profile.port == 6390)
    }

    @Test func sentinelAndClusterSchemes() throws {
        let sentinel = try ConnectionURI.parse("redis-sentinel://:pw@127.0.0.1:17311,127.0.0.1:17312/0?master=mymaster")
        #expect(sentinel.profile.mode == .sentinel)
        #expect(sentinel.profile.sentinelMasterName == "mymaster")
        #expect(sentinel.profile.sentinelNodes.contains("17312"))
        let cluster = try ConnectionURI.parse("redis-cluster://127.0.0.1:17101,127.0.0.1:17102")
        #expect(cluster.profile.mode == .cluster)
        #expect(cluster.profile.clusterSeeds.contains("17102"))
    }

    @Test func invalidURIs() {
        for text in ["http://example.com", "redis://", "redis://host:notaport", "redis://h/abc"] {
            #expect(throws: (any Error).self) { try ConnectionURI.parse(text) }
        }
    }

    @Test func exportOmitsPassword() {
        var profile = ConnectionProfile(host: "h", port: 6380)
        profile.username = "bob"
        profile.database = 1
        profile.tls = TLSOptions()
        #expect(ConnectionURI.string(for: profile) == "rediss://bob@h:6380/1")
    }
}
