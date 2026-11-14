import Foundation
import RESPWire

/// Lazily created `NodeClient` per node address, sharing the learned handshake plan.
actor NodeRegistry {
    private var nodes: [Endpoint: NodeClient] = [:]
    private var basePlan: HandshakePlan
    private let connector: EndpointConnector
    private let poolSize: Int
    private let commandTimeout: Double?
    private let limits: RESPLimits
    private var isClosed = false

    init(basePlan: HandshakePlan, connector: @escaping EndpointConnector, poolSize: Int, commandTimeout: Double?, limits: RESPLimits) {
        self.basePlan = basePlan
        self.connector = connector
        self.poolSize = poolSize
        self.commandTimeout = commandTimeout
        self.limits = limits
    }

    func node(_ endpoint: Endpoint, readOnlyReplica: Bool = false) throws -> NodeClient {
        guard !isClosed else { throw RedisError(.connectionClosed, "The connection is closed") }
        if let existing = nodes[endpoint] { return existing }
        var plan = basePlan
        plan.readOnlyReplica = readOnlyReplica
        let node = NodeClient(endpoint: endpoint, plan: plan, connector: connector, poolSize: poolSize,
                              commandTimeout: commandTimeout, limits: limits)
        nodes[endpoint] = node
        return node
    }

    /// Adopts what the first node learned (HELLO support, SETNAME) for nodes created later.
    func learn(from plan: HandshakePlan) {
        basePlan.sendHello = plan.sendHello
        basePlan.setNameOnRESP2 = plan.setNameOnRESP2
    }

    func updateAll(_ transform: @escaping @Sendable (inout HandshakePlan) -> Void) {
        transform(&basePlan)
        for node in nodes.values { node.updatePlan(transform) }
    }

    func remove(_ endpoint: Endpoint) async {
        guard let node = nodes.removeValue(forKey: endpoint) else { return }
        await node.close()
    }

    var endpoints: [Endpoint] { Array(nodes.keys) }

    /// Closes every pool so new connections are made with the updated plan (e.g. another database).
    func resetPools() async {
        let all = nodes.values
        nodes.removeAll()
        for node in all { await node.close() }
    }

    var plan: HandshakePlan { basePlan }

    func closeAll() async {
        isClosed = true
        let all = nodes.values
        nodes.removeAll()
        for node in all { await node.close() }
    }
}
