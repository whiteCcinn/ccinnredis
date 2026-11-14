import Foundation

/// A Redis server address: TCP host and port, or a Unix domain socket path (host starting with `/`).
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible, Comparable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 6379) {
        self.host = host
        self.port = port
    }

    public static func unixSocket(_ path: String) -> Endpoint { Endpoint(host: path, port: 0) }

    public var isUnixSocket: Bool { host.hasPrefix("/") || host.hasPrefix("~/") }
    public var isIPv6: Bool { !isUnixSocket && host.contains(":") }

    public var description: String {
        if isUnixSocket { return host }
        return isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public static func < (lhs: Endpoint, rhs: Endpoint) -> Bool {
        (lhs.host, lhs.port) < (rhs.host, rhs.port)
    }

    /// Parses `host`, `host:port`, `[v6]:port`, bare IPv6 and Unix socket paths.
    public static func parse(_ text: String, defaultPort: Int = 6379) -> Endpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return .unixSocket(trimmed) }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { return Endpoint(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65_535).contains(port) else { return nil }
            return Endpoint(host: host, port: port)
        }
        let colons = trimmed.filter { $0 == ":" }.count
        if colons > 1 { return Endpoint(host: trimmed, port: defaultPort) } // bare IPv6
        if colons == 1, let separator = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<separator])
            guard !host.isEmpty, let port = Int(trimmed[trimmed.index(after: separator)...]), (1...65_535).contains(port) else { return nil }
            return Endpoint(host: host, port: port)
        }
        return Endpoint(host: trimmed, port: defaultPort)
    }
}
