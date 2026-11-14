import CcinnRedisKit
import Foundation
import Observation

/// Shared, observable list of saved connection profiles (persisted via `ProfileRepository`).
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile] = []
    var lastError: String?
    let repository: ProfileRepository

    init(repository: ProfileRepository) {
        self.repository = repository
        do {
            profiles = try repository.load()
        } catch {
            lastError = "Could not read saved connections: \(error.localizedDescription)"
        }
    }

    var favorites: [ConnectionProfile] { profiles.filter(\.isFavorite).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var recents: [ConnectionProfile] { Array(ConnectionProfile.recents(profiles.filter { !$0.isFavorite }).prefix(10)) }
    var others: [ConnectionProfile] {
        let recentIDs = Set(recents.map(\.id))
        return profiles.filter { !$0.isFavorite && !recentIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func profile(id: UUID?) -> ConnectionProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Inserts or updates a profile; secrets go to the Keychain, never to the profile file.
    @discardableResult
    func save(_ profile: ConnectionProfile, secrets: ProfileSecrets) throws -> ConnectionProfile {
        try repository.storeSecrets(for: profile, secrets: secrets)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
        return profile
    }

    func delete(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? repository.delete(profile)
        try? persist()
    }

    func duplicate(_ profile: ConnectionProfile) -> ConnectionProfile? {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.displayName + " copy"
        copy.lastConnectedAt = nil
        copy.createdAt = Date()
        copy.isFavorite = false
        return try? save(copy, secrets: secrets(for: profile))
    }

    func toggleFavorite(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isFavorite.toggle()
        try? persist()
    }

    func setMCPAccess(_ access: MCPAccess, for profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mcpAccess = access
        try? persist()
    }

    func markConnected(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastConnectedAt = Date()
        try? persist()
    }

    func secrets(for profile: ConnectionProfile) -> ProfileSecrets { repository.secrets(for: profile) }

    private func persist() throws {
        do {
            try repository.save(profiles)
            lastError = nil
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
            throw error
        }
    }
}

/// App-wide services shared by every window.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let profiles: ProfileStore
    let dataDirectory: URL
    var historyDirectory: URL { dataDirectory.appendingPathComponent("History", isDirectory: true) }

    private init() {
        // `--profiles-directory <path>` (automation, screenshots) keeps secrets in memory, not in the Keychain.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--profiles-directory"), arguments.indices.contains(index + 1) {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            profiles = ProfileStore(repository: ProfileRepository(directory: dataDirectory, secrets: InMemorySecretStore()))
        } else {
            dataDirectory = ProfileRepository.defaultDirectory
            profiles = ProfileStore(repository: ProfileRepository())
        }
    }
}
