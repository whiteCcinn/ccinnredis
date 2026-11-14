import Foundation

/// Rewrites addresses announced by cluster nodes or sentinels before connecting (Docker, NAT,
/// port-forwarded clusters). One rule per line: `from => to`, where each side is `host` or `host:port`.
/// `host:port` rules match exactly; `host` rules replace the host and keep (or replace) the port.
public struct AddressMap: Sendable, Hashable, Codable {
    public struct Rule: Sendable, Hashable, Codable {
        public var fromHost: String
        public var fromPort: Int?
        public var toHost: String
        public var toPort: Int?
    }

    public private(set) var rules: [Rule]

    public init() { rules = [] }

    public init(rules text: String) throws {
        var rules: [Rule] = []
        for (number, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let separators = ["=>", "->", " = ", "="]
            guard let separator = separators.first(where: { line.contains($0) }),
                  let range = line.range(of: separator) else {
                throw RedisError(.invalidArgument, "Address map line \(number + 1): use 'from => to'")
            }
            let left = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let from = Self.side(left), let to = Self.side(right) else {
                throw RedisError(.invalidArgument, "Address map line \(number + 1): '\(line)' is not 'host[:port] => host[:port]'")
            }
            rules.append(Rule(fromHost: from.host, fromPort: from.port, toHost: to.host, toPort: to.port))
        }
        self.rules = rules
    }

    public var isEmpty: Bool { rules.isEmpty }

    public var text: String {
        rules.map { rule in
            let from = rule.fromPort.map { "\(rule.fromHost):\($0)" } ?? rule.fromHost
            let to = rule.toPort.map { "\(rule.toHost):\($0)" } ?? rule.toHost
            return "\(from) => \(to)"
        }.joined(separator: "\n")
    }

    public func resolve(_ endpoint: Endpoint) -> Endpoint {
        guard !endpoint.isUnixSocket else { return endpoint }
        if let exact = rules.first(where: { $0.fromPort == endpoint.port && $0.fromHost.caseInsensitiveCompare(endpoint.host) == .orderedSame }) {
            return Endpoint(host: exact.toHost, port: exact.toPort ?? endpoint.port)
        }
        if let hostRule = rules.first(where: { $0.fromPort == nil && $0.fromHost.caseInsensitiveCompare(endpoint.host) == .orderedSame }) {
            return Endpoint(host: hostRule.toHost, port: hostRule.toPort ?? endpoint.port)
        }
        return endpoint
    }

    private static func side(_ text: String) -> (host: String, port: Int?)? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.hasPrefix("[") || text.filter({ $0 == ":" }).count == 1 {
            guard let endpoint = Endpoint.parse(text, defaultPort: -1) else { return nil }
            return (endpoint.host, endpoint.port == -1 ? nil : endpoint.port)
        }
        return (text, nil)
    }
}
