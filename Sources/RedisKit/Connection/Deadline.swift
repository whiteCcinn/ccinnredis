import Foundation

/// Runs an operation with a time limit. On timeout the operation's task is cancelled, which closes
/// any socket it is waiting on (connections close their transport on cancellation).
enum Deadline {
    static func run<T: Sendable>(seconds: Double?, timeoutError: @escaping @Sendable () -> RedisError,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let seconds, seconds > 0 else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int(max(0.05, min(seconds, 86_400)) * 1000)))
                throw timeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw timeoutError() }
            return result
        }
    }
}
