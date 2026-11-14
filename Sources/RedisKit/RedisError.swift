import Foundation
import RESPWire

/// Every failure surfaced by RedisKit. Messages are user-facing and never contain secrets.
public struct RedisError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidArgument
        case network
        case timeout
        case dns
        case tls
        case sshTunnel
        case authentication
        /// The server answered with an error reply. The connection stays usable.
        case server
        case protocolViolation
        case cancelled
        case connectionClosed
        case busy
        /// The command or feature is not available on this server, version or proxy.
        case unsupported
        /// Blocked by read-only mode before being sent.
        case readOnly
        /// Cluster/sentinel topology could not be resolved.
        case topology
    }

    public let kind: Kind
    public let message: String
    /// First word of a server error reply (`ERR`, `WRONGTYPE`, `MOVED`, `NOAUTH`…).
    public let code: String?

    public init(_ kind: Kind, _ message: String, code: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public static func cancelled() -> RedisError { RedisError(.cancelled, "The operation was cancelled") }

    /// Builds the error for an error reply, classifying authentication failures.
    public static func server(_ message: String) -> RedisError {
        let code = message.split(separator: " ", maxSplits: 1).first.map(String.init)
        let kind: Kind = isAuthenticationFailure(message) ? .authentication : .server
        return RedisError(kind, message.isEmpty ? "Server error" : message, code: code)
    }

    static func isAuthenticationFailure(_ message: String) -> Bool {
        let upper = message.uppercased()
        return upper.hasPrefix("WRONGPASS") || upper.hasPrefix("NOAUTH") || upper.hasPrefix("ERR INVALID PASSWORD")
            || upper.hasPrefix("INVALIDPASSWORD") || upper.contains("AUTHENTICATION REQUIRED")
            || upper.hasPrefix("ERR INVALID USERNAME-PASSWORD PAIR")
    }

    /// Errors after which the connection must not be reused.
    public var breaksConnection: Bool {
        switch kind {
        case .server, .authentication, .invalidArgument, .busy, .unsupported, .readOnly: false
        default: true
        }
    }

    /// The server (or a proxy in front of it) does not know or refuses the command.
    public var isCommandUnavailable: Bool {
        guard kind == .server || kind == .unsupported else { return false }
        return Self.looksLikeUnavailableCommand(message)
    }

    static func looksLikeUnavailableCommand(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unknown command") || lower.contains("unknown subcommand")
            || lower.contains("not allowed") || lower.contains("not supported") || lower.contains("unsupported command")
            || lower.contains("command not support") || lower.contains("forbid") || lower.contains("disabled")
            || lower.contains("not permitted") || lower.contains("unknown or disabled command")
            || lower.hasPrefix("err unsupported")
    }

    /// `-NOPERM` (ACL).
    public var isPermissionDenied: Bool { code?.uppercased() == "NOPERM" || message.uppercased().hasPrefix("NOPERM") }

    static let connectStageCode = "CONNECT"

    /// The failure happened while establishing a connection, so no command was sent.
    public var isConnectStage: Bool { code == Self.connectStageCode }

    /// Network-level failures that happened before or instead of a reply.
    public var isConnectionFailure: Bool {
        switch kind {
        case .network, .connectionClosed, .dns, .timeout: true
        default: false
        }
    }
}

extension RESPError {
    var redisError: RedisError { RedisError(.protocolViolation, message) }
}
