import Foundation
import RESPWire

/// All traffic to one node: a bounded pool of exclusive connections sharing a learned handshake plan.
public final class NodeClient: Sendable {
    public let endpoint: Endpoint
    public let commandTimeout: Double?
    private let pool: ConnectionPool
    private let connector: EndpointConnector
    private let limits: RESPLimits
    private let planBox: OSAllocatedUnfairLockBox<HandshakePlan>
    private let outcomeBox = OSAllocatedUnfairLockBox<HandshakeOutcome?>(nil)

    /// Idle time after which a pooled connection is checked with PING before reuse (servers close idle
    /// clients after `timeout` seconds; a dead socket would otherwise fail the user's command).
    static let healthCheckAfter: Duration = .seconds(20)

    public init(endpoint: Endpoint, plan: HandshakePlan, connector: @escaping EndpointConnector, poolSize: Int = 4,
                commandTimeout: Double? = 30, limits: RESPLimits = RESPLimits()) {
        self.endpoint = endpoint
        self.commandTimeout = commandTimeout
        self.connector = connector
        self.limits = limits
        let planBox = OSAllocatedUnfairLockBox(plan)
        let outcomeBox = self.outcomeBox
        self.planBox = planBox
        pool = ConnectionPool(maxSize: poolSize) {
            let (connection, outcome) = try await Handshaker.open(endpoint: endpoint, plan: planBox.value, connector: connector,
                                                                  limits: limits, timeout: commandTimeout.map { min($0, 15) } ?? 15)
            planBox.withLock { $0 = outcome.learnedPlan }
            outcomeBox.withLock { if $0 == nil { $0 = outcome } }
            return connection
        }
    }

    public var plan: HandshakePlan { planBox.value }

    /// Outcome of the first successful handshake (protocol, HELLO reply, fallback reasons).
    public var firstHandshake: HandshakeOutcome? { outcomeBox.value }

    public func updatePlan(_ transform: @Sendable (inout HandshakePlan) -> Void) {
        planBox.withLock { transform(&$0) }
    }

    /// Runs `body` with an exclusively leased, health-checked connection.
    public func withConnection<T: Sendable>(_ body: (RedisConnection) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            let connection = try await pool.checkout()
            if attempt < 2, await connection.idleDuration > Self.healthCheckAfter {
                do {
                    _ = try await connection.pipeline([RedisCommand("PING")], timeout: 3)
                } catch {
                    await pool.checkin(connection) // broken → discarded by the pool
                    attempt += 1
                    continue
                }
            }
            do {
                let result = try await body(connection)
                await pool.checkin(connection)
                return result
            } catch {
                await pool.checkin(connection)
                throw error
            }
        }
    }

    /// Pipelines commands on one connection; error replies are values.
    public func pipeline(_ commands: [RedisCommand], timeout: Double?? = nil) async throws -> [RESPValue] {
        let limit = timeout ?? commandTimeout
        return try await withConnection { try await $0.pipeline(commands, timeout: limit) }
    }

    /// Sends one command; error replies are thrown.
    @discardableResult
    public func send(_ command: RedisCommand, timeout: Double?? = nil) async throws -> RESPValue {
        let reply = try await pipeline([command], timeout: timeout)[0]
        if let message = reply.errorMessage { throw RedisError.server(message) }
        return reply
    }

    /// A fresh connection outside the pool (console sessions, Pub/Sub, MONITOR). The caller closes it.
    public func dedicatedConnection(plan override: HandshakePlan? = nil) async throws -> (RedisConnection, HandshakeOutcome) {
        try await Handshaker.open(endpoint: endpoint, plan: override ?? planBox.value, connector: connector, limits: limits,
                                  timeout: commandTimeout.map { min($0, 15) } ?? 15)
    }

    public var poolStatistics: (open: Int, idle: Int, waiting: Int) {
        get async { await pool.statistics }
    }

    public func close() async {
        await pool.close()
    }
}
