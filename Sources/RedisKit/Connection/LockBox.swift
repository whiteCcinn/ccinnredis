import os

/// Small wrapper over `OSAllocatedUnfairLock` for `Sendable` state shared across tasks.
/// Bodies run under the lock and must be short and non-blocking.
final class OSAllocatedUnfairLockBox<State: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    init(_ initial: State) {
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try lock.withLockUnchecked(body)
    }

    var value: State { lock.withLock { $0 } }
}
