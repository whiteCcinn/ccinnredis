import Foundation
import RESPWire

/// One connection to one Redis server.
///
/// Request/response use is exclusive: a caller sends one command or a pipeline and reads all of its
/// replies before anyone else may use the connection (re-entry throws `busy`). Cancellation or a
/// timeout while replies are outstanding closes the transport and marks the connection broken, because
/// the byte stream can no longer be matched to requests. Streaming use (Pub/Sub, MONITOR) is entered
/// explicitly and owned by a single session object.
public actor RedisConnection {
    public nonisolated let endpoint: Endpoint
    public nonisolated let localID: UInt64
    private nonisolated let transport: any ByteTransport
    private var parser: RESPParser
    public private(set) var protocolVersion = 2
    public private(set) var isBroken = false
    private var isBusy = false
    private var isStreaming = false
    private var lastActivity = ContinuousClock.now
    private var pushHandler: (@Sendable (RESPValue) -> Void)?

    private static let counter = IDCounter()

    public init(endpoint: Endpoint, transport: any ByteTransport, limits: RESPLimits = RESPLimits()) {
        self.endpoint = endpoint
        self.transport = transport
        parser = RESPParser(limits: limits)
        localID = Self.counter.next()
    }

    /// Time since the last completed exchange.
    public var idleDuration: Duration { ContinuousClock.now - lastActivity }

    func setProtocolVersion(_ version: Int) { protocolVersion = version }

    /// Receives RESP3 push frames that arrive between replies (e.g. invalidation messages).
    public func setPushHandler(_ handler: (@Sendable (RESPValue) -> Void)?) { pushHandler = handler }

    // MARK: Request / response

    /// Sends one command and returns its reply; error replies are thrown as `RedisError`.
    @discardableResult
    public func send(_ command: RedisCommand, timeout: Double? = nil) async throws -> RESPValue {
        let reply = try await pipeline([command], timeout: timeout)[0]
        if let message = reply.errorMessage { throw RedisError.server(message) }
        return reply
    }

    /// Sends all commands in one write and returns one reply per command, in order. Error replies are
    /// returned as values so one failing command does not hide the others.
    public func pipeline(_ commands: [RedisCommand], timeout: Double? = nil) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        guard !isBroken else { throw RedisError(.connectionClosed, "The connection to \(endpoint) is closed") }
        guard !isBusy, !isStreaming else { throw RedisError(.busy, "The connection to \(endpoint) is in use") }
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }
        let endpoint = endpoint
        do {
            let replies = try await Deadline.run(seconds: timeout, timeoutError: {
                RedisError(.timeout, "No reply from \(endpoint) within \(Self.format(seconds: timeout))")
            }) { [self] in
                try await self.exchange(commands)
            }
            lastActivity = .now
            return replies
        } catch {
            fail()
            if Task.isCancelled, (error as? RedisError)?.kind != .timeout { throw RedisError.cancelled() }
            throw Self.normalize(error)
        }
    }

    private func exchange(_ commands: [RedisCommand]) async throws -> [RESPValue] {
        var bytes: [UInt8] = []
        for command in commands { RESPEncoder.appendCommand(arguments: command.arguments, to: &bytes) }
        let transport = transport
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await transport.send(bytes)
            var replies: [RESPValue] = []
            replies.reserveCapacity(commands.count)
            while replies.count < commands.count {
                replies.append(try await readValue(allowPush: false))
            }
            return replies
        } onCancel: {
            transport.close()
        }
    }

    private func readValue(allowPush: Bool) async throws -> RESPValue {
        while true {
            do {
                if let value = try parser.next() {
                    if !allowPush, case .push = value {
                        pushHandler?(value)
                        continue
                    }
                    return value
                }
            } catch let error as RESPError {
                throw error.redisError
            }
            let chunk = try await transport.receive()
            parser.append(chunk)
        }
    }

    // MARK: Streaming (Pub/Sub, MONITOR)

    /// Switches the connection to streaming use; request/response calls are refused afterwards.
    public func enterStreamingMode() throws {
        guard !isBusy else { throw RedisError(.busy, "The connection to \(endpoint) is in use") }
        isStreaming = true
    }

    /// Writes commands without waiting for replies (replies arrive through `nextStreamValue`).
    public func streamWrite(_ commands: [RedisCommand]) async throws {
        guard isStreaming, !isBroken else { throw RedisError(.connectionClosed, "The streaming connection to \(endpoint) is closed") }
        var bytes: [UInt8] = []
        for command in commands { RESPEncoder.appendCommand(arguments: command.arguments, to: &bytes) }
        do {
            try await transport.send(bytes)
        } catch {
            fail()
            throw Self.normalize(error)
        }
    }

    /// Next frame (reply, RESP2 message array or RESP3 push) on a streaming connection.
    public func nextStreamValue() async throws -> RESPValue {
        guard isStreaming, !isBroken else { throw RedisError(.connectionClosed, "The streaming connection to \(endpoint) is closed") }
        let transport = transport
        do {
            return try await withTaskCancellationHandler {
                try await readValue(allowPush: true)
            } onCancel: {
                transport.close()
            }
        } catch {
            fail()
            if Task.isCancelled { throw RedisError.cancelled() }
            throw Self.normalize(error)
        }
    }

    // MARK: Lifecycle

    public func close() {
        isBroken = true
        transport.close()
    }

    /// Closes the socket from any context (used for cancellation and app shutdown).
    public nonisolated func closeImmediately() {
        transport.close()
    }

    private func fail() {
        isBroken = true
        transport.close()
    }

    static func normalize(_ error: any Error) -> RedisError {
        if let error = error as? RedisError { return error }
        if let error = error as? RESPError { return error.redisError }
        if error is CancellationError { return .cancelled() }
        return RedisError(.network, error.localizedDescription)
    }

    static func format(seconds: Double?) -> String {
        guard let seconds else { return "the time limit" }
        return seconds < 1 ? "\(Int(seconds * 1000)) ms" : "\(Int(seconds.rounded())) s"
    }
}

/// Process-wide monotonically increasing identifiers.
final class IDCounter: Sendable {
    private let value = OSAllocatedUnfairLockBox<UInt64>(0)
    func next() -> UInt64 { value.withLock { current in current &+= 1; return current } }
}
