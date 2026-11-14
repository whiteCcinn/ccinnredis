import Foundation
import RESPWire
import Testing
@testable import RedisKit

private let local = Endpoint(host: "127.0.0.1", port: 6379)

@Suite("Handshake")
struct HandshakeTests {
    @Test func negotiatesRESP3WithHelloAuthAndName() async throws {
        let backend = FakeRedisBackend { request in
            request.name == "HELLO" ? .reply(helloReply()) : .reply(.ok)
        }
        let plan = HandshakePlan(credentials: Credentials(username: "alice", password: "s3cret"))
        let (connection, outcome) = try await Handshaker.open(endpoint: local, plan: plan, connector: backend.connector)
        #expect(outcome.protocolVersion == 3)
        #expect(await connection.protocolVersion == 3)
        #expect(backend.commands == [["HELLO", "3", "AUTH", "alice", "s3cret", "SETNAME", "ccinnredis"]])
        #expect(outcome.learnedPlan.sendHello)
    }

    @Test func fallsBackToRESP2AndLegacyAuthOnOldServer() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "HELLO": .reply(.err("ERR unknown command 'HELLO'"))
            case "AUTH": .reply(request.arguments.count == 2 ? .ok : .err("ERR wrong number of arguments for 'auth' command"))
            default: .reply(.ok)
            }
        }
        let plan = HandshakePlan(credentials: Credentials(password: "pw"), database: 2)
        let (connection, outcome) = try await Handshaker.open(endpoint: local, plan: plan, connector: backend.connector)
        #expect(outcome.protocolVersion == 2)
        #expect(await connection.protocolVersion == 2)
        #expect(outcome.helloFallbackReason?.contains("unknown command") == true)
        #expect(outcome.learnedPlan.sendHello == false)
        #expect(backend.commandNames == ["HELLO", "AUTH", "SELECT"])
        #expect(backend.commands[1] == ["AUTH", "pw"])
        #expect(backend.commands[2] == ["SELECT", "2"])
    }

    @Test func namedUserOnPreACLServerExplainsTheProblem() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "AUTH": .reply(.err("ERR wrong number of arguments for 'auth' command"))
            default: .reply(.ok)
            }
        }
        let plan = HandshakePlan(credentials: Credentials(username: "bob", password: "pw"), protocolPreference: .resp2)
        await #expect(throws: RedisError.self) {
            _ = try await Handshaker.open(endpoint: local, plan: plan, connector: backend.connector)
        }
        #expect(backend.commandNames == ["AUTH"])
    }

    @Test func peerDroppingHelloIsRetriedWithRESP2() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "HELLO": .drop
            case "AUTH": .reply(.ok)
            default: .reply(.ok)
            }
        }
        let plan = HandshakePlan(credentials: Credentials(password: "pw"))
        let (_, outcome) = try await Handshaker.open(endpoint: local, plan: plan, connector: backend.connector)
        #expect(outcome.helloDroppedConnection)
        #expect(outcome.protocolVersion == 2)
        #expect(backend.connectionCount == 2)
        #expect(backend.commandNames == ["HELLO", "AUTH"])
        #expect(outcome.learnedPlan.sendHello == false)
    }

    @Test func wrongPasswordIsAnAuthenticationError() async {
        let backend = FakeRedisBackend { _ in .reply(.err("WRONGPASS invalid username-password pair or user is disabled.")) }
        do {
            _ = try await Handshaker.open(endpoint: local, plan: HandshakePlan(credentials: Credentials(password: "bad")), connector: backend.connector)
            Issue.record("expected failure")
        } catch let error as RedisError {
            #expect(error.kind == .authentication)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func missingPasswordReportsNoAuth() async {
        let backend = FakeRedisBackend { _ in
            .reply(.err("NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO <proto> AUTH <user> <pass> option can be used"))
        }
        do {
            _ = try await Handshaker.open(endpoint: local, plan: HandshakePlan(), connector: backend.connector)
            Issue.record("expected failure")
        } catch let error as RedisError {
            #expect(error.kind == .authentication)
            #expect(error.message.contains("requires a password"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func passwordOnServerWithoutPasswordIsANoteNotAFailure() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "AUTH": .reply(.err("ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?"))
            default: .reply(.ok)
            }
        }
        let plan = HandshakePlan(credentials: Credentials(password: "unneeded"), protocolPreference: .resp2)
        let (_, outcome) = try await Handshaker.open(endpoint: local, plan: plan, connector: backend.connector)
        #expect(outcome.authenticationNote != nil)
    }

    @Test func requiredRESP3FailsOnOldServer() async {
        let backend = FakeRedisBackend { _ in .reply(.err("ERR unknown command 'HELLO'")) }
        await #expect(throws: RedisError.self) {
            _ = try await Handshaker.open(endpoint: local, plan: HandshakePlan(protocolPreference: .resp3), connector: backend.connector)
        }
    }

    @Test func resp2PreferenceNeverSendsHello() async throws {
        let backend = FakeRedisBackend { _ in .reply(.ok) }
        _ = try await Handshaker.open(endpoint: local, plan: HandshakePlan(protocolPreference: .resp2), connector: backend.connector)
        #expect(backend.commands.isEmpty)
    }

    @Test func selectFailureIsReported() async {
        let backend = FakeRedisBackend { request in
            request.name == "SELECT" ? .reply(.err("ERR SELECT is not allowed in cluster mode")) : .reply(helloReply())
        }
        do {
            _ = try await Handshaker.open(endpoint: local, plan: HandshakePlan(database: 3), connector: backend.connector)
            Issue.record("expected failure")
        } catch let error as RedisError {
            #expect(error.message.contains("database 3"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("Connection")
struct ConnectionTests {
    private func connection(_ backend: FakeRedisBackend) async throws -> RedisConnection {
        try await Handshaker.open(endpoint: local, plan: HandshakePlan(protocolPreference: .resp2), connector: backend.connector).0
    }

    @Test func pipelineReturnsErrorsInPlace() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "GET": .reply(.bulk("v"))
            case "INCR": .reply(.err("ERR value is not an integer or out of range"))
            default: .reply(.ok)
            }
        }
        let connection = try await connection(backend)
        let replies = try await connection.pipeline([RedisCommand("SET", ["k", "v"]), RedisCommand("INCR", ["k"]), RedisCommand("GET", ["k"])])
        #expect(replies.count == 3)
        #expect(replies[0] == .ok)
        #expect(replies[1].isError)
        #expect(replies[2].string == "v")
        await #expect(throws: RedisError.self) { try await connection.send(RedisCommand("INCR", ["k"])) }
        // A server error does not break the connection.
        #expect(await connection.isBroken == false)
    }

    @Test func pushFramesBetweenRepliesGoToTheHandler() async throws {
        let backend = FakeRedisBackend { request in
            request.name == "GET"
                ? .replies([.push([.bulk("invalidate"), .array([.bulk("k")])]), .bulk("value")])
                : .reply(.ok)
        }
        let connection = try await connection(backend)
        let received = OSAllocatedUnfairLockBox<[RESPValue]>([])
        await connection.setPushHandler { value in received.withLock { $0.append(value) } }
        let reply = try await connection.send(RedisCommand("GET", ["k"]))
        #expect(reply.string == "value")
        #expect(received.value.count == 1)
    }

    @Test func timeoutBreaksTheConnection() async throws {
        let backend = FakeRedisBackend { request in request.name == "BLPOP" ? .hang : .reply(.ok) }
        let connection = try await connection(backend)
        do {
            _ = try await connection.send(RedisCommand("BLPOP", ["q", "0"]), timeout: 0.2)
            Issue.record("expected timeout")
        } catch let error as RedisError {
            #expect(error.kind == .timeout)
        }
        #expect(await connection.isBroken)
        await #expect(throws: RedisError.self) { try await connection.send(RedisCommand("PING")) }
    }

    @Test func cancellationBreaksTheConnectionPromptly() async throws {
        let backend = FakeRedisBackend { request in request.name == "BLPOP" ? .hang : .reply(.ok) }
        let connection = try await connection(backend)
        let task = Task { try await connection.send(RedisCommand("BLPOP", ["q", "0"])) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: RedisError.self) { try result.get() }
        #expect(await connection.isBroken)
    }

    @Test func concurrentUseIsRejected() async throws {
        let backend = FakeRedisBackend { request in request.name == "BLPOP" ? .hang : .reply(.ok) }
        let connection = try await connection(backend)
        let blocked = Task { try await connection.send(RedisCommand("BLPOP", ["q", "0"]), timeout: 1) }
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await connection.send(RedisCommand("PING"))
            Issue.record("expected busy")
        } catch let error as RedisError {
            #expect(error.kind == .busy)
        }
        blocked.cancel()
        _ = await blocked.result
    }

    @Test func protocolViolationBreaksTheConnection() async throws {
        let backend = FakeRedisBackend { _ in .reply(.ok) }
        let connection = try await connection(backend)
        // Garbage the parser rejects arrives before the replies.
        backend.connection(0)?.injectBytes(Array("?garbage\r\n".utf8))
        await #expect(throws: RedisError.self) { try await connection.pipeline([RedisCommand("PING"), RedisCommand("PING")]) }
        #expect(await connection.isBroken)
    }
}

@Suite("Pool and node client")
struct PoolTests {
    @Test func poolNeverExceedsItsSizeAndQueuesWaiters() async throws {
        let backend = FakeRedisBackend { _ in .reply(.ok) }
        let node = NodeClient(endpoint: local, plan: HandshakePlan(protocolPreference: .resp2), connector: backend.connector, poolSize: 2)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await node.send(RedisCommand("PING")) }
            }
            try await group.waitForAll()
        }
        #expect(backend.connectionCount <= 2)
        let stats = await node.poolStatistics
        #expect(stats.open <= 2)
        await node.close()
    }

    @Test func brokenConnectionsAreReplaced() async throws {
        let backend = FakeRedisBackend { request in request.name == "BLPOP" ? .hang : .reply(.bulk("pong")) }
        let node = NodeClient(endpoint: local, plan: HandshakePlan(protocolPreference: .resp2), connector: backend.connector, poolSize: 1)
        await #expect(throws: RedisError.self) { try await node.send(RedisCommand("BLPOP", ["q", "0"]), timeout: 0.1) }
        let reply = try await node.send(RedisCommand("PING"))
        #expect(reply.string == "pong")
        #expect(backend.connectionCount == 2)
        await node.close()
    }

    @Test func learnedPlanIsReusedByLaterConnections() async throws {
        let backend = FakeRedisBackend { request in
            switch request.name {
            case "HELLO": .reply(.err("ERR unknown command 'HELLO'"))
            case "BLPOP": .hang
            default: .reply(.ok)
            }
        }
        let node = NodeClient(endpoint: local, plan: HandshakePlan(), connector: backend.connector, poolSize: 1)
        _ = try await node.send(RedisCommand("PING"))
        await #expect(throws: RedisError.self) { try await node.send(RedisCommand("BLPOP", ["q", "0"]), timeout: 0.1) }
        _ = try await node.send(RedisCommand("PING"))
        #expect(backend.commandNames.filter { $0 == "HELLO" }.count == 1)
        #expect(node.plan.sendHello == false)
        #expect(node.firstHandshake?.protocolVersion == 2)
        await node.close()
    }

    @Test func waitingForAConnectionIsCancellable() async throws {
        let backend = FakeRedisBackend { request in request.name == "BLPOP" ? .hang : .reply(.ok) }
        let node = NodeClient(endpoint: local, plan: HandshakePlan(protocolPreference: .resp2), connector: backend.connector, poolSize: 1, commandTimeout: nil)
        let holder = Task { try await node.send(RedisCommand("BLPOP", ["q", "0"])) }
        try await Task.sleep(for: .milliseconds(50))
        let waiter = Task { try await node.send(RedisCommand("PING")) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let waited = await waiter.result
        #expect(throws: (any Error).self) { try waited.get() } // cancelled while queued
        holder.cancel()
        _ = await holder.result
        await node.close()
    }
}

