import Foundation

/// Opens one SSH local forward per remote endpoint on demand, so Sentinel and Cluster nodes
/// discovered at runtime are reachable through the same bastion as the seed.
public actor TunnelManager {
    public nonisolated let configuration: SSHTunnelConfiguration
    private let secret: String?
    private var tunnels: [Endpoint: SSHTunnel] = [:]
    private var opening: [Endpoint: Task<SSHTunnel, any Error>] = [:]
    private var isClosed = false

    public init(configuration: SSHTunnelConfiguration, secret: String?) {
        self.configuration = configuration
        self.secret = secret
    }

    /// Local `127.0.0.1:port` forwarding to `remote` (opened if needed).
    public func localEndpoint(for remote: Endpoint) async throws -> Endpoint {
        guard !isClosed else { throw RedisError(.sshTunnel, "The SSH tunnels for this connection are closed") }
        if let tunnel = tunnels[remote], tunnel.isRunning { return tunnel.localAddress }
        if let pending = opening[remote] { return try await pending.value.localAddress }
        let configuration = configuration
        let secret = secret
        let task = Task { try await SSHTunnel.open(configuration: configuration, secret: secret, remote: remote) }
        opening[remote] = task
        defer { opening[remote] = nil }
        let tunnel = try await task.value
        if isClosed {
            tunnel.close()
            throw RedisError(.sshTunnel, "The SSH tunnels for this connection are closed")
        }
        tunnels[remote]?.close()
        tunnels[remote] = tunnel
        return tunnel.localAddress
    }

    public var openTunnelCount: Int { tunnels.values.filter(\.isRunning).count }

    public func closeAll() {
        isClosed = true
        for task in opening.values { task.cancel() }
        for tunnel in tunnels.values { tunnel.close() }
        tunnels.removeAll()
    }
}
