import Foundation
import RedisKit

/// The connection a new window opens: a profile and the secrets to use (`nil` = read them from the store, as
/// Connect does). Lives in memory only (see `WindowHandoff`).
public struct WindowConnection: Sendable {
    public let profile: ConnectionProfile
    public let secrets: ProfileSecrets?

    public init(profile: ConnectionProfile, secrets: ProfileSecrets?) {
        self.profile = profile
        self.secrets = secrets
    }

    /// A saved connection, opened with the secrets stored for it.
    public static func saved(_ profile: ConnectionProfile) -> WindowConnection {
        WindowConnection(profile: profile, secrets: nil)
    }

    /// Another window connected like an open one: the profile it connected with, every secret its client was opened
    /// with (so unsaved connections and secrets not in the Keychain work too, and the Keychain is never consulted)
    /// and the database it is browsing now. Redis Cluster only has database 0.
    public static func duplicate(of profile: ConnectionProfile, configuration: ClientConfiguration, database: Int) -> WindowConnection {
        var copy = profile
        if profile.mode != .cluster, database >= 0 { copy.database = database }
        return WindowConnection(profile: copy, secrets: ProfileSecrets(configuration: configuration))
    }
}
