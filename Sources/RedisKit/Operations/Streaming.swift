import Foundation
import RESPWire

public enum PubSubEvent: Sendable, Equatable {
    case subscribed(kind: String, channel: String, count: Int64)
    case unsubscribed(kind: String, channel: String, count: Int64)
    case message(channel: [UInt8], payload: [UInt8], pattern: [UInt8]?)
    case pong
    case other(RESPValue)
    case closed(String?)

    /// Interprets a frame received on a subscribed connection (RESP2 array or RESP3 push).
    public static func parse(_ value: RESPValue) -> PubSubEvent {
        guard let parts = value.array, let kind = parts.first?.string?.lowercased() else {
            if let message = value.errorMessage { return .closed(message) }
            return .other(value)
        }
        switch kind {
        case "message", "smessage":
            guard parts.count >= 3 else { return .other(value) }
            return .message(channel: parts[1].bytes ?? [], payload: parts[2].bytes ?? [], pattern: nil)
        case "pmessage":
            guard parts.count >= 4 else { return .other(value) }
            return .message(channel: parts[2].bytes ?? [], payload: parts[3].bytes ?? [], pattern: parts[1].bytes)
        case "subscribe", "psubscribe", "ssubscribe":
            return .subscribed(kind: kind, channel: parts.count > 1 ? parts[1].string ?? "" : "", count: parts.count > 2 ? parts[2].int ?? 0 : 0)
        case "unsubscribe", "punsubscribe", "sunsubscribe":
            return .unsubscribed(kind: kind, channel: parts.count > 1 ? parts[1].string ?? "" : "", count: parts.count > 2 ? parts[2].int ?? 0 : 0)
        case "pong":
            return .pong
        default:
            return .other(value)
        }
    }
}

/// A dedicated connection whose frames are delivered as a stream: Pub/Sub, MONITOR, console streaming.
public actor StreamingSession {
    private let connection: RedisConnection
    public nonisolated let endpoint: Endpoint
    public nonisolated let frames: AsyncStream<RESPValue>
    private let sink: AsyncStream<RESPValue>.Continuation
    private var reader: Task<Void, Never>?
    public private(set) var closeReason: String?

    private init(connection: RedisConnection) {
        self.connection = connection
        endpoint = connection.endpoint
        (frames, sink) = AsyncStream.makeStream(of: RESPValue.self, bufferingPolicy: .bufferingNewest(10_000))
    }

    /// Opens a dedicated connection on the route and sends `initial` (e.g. SUBSCRIBE, MONITOR).
    public static func open(client: RedisClient, route: Route = .auto, initial: [RedisCommand]) async throws -> StreamingSession {
        let (connection, _) = try await client.dedicatedConnection(route: route, command: initial.first)
        do {
            try await connection.enterStreamingMode()
            let session = StreamingSession(connection: connection)
            await session.start()
            if !initial.isEmpty { try await session.send(initial) }
            return session
        } catch {
            await connection.close()
            throw error
        }
    }

    private func start() {
        let connection = connection
        let sink = sink
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await connection.nextStreamValue()
                    sink.yield(frame)
                } catch {
                    await self?.finish(reason: (error as? RedisError)?.message ?? error.localizedDescription)
                    return
                }
            }
        }
    }

    public func send(_ commands: [RedisCommand]) async throws {
        try await connection.streamWrite(commands)
    }

    private func finish(reason: String?) {
        if closeReason == nil { closeReason = reason }
        sink.finish()
    }

    public func close() async {
        reader?.cancel()
        reader = nil
        await connection.close()
        finish(reason: nil)
    }
}
