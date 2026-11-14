import Foundation

/// How a probe failed.
public enum ProbeFailure: Sendable, Equatable {
    /// The peer closed the connection (twemproxy does this for unsupported commands).
    case dropped
    case message(String)
}

/// Recognises proxies from their behaviour (design D6).
public enum ProxyDetector {
    /// Flavor implied by how `INFO` failed.
    public static func classify(infoError: ProbeFailure, helloDropped: Bool) -> ProxyFlavor {
        switch infoError {
        case .dropped:
            return .twemproxy
        case let .message(message):
            let lower = message.lowercased()
            if lower.contains("unsupported command") { return .envoy }
            if lower.contains("handle request") || lower.contains("not allowed") { return .codis }
            if lower.contains("forbid") { return .predixy }
            if lower.contains("command not support") || lower.contains("not support") { return .cloud }
            return helloDropped ? .twemproxy : .unknown
        }
    }

    /// Flavor implied by INFO content, or `nil` when it looks like a real server.
    public static func flavor(fromInfo info: InfoSnapshot) -> ProxyFlavor? {
        if info.section("Proxy") != nil, info["redis_version"] == nil { return .predixy }
        if info["proxy_version"] != nil || info["proxy_mode"] != nil || info.section("Proxy") != nil { return .cloud }
        if info["redis_version"] == nil, info["valkey_version"] == nil, info["dragonfly_version"] == nil, !info.isEmpty { return .unknown }
        return nil
    }
}
