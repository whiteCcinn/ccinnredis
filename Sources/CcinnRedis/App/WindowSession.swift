import CcinnRedisKit
import Foundation
import Observation
import RedisKit

/// Opens a client for a profile.
enum ConnectionOpener {
    static func open(profile: ConnectionProfile, secrets: ProfileSecrets, progress: @escaping @Sendable (String) -> Void) async throws -> RedisClient {
        let configuration = try profile.clientConfiguration(secrets: secrets)
        if let ssh = profile.ssh { progress("Opening SSH tunnel through \(ssh.host)…") }
        return try await RedisClient.connect(configuration, progress: progress)
    }
}

/// State of one window: choosing a connection, connecting, or connected to a workspace.
@MainActor
@Observable
final class WindowSession {
    enum Phase {
        case connections
        case connecting(name: String, status: String)
        case connected(WorkspaceModel)
    }

    var phase: Phase = .connections
    var connectError: String?
    private var connectTask: Task<Void, Never>?

    var workspace: WorkspaceModel? {
        if case let .connected(model) = phase { return model }
        return nil
    }

    func connect(profile: ConnectionProfile, store: ProfileStore, secrets override: ProfileSecrets? = nil,
                 then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        // A connect still in flight would otherwise finish later and replace this one.
        connectTask?.cancel()
        connectError = nil
        let name = profile.displayName
        let secrets = override ?? store.secrets(for: profile)
        phase = .connecting(name: name, status: "Connecting…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in self.updateStatus(name: name, status: status) }
        }
        connectTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, secrets: secrets, progress: report)
                if Task.isCancelled {
                    await client.close()
                    return
                }
                store.markConnected(profile.id)
                let workspace = WorkspaceModel(profile: profile, client: client)
                self.phase = .connected(workspace)
                workspace.start()
                then?(workspace)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .connections
            }
        }
    }

    /// Connects a window opened by a request of this process and returns `true`. A request without a handed-off
    /// connection is a window macOS restored after a relaunch: it returns `false`, and the window is treated like one
    /// opened without a request (connection screen); it never connects by itself.
    func connect(_ request: WindowRequest, store: ProfileStore) -> Bool {
        guard let connection = Self.handoff.take(request) else { return false }
        connect(profile: connection.profile, store: store, secrets: connection.secrets)
        return true
    }

    /// A request for another window connected like this one: the same profile, every secret in use (so unsaved
    /// connections and secrets not in the Keychain work too) and the database this window is browsing.
    func duplicateRequest() -> WindowRequest? {
        guard let workspace else { return nil }
        let client = workspace.client
        let connection = WindowConnection.duplicate(of: workspace.profile, configuration: client.configuration, database: client.database)
        return Self.handoff.request(profileID: workspace.profile.id, payload: connection)
    }

    /// A request for a new window that connects to a saved profile, reading its secrets from the Keychain as
    /// Connect does.
    static func request(opening profile: ConnectionProfile) -> WindowRequest {
        handoff.request(profileID: profile.id, payload: .saved(profile))
    }

    /// Connections handed to windows this process opens (see `WindowHandoff`); in memory only.
    private static let handoff = WindowHandoff<WindowConnection>()

    private func updateStatus(name: String, status: String) {
        guard case .connecting = phase else { return }
        phase = .connecting(name: name, status: status)
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .connections
    }

    /// Also called when the window closes: a connect still in flight would otherwise finish later and leave a live
    /// client (and SSH tunnel) behind.
    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        workspace?.shutdown()
        phase = .connections
    }
}

/// User-facing text for any error.
func describe(_ error: any Error) -> String {
    if let error = error as? RedisError { return error.message }
    if let error = error as? any LocalizedError, let description = error.errorDescription { return description }
    return error.localizedDescription
}
