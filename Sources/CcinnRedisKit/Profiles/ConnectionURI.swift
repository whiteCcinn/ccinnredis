import Foundation
import RedisKit

/// Imports and exports connection URIs:
/// `redis://[user[:password]@]host[:port][/db][?options]`, `rediss://` (TLS), `unix:///path[?db=n]`,
/// `redis-sentinel://[:pw@]h1:p1,h2:p2[/db]?master=name`, `redis-cluster://h1:p1,h2:p2`.
/// Options: `protocol=2|3`, `readonly=true`, `name=…`, `db=n`, `user=…`, `password=…`.
public enum ConnectionURI {
    public struct Parsed: Sendable {
        public var profile: ConnectionProfile
        public var password: String?
    }

    public struct ParseError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ text: String) throws -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { throw ParseError(message: "Not a Redis URI (expected redis://…)") }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        var rest = String(trimmed[schemeEnd.upperBound...])
        var profile = ConnectionProfile()
        var password: String?

        var query: [String: String] = [:]
        if let question = rest.firstIndex(of: "?") {
            for item in rest[rest.index(after: question)...].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if pair.count == 2 { query[pair[0].lowercased()] = pair[1] }
            }
            rest = String(rest[..<question])
        }

        switch scheme {
        case "unix":
            guard rest.hasPrefix("/") else { throw ParseError(message: "unix:// URIs need an absolute socket path") }
            profile.useUnixSocket = true
            profile.host = rest.removingPercentEncoding ?? rest
        case "redis", "rediss", "valkey", "valkeys", "redis-sentinel", "redis-cluster":
            if scheme == "rediss" || scheme == "valkeys" { profile.tls = TLSOptions() }
            // userinfo
            if let at = rest.lastIndex(of: "@") {
                let userInfo = String(rest[..<at])
                rest = String(rest[rest.index(after: at)...])
                let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let user = parts[0].removingPercentEncoding ?? parts[0]
                if parts.count == 2 {
                    profile.username = user
                    let decoded = parts[1].removingPercentEncoding ?? parts[1]
                    password = decoded.isEmpty ? nil : decoded
                } else {
                    // `redis://password@host` (legacy form used by some clients).
                    password = user.isEmpty ? nil : user
                }
            }
            // path = /db
            var hostPart = rest
            if let slash = rest.firstIndex(of: "/") {
                hostPart = String(rest[..<slash])
                let path = rest[rest.index(after: slash)...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !path.isEmpty {
                    guard let database = Int(path), database >= 0 else { throw ParseError(message: "'\(path)' is not a database number") }
                    profile.database = database
                }
            }
            guard !hostPart.isEmpty else { throw ParseError(message: "The URI has no host") }
            let hosts = hostPart.split(separator: ",").map(String.init)
            var endpoints: [Endpoint] = []
            for host in hosts {
                let defaultPort = scheme == "redis-sentinel" ? 26379 : 6379
                guard let endpoint = Endpoint.parse(host, defaultPort: defaultPort), !endpoint.host.isEmpty else {
                    throw ParseError(message: "'\(host)' is not a valid host[:port]")
                }
                endpoints.append(endpoint)
            }
            switch scheme {
            case "redis-sentinel":
                profile.mode = .sentinel
                profile.sentinelNodes = endpoints.map(\.description).joined(separator: ", ")
                profile.sentinelMasterName = query["master"] ?? query["mastername"] ?? query["service"] ?? ""
            case "redis-cluster":
                profile.mode = .cluster
                profile.clusterSeeds = endpoints.map(\.description).joined(separator: ", ")
                profile.database = 0
            default:
                guard let first = endpoints.first else { throw ParseError(message: "The URI has no host") }
                if endpoints.count > 1 {
                    profile.mode = .cluster
                    profile.clusterSeeds = endpoints.map(\.description).joined(separator: ", ")
                } else {
                    profile.host = first.host
                    profile.port = first.port
                }
            }
        default:
            throw ParseError(message: "Unsupported scheme '\(scheme)://'. Use redis://, rediss://, unix://, redis-sentinel:// or redis-cluster://")
        }

        if let db = query["db"] {
            guard let database = Int(db), database >= 0 else { throw ParseError(message: "'\(db)' is not a database number") }
            profile.database = database
        }
        if let user = query["user"] ?? query["username"] { profile.username = user }
        if let secret = query["password"] { password = secret }
        if let proto = query["protocol"] ?? query["resp"] { profile.protocolPreference = proto == "2" ? .resp2 : proto == "3" ? .resp3 : .auto }
        if let flag = query["readonly"] ?? query["read_only"] { profile.readOnly = ["1", "true", "yes"].contains(flag.lowercased()) }
        if let name = query["name"] { profile.name = name }
        if let skip = query["insecure"] ?? query["ssl_cert_reqs"], profile.tls != nil, ["1", "true", "none"].contains(skip.lowercased()) {
            profile.tls?.allowInvalidCertificates = true
        }
        return Parsed(profile: profile, password: password)
    }

    /// URI for a profile, without any secret.
    public static func string(for profile: ConnectionProfile) -> String {
        let user = profile.username.isEmpty ? "" : (profile.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? profile.username) + "@"
        switch profile.mode {
        case .standalone:
            if profile.useUnixSocket { return "unix://\(profile.host)" + (profile.database != 0 ? "?db=\(profile.database)" : "") }
            let scheme = profile.tls == nil ? "redis" : "rediss"
            let database = profile.database != 0 ? "/\(profile.database)" : ""
            return "\(scheme)://\(user)\(profile.endpoint)\(database)"
        case .sentinel:
            let hosts = profile.sentinelEndpoints.map(\.description).joined(separator: ",")
            let master = profile.sentinelMasterName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile.sentinelMasterName
            return "redis-sentinel://\(user)\(hosts)/\(profile.database)?master=\(master)"
        case .cluster:
            return "redis-cluster://\(user)" + profile.clusterEndpoints.map(\.description).joined(separator: ",")
        }
    }
}
