import Foundation

/// Runs `flush` at most once per `interval` however often `signal()` is called, so a burst of
/// MONITOR or Pub/Sub frames turns into ~10 UI updates per second instead of one per frame.
@MainActor
final class UpdateCoalescer {
    private let interval: Duration
    private let flush: @MainActor () -> Void
    private var scheduled: Task<Void, Never>?

    init(interval: Duration = .milliseconds(100), flush: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.flush = flush
    }

    func signal() {
        guard scheduled == nil else { return }
        let interval = interval
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            self.flush()
        }
    }

    /// Flushes pending work immediately (e.g. when the stream ends).
    func flushNow() {
        cancel()
        flush()
    }

    func cancel() {
        scheduled?.cancel()
        scheduled = nil
    }
}
