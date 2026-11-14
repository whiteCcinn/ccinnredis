import Foundation
import RESPWire

public enum ProtocolPreference: String, Codable, Sendable, CaseIterable, Identifiable {
    /// RESP3 via `HELLO 3` when the server supports it, RESP2 otherwise.
    case auto
    /// Never send HELLO (proxies, very old servers, managed services that misbehave).
    case resp2
    /// Require RESP3 (fails on servers older than 6.0).
    case resp3

    public var id: String { rawValue }
}

public struct Credentials: Sendable, Equatable {
    public var username: String?
    public var password: String?

    public init(username: String? = nil, password: String? = nil) {
        self.username = username?.nilIfBlank
        self.password = password?.isEmpty == false ? password : nil
    }

    /// ACL user other than `default`.
    var hasNamedUser: Bool { username.map { $0 != "default" } ?? false }
}

/// How new connections to a node are initialised. Starts optimistic and learns from the server
/// (e.g. `sendHello` becomes `false` once HELLO is known to be unsupported) so detection runs once.
public struct HandshakePlan: Sendable, Equatable {
    public var credentials: Credentials
    public var protocolPreference: ProtocolPreference
    public var database: Int
    public var clientName: String?
    /// Send HELLO (learned: `false` after HELLO failed or made the peer drop the connection).
    public var sendHello: Bool
    /// Send `CLIENT SETNAME` on RESP2 connections (only once detection proved a real Redis).
    public var setNameOnRESP2: Bool
    /// Send `READONLY` (cluster replica reads).
    public var readOnlyReplica: Bool

    public init(credentials: Credentials = Credentials(), protocolPreference: ProtocolPreference = .auto, database: Int = 0,
                clientName: String? = "ccinnredis", sendHello: Bool = true, setNameOnRESP2: Bool = false, readOnlyReplica: Bool = false) {
        self.credentials = credentials
        self.protocolPreference = protocolPreference
        self.database = max(0, database)
        self.clientName = clientName
        self.sendHello = sendHello && protocolPreference != .resp2
        self.setNameOnRESP2 = setNameOnRESP2
        self.readOnlyReplica = readOnlyReplica
    }
}

public struct HandshakeOutcome: Sendable {
    public var protocolVersion: Int
    /// The HELLO reply map (server, version, proto, id, mode, role, modules) when RESP3 was negotiated.
    public var hello: RESPValue?
    /// Why the connection uses RESP2 although HELLO was attempted.
    public var helloFallbackReason: String?
    /// The peer closed the connection in response to HELLO (twemproxy does this).
    public var helloDroppedConnection: Bool
    /// Informational note (e.g. a password was supplied but the server has none).
    public var authenticationNote: String?
    /// The plan to use for further connections.
    public var learnedPlan: HandshakePlan
}

public typealias EndpointConnector = @Sendable (Endpoint) async throws -> any ByteTransport

/// Opens and initialises connections according to a `HandshakePlan` (design D4).
public enum Handshaker {
    public static func open(endpoint: Endpoint, plan: HandshakePlan, connector: EndpointConnector,
                            limits: RESPLimits = RESPLimits(), timeout: Double? = 15) async throws -> (RedisConnection, HandshakeOutcome) {
        var plan = plan
        var outcome = HandshakeOutcome(protocolVersion: 2, hello: nil, helloFallbackReason: nil, helloDroppedConnection: false,
                                       authenticationNote: nil, learnedPlan: plan)
        var connection = RedisConnection(endpoint: endpoint, transport: try await connector(endpoint), limits: limits)
        var authenticated = false

        if plan.sendHello {
            var arguments: [RedisArgument] = ["3"]
            if let password = plan.credentials.password {
                arguments += ["AUTH", .string(plan.credentials.username ?? "default"), .string(password)]
            }
            if let name = plan.clientName { arguments += ["SETNAME", .string(name)] }
            do {
                let reply = try await connection.pipeline([RedisCommand("HELLO", arguments)], timeout: timeout)[0]
                if let message = reply.errorMessage {
                    if RedisError.isAuthenticationFailure(message) { throw authenticationError(message, plan: plan) }
                    guard plan.protocolPreference != .resp3 else {
                        throw RedisError(.unsupported, "This server does not support RESP3 (HELLO failed: \(message)). Choose RESP2 or Auto.")
                    }
                    outcome.helloFallbackReason = message
                    plan.sendHello = false
                } else {
                    let proto = reply["proto"]?.int ?? 2
                    outcome.protocolVersion = proto >= 3 ? 3 : 2
                    outcome.hello = reply
                    authenticated = plan.credentials.password != nil
                    await connection.setProtocolVersion(outcome.protocolVersion)
                }
            } catch let error as RedisError where error.isConnectionFailure && error.kind != .timeout {
                // The peer dropped the connection on HELLO (twemproxy): reconnect and use RESP2.
                guard plan.protocolPreference != .resp3 else { throw error }
                plan.sendHello = false
                outcome.helloDroppedConnection = true
                outcome.helloFallbackReason = "The server closed the connection when it received HELLO"
                connection = RedisConnection(endpoint: endpoint, transport: try await connector(endpoint), limits: limits)
            }
        }

        do {
            if !authenticated, let password = plan.credentials.password {
                outcome.authenticationNote = try await authenticate(connection, credentials: plan.credentials, password: password, timeout: timeout)
            }
            if plan.database != 0 {
                let reply = try await connection.pipeline([RedisCommand("SELECT", [.int(plan.database)])], timeout: timeout)[0]
                if let message = reply.errorMessage {
                    throw RedisError(.invalidArgument, "Cannot select database \(plan.database): \(message)", code: "SELECT")
                }
            }
            if outcome.protocolVersion == 2, plan.setNameOnRESP2, let name = plan.clientName {
                _ = try await connection.pipeline([RedisCommand("CLIENT", ["SETNAME", .string(name)])], timeout: timeout)
            }
            if plan.readOnlyReplica {
                _ = try await connection.pipeline([RedisCommand("READONLY")], timeout: timeout)
            }
        } catch {
            await connection.close()
            throw error
        }
        outcome.learnedPlan = plan
        return (connection, outcome)
    }

    /// `AUTH` for legacy and ACL servers; returns an informational note when the server needs no password.
    private static func authenticate(_ connection: RedisConnection, credentials: Credentials, password: String,
                                     timeout: Double?) async throws -> String? {
        var command = credentials.hasNamedUser
            ? RedisCommand("AUTH", [.string(credentials.username ?? "default"), .string(password)])
            : RedisCommand("AUTH", [.string(password)])
        for attempt in 0..<2 {
            let reply = try await connection.pipeline([command], timeout: timeout)[0]
            guard let message = reply.errorMessage else { return nil }
            let lower = message.lowercased()
            if lower.contains("no password is set") || lower.contains("without any password configured") {
                return "A password was supplied but the server does not require one"
            }
            if attempt == 0, lower.contains("wrong number of arguments") || lower.contains("syntax error") {
                // Pre-6.0 server: only `AUTH password` exists.
                if credentials.hasNamedUser {
                    throw RedisError(.authentication, "This server predates ACL users (Redis < 6.0). Leave the user name empty and use the password only.")
                }
                command = RedisCommand("AUTH", [.string(password)])
                continue
            }
            throw authenticationError(message, plan: nil)
        }
        throw RedisError(.authentication, "Authentication failed")
    }

    private static func authenticationError(_ message: String, plan: HandshakePlan?) -> RedisError {
        let upper = message.uppercased()
        if upper.hasPrefix("NOAUTH") || upper.contains("AUTHENTICATION REQUIRED") {
            return RedisError(.authentication, "The server requires a password. Enter the password (and ACL user if any) for this connection.", code: "NOAUTH")
        }
        if upper.hasPrefix("WRONGPASS") || upper.contains("INVALID PASSWORD") || upper.contains("INVALID USERNAME-PASSWORD") {
            return RedisError(.authentication, "Wrong user name or password (\(message))", code: "WRONGPASS")
        }
        return RedisError(.authentication, message, code: upper.split(separator: " ").first.map(String.init))
    }
}
