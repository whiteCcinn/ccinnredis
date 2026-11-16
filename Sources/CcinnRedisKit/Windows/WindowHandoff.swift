import Foundation

/// Hands the connection to open (profile, secrets in use, …) to a window this process opens. A `WindowRequest`
/// only carries ids, because SwiftUI may persist and restore it, so the payload stays here, in memory, until the new
/// window takes it, exactly once.
///
/// A request without a payload was not created by this process: it is a window macOS restored after a relaunch.
/// Such a window shows the connection screen and never connects by itself.
@MainActor
public final class WindowHandoff<Payload> {
    private var pending: [UUID: Payload] = [:]

    public init() {}

    /// Keeps `payload` for the window that the returned request opens.
    public func request(profileID: UUID, payload: Payload) -> WindowRequest {
        let request = WindowRequest(profileID: profileID)
        pending[request.nonce] = payload
        return request
    }

    /// The payload for `request`, once; `nil` for a request this handoff did not create or already handed over.
    public func take(_ request: WindowRequest) -> Payload? {
        pending.removeValue(forKey: request.nonce)
    }

    public var pendingCount: Int { pending.count }
}
