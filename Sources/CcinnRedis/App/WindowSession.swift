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

    private func updateStatus(name: String, status: String) {
        guard case .connecting = phase else { return }
        phase = .connecting(name: name, status: status)
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .connections
    }

    func disconnect() {
        workspace?.shutdown()
        phase = .connections
    }
}

/// User-facing text for any error.
func describe(_ error: any Error) -> String {
    if let error = error as? RedisError { return error.message }
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return error.localizedDescription
}
