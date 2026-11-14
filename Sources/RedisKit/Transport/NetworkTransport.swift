import Foundation
import Network
import os
import Security

/// `ByteTransport` over Network.framework (TCP, optional TLS, Unix sockets).
final class NetworkTransport: ByteTransport, @unchecked Sendable {
    // NWConnection is thread-safe; the connect handshake guards its one-shot continuation with a lock.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let endpoint: Endpoint

    private init(connection: NWConnection, queue: DispatchQueue, endpoint: Endpoint) {
        self.connection = connection
        self.queue = queue
        self.endpoint = endpoint
    }

    static func connect(to endpoint: Endpoint, options: TransportOptions) async throws -> NetworkTransport {
        let parameters = try makeParameters(for: endpoint, options: options)
        let target: NWEndpoint
        if endpoint.isUnixSocket {
            target = .unix(path: (endpoint.host as NSString).expandingTildeInPath)
        } else {
            let host = endpoint.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { throw RedisError(.invalidArgument, "Enter a host name") }
            guard (1...65_535).contains(endpoint.port), let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)) else {
                throw RedisError(.invalidArgument, "Invalid port \(endpoint.port)")
            }
            target = .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        let queue = DispatchQueue(label: "ccinnredis.transport.\(endpoint)", qos: .userInitiated)
        let connection = NWConnection(to: target, using: parameters)
        let transport = NetworkTransport(connection: connection, queue: queue, endpoint: endpoint)
        try await transport.start(timeout: options.connectTimeout, usesTLS: options.tls != nil)
        return transport
    }

    private func start(timeout: Double, usesTLS: Bool) async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        let endpoint = self.endpoint
        let connection = self.connection
        let queue = self.queue

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                @Sendable func finish(_ result: Result<Void, RedisError>) {
                    let first = once.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    connection.stateUpdateHandler = nil
                    switch result {
                    case .success: continuation.resume()
                    case let .failure(error):
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case let .failed(error): finish(.failure(Self.describe(error, endpoint: endpoint, tls: usesTLS)))
                    // Network.framework would keep retrying (e.g. connection refused); fail fast instead.
                    case let .waiting(error): finish(.failure(Self.describe(error, endpoint: endpoint, tls: usesTLS)))
                    case .cancelled: finish(.failure(RedisError(.cancelled, "Connection to \(endpoint) was cancelled")))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    finish(.failure(RedisError(.timeout, "Timed out after \(Int(timeout))s connecting to \(endpoint)")))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let connection = self.connection
        let endpoint = self.endpoint
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RedisError(.network, "Failed to send to \(endpoint): \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> [UInt8] {
        let connection = self.connection
        let endpoint = self.endpoint
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    if case .posix(.ECANCELED) = error {
                        continuation.resume(throwing: RedisError(.connectionClosed, "Connection to \(endpoint) was closed"))
                    } else {
                        continuation.resume(throwing: RedisError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)"))
                    }
                } else if isComplete {
                    continuation.resume(throwing: RedisError(.connectionClosed, "\(endpoint) closed the connection"))
                } else {
                    continuation.resume(throwing: RedisError(.network, "Connection to \(endpoint) returned no data"))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    // MARK: Parameters

    private static func makeParameters(for endpoint: Endpoint, options: TransportOptions) throws -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = Int(max(1, options.connectTimeout.rounded(.up)))

        guard let tlsOptions = options.tls else {
            return NWParameters(tls: nil, tcp: tcp)
        }
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        let verificationHost = tlsOptions.serverName?.nilIfBlank ?? endpoint.host
        if !endpoint.isUnixSocket, !verificationHost.isEmpty, !verificationHost.contains(":") {
            sec_protocol_options_set_tls_server_name(security, verificationHost)
        }
        if let file = tlsOptions.clientCertificateFile?.nilIfBlank {
            let identity = try TLSMaterial.loadIdentity(pkcs12Path: file, password: options.clientCertificatePassword)
            guard let secIdentity = sec_identity_create(identity) else {
                throw RedisError(.tls, "Could not use the client certificate in \(file)")
            }
            sec_protocol_options_set_local_identity(security, secIdentity)
        }

        let anchors = try tlsOptions.caFile?.nilIfBlank.map(TLSMaterial.loadCertificates(pemPath:))
        if tlsOptions.allowInvalidCertificates || tlsOptions.allowInvalidHostnames || anchors != nil || tlsOptions.serverName != nil {
            let allowInvalidCertificates = tlsOptions.allowInvalidCertificates
            let allowInvalidHostnames = tlsOptions.allowInvalidHostnames
            sec_protocol_options_set_verify_block(security, { _, trustRef, complete in
                if allowInvalidCertificates {
                    complete(true)
                    return
                }
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                if let anchors {
                    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, true)
                }
                let policy = allowInvalidHostnames ? SecPolicyCreateBasicX509() : SecPolicyCreateSSL(true, verificationHost as CFString)
                SecTrustSetPolicies(trust, policy)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, DispatchQueue.global(qos: .userInitiated))
        }
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func describe(_ error: NWError, endpoint: Endpoint, tls: Bool) -> RedisError {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED:
                return RedisError(.network, "Connection refused by \(endpoint). Is Redis running and listening on that port?")
            case .ETIMEDOUT:
                return RedisError(.timeout, "Timed out connecting to \(endpoint)")
            case .EHOSTUNREACH, .ENETUNREACH:
                return RedisError(.network, "\(endpoint) is unreachable from this network")
            case .ENOENT:
                return RedisError(.network, "No Unix socket at \(endpoint)")
            case .EACCES:
                return RedisError(.network, "Permission denied opening \(endpoint)")
            default:
                return RedisError(.network, "Could not connect to \(endpoint): \(error.localizedDescription)")
            }
        case .dns:
            return RedisError(.dns, "Could not resolve host \(endpoint.host)")
        case .tls:
            return RedisError(.tls, "TLS handshake with \(endpoint) failed: \(error.localizedDescription)")
        default:
            return RedisError(tls ? .tls : .network, "Could not connect to \(endpoint): \(error.localizedDescription)")
        }
    }
}

enum TLSMaterial {
    static func loadCertificates(pemPath path: String) throws -> [SecCertificate] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            if let data = FileManager.default.contents(atPath: expanded), let certificate = SecCertificateCreateWithData(nil, data as CFData) {
                return [certificate] // DER
            }
            throw RedisError(.tls, "Cannot read CA file \(path)")
        }
        var certificates: [SecCertificate] = []
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var remainder = Substring(text)
        while let start = remainder.range(of: begin), let finish = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
            let base64 = remainder[start.upperBound..<finish.lowerBound].filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(base64)), let certificate = SecCertificateCreateWithData(nil, data as CFData) {
                certificates.append(certificate)
            }
            remainder = remainder[finish.upperBound...]
        }
        guard !certificates.isEmpty else { throw RedisError(.tls, "No certificates found in \(path)") }
        return certificates
    }

    static func loadIdentity(pkcs12Path path: String, password: String?) throws -> SecIdentity {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw RedisError(.tls, "Cannot read client certificate \(path)")
        }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password ?? ""] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            throw RedisError(.tls, "Could not import \(path) (status \(status)). Provide a PKCS#12 (.p12) file and its password.")
        }
        let identityRef = identityValue as CFTypeRef
        guard CFGetTypeID(identityRef) == SecIdentityGetTypeID() else {
            throw RedisError(.tls, "\(path) does not contain a client identity")
        }
        // The CF type id was verified above; `unsafeDowncast` avoids a trapping cast.
        return unsafeDowncast(identityRef, to: SecIdentity.self)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
