import Foundation
import os
import RESPWire
@testable import RedisKit

/// What the fake does with one request.
enum FakeAction: Sendable {
    case reply(RESPValue)
    /// Several frames (e.g. SUBSCRIBE confirmations for several channels).
    case replies([RESPValue])
    /// Close the connection without answering (twemproxy on unsupported commands).
    case drop
    /// Never answer.
    case hang
}

struct FakeRequest: Sendable {
    let arguments: [[UInt8]]
    let connectionIndex: Int
    let endpoint: Endpoint

    var name: String { arguments.first.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? "" }
    var strings: [String] { arguments.map { String(decoding: $0, as: UTF8.self) } }
    func argument(_ index: Int) -> String? { arguments.indices.contains(index) ? String(decoding: arguments[index], as: UTF8.self) : nil }
}

/// Scriptable in-process Redis: hands out `FakeConnection` transports and records every request.
final class FakeRedisBackend: Sendable {
    typealias Handler = @Sendable (FakeRequest) -> FakeAction

    private struct State {
        var connections: [FakeConnection] = []
        var log: [(connection: Int, endpoint: Endpoint, command: [String])] = []
        var refusedEndpoints: Set<Endpoint> = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var connector: EndpointConnector {
        { [self] endpoint in try self.connect(endpoint) }
    }

    func connect(_ endpoint: Endpoint) throws -> FakeConnection {
        try state.withLockUnchecked { state in
            if state.refusedEndpoints.contains(endpoint) {
                throw RedisError(.network, "Connection refused by \(endpoint)")
            }
            let connection = FakeConnection(index: state.connections.count, endpoint: endpoint, backend: self)
            state.connections.append(connection)
            return connection
        }
    }

    func refuse(_ endpoint: Endpoint) { state.withLockUnchecked { _ = $0.refusedEndpoints.insert(endpoint) } }
    func accept(_ endpoint: Endpoint) { state.withLockUnchecked { _ = $0.refusedEndpoints.remove(endpoint) } }

    fileprivate func handle(_ request: FakeRequest) -> FakeAction {
        state.withLockUnchecked { $0.log.append((request.connectionIndex, request.endpoint, request.strings)) }
        return handler(request)
    }

    var connectionCount: Int { state.withLockUnchecked { $0.connections.count } }
    var commands: [[String]] { state.withLockUnchecked { $0.log.map(\.command) } }
    var commandNames: [String] { commands.map { $0.first?.uppercased() ?? "" } }
    func commands(on endpoint: Endpoint) -> [[String]] { state.withLockUnchecked { $0.log.filter { $0.endpoint == endpoint }.map(\.command) } }
    func connection(_ index: Int) -> FakeConnection? { state.withLockUnchecked { $0.connections.indices.contains(index) ? $0.connections[index] : nil } }

    /// Sends an unsolicited frame (push / pubsub message) on every open connection.
    func broadcast(_ value: RESPValue) {
        for connection in state.withLockUnchecked({ $0.connections }) { connection.inject(value) }
    }
}

final class FakeConnection: ByteTransport, @unchecked Sendable {
    private struct State {
        var outbox: [UInt8] = []
        var receiver: CheckedContinuation<[UInt8], any Error>?
        var closed = false
        var parser = RESPParser()
    }

    let index: Int
    let endpoint: Endpoint
    private unowned let backend: FakeRedisBackend
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(index: Int, endpoint: Endpoint, backend: FakeRedisBackend) {
        self.index = index
        self.endpoint = endpoint
        self.backend = backend
    }

    var isClosed: Bool { state.withLockUnchecked { $0.closed } }

    func send(_ bytes: [UInt8]) async throws {
        var requests: [[[UInt8]]] = []
        try state.withLockUnchecked { state in
            guard !state.closed else { throw RedisError(.connectionClosed, "closed") }
            state.parser.append(bytes)
            while let value = try state.parser.next() {
                requests.append(value.array?.compactMap(\.bytes) ?? [])
            }
        }
        for arguments in requests {
            switch backend.handle(FakeRequest(arguments: arguments, connectionIndex: index, endpoint: endpoint)) {
            case let .reply(value): enqueue(RESPEncoder.encode(value))
            case let .replies(values): for value in values { enqueue(RESPEncoder.encode(value)) }
            case .drop:
                close()
                return
            case .hang:
                return
            }
        }
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            state.withLockUnchecked { state in
                if !state.outbox.isEmpty {
                    let bytes = state.outbox
                    state.outbox.removeAll()
                    continuation.resume(returning: bytes)
                } else if state.closed {
                    continuation.resume(throwing: RedisError(.connectionClosed, "\(endpoint) closed the connection"))
                } else {
                    state.receiver = continuation
                }
            }
        }
    }

    func close() {
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            state.closed = true
            defer { state.receiver = nil }
            return state.receiver
        }
        receiver?.resume(throwing: RedisError(.connectionClosed, "\(endpoint) closed the connection"))
    }

    func inject(_ value: RESPValue) { enqueue(RESPEncoder.encode(value)) }
    func injectBytes(_ bytes: [UInt8]) { enqueue(bytes) }

    private func enqueue(_ bytes: [UInt8]) {
        let delivery = state.withLockUnchecked { state -> (CheckedContinuation<[UInt8], any Error>, [UInt8])? in
            guard !state.closed else { return nil }
            state.outbox.append(contentsOf: bytes)
            guard let receiver = state.receiver else { return nil }
            state.receiver = nil
            let out = state.outbox
            state.outbox.removeAll()
            return (receiver, out)
        }
        if let (receiver, out) = delivery { receiver.resume(returning: out) }
    }
}

extension RESPValue {
    static func bulk(_ text: String) -> RESPValue { .bulkString(Array(text.utf8)) }
    static let ok = RESPValue.simpleString("OK")
    static func err(_ text: String) -> RESPValue { .error(text) }
}

/// HELLO reply map for a Redis server of the given version.
func helloReply(version: String = "7.2.4", mode: String = "standalone", role: String = "master", proto: Int64 = 3) -> RESPValue {
    .map([
        RESPPair(.bulk("server"), .bulk("redis")), RESPPair(.bulk("version"), .bulk(version)),
        RESPPair(.bulk("proto"), .integer(proto)), RESPPair(.bulk("id"), .integer(7)),
        RESPPair(.bulk("mode"), .bulk(mode)), RESPPair(.bulk("role"), .bulk(role)), RESPPair(.bulk("modules"), .array([])),
    ])
}
