import Foundation

/// A bidirectional byte stream to one server. `close()` must be safe to call from any thread at any
/// time (it is used for cancellation) and must make pending calls fail promptly.
public protocol ByteTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Returns the next chunk of bytes (at least one byte) or throws when the stream ends.
    func receive() async throws -> [UInt8]
    func close()
}

public struct TLSOptions: Sendable, Equatable, Hashable, Codable {
    /// Skip certificate validation entirely (self-signed test servers). Shown with a warning in the UI.
    public var allowInvalidCertificates: Bool
    /// Validate the chain but not the host name.
    public var allowInvalidHostnames: Bool
    /// PEM file with one or more CA certificates to trust instead of the system roots.
    public var caFile: String?
    /// PKCS#12 file with the client certificate and private key (mutual TLS).
    public var clientCertificateFile: String?
    /// Server name for SNI and verification when it differs from the dialled host (tunnels, address maps).
    public var serverName: String?

    public init(allowInvalidCertificates: Bool = false, allowInvalidHostnames: Bool = false, caFile: String? = nil,
                clientCertificateFile: String? = nil, serverName: String? = nil) {
        self.allowInvalidCertificates = allowInvalidCertificates
        self.allowInvalidHostnames = allowInvalidHostnames
        self.caFile = caFile
        self.clientCertificateFile = clientCertificateFile
        self.serverName = serverName
    }
}

public struct TransportOptions: Sendable, Equatable {
    /// Seconds to establish TCP (+TLS).
    public var connectTimeout: Double
    public var tls: TLSOptions?
    /// Password of the PKCS#12 client certificate (kept out of `TLSOptions` so it is never persisted).
    public var clientCertificatePassword: String?

    public init(connectTimeout: Double = 10, tls: TLSOptions? = nil, clientCertificatePassword: String? = nil) {
        self.connectTimeout = connectTimeout
        self.tls = tls
        self.clientCertificatePassword = clientCertificatePassword
    }
}

public typealias TransportFactory = @Sendable (Endpoint, TransportOptions) async throws -> any ByteTransport

public enum Transports {
    /// TCP, TLS or Unix sockets via Network.framework.
    public static let network: TransportFactory = { endpoint, options in
        try await NetworkTransport.connect(to: endpoint, options: options)
    }
}
