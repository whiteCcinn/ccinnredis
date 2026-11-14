import os

/// Small wrapper over `OSAllocatedUnfairLock` for `Sendable` state shared across tasks.
final class OSAllocatedUnfairLockBox<State: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    init(_ initial: State) {
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    func withLock<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
        try lock.withLock(body)
    }

    var value: State { lock.withLock { $0 } }
}
