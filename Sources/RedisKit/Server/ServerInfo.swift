import Foundation
import RESPWire

/// `major.minor.patch` of a server.
public struct ServerVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "7.2.4", "8.0-m02", "2.8.24", "255.255.255" (unstable builds); `nil` without a leading number.
    public init?(parsing text: String) {
        var numbers: [Int] = []
        var current = ""
        for character in text.trimmingCharacters(in: .whitespaces) {
            if character.isASCII, character.isNumber {
                current.append(character)
                guard current.count <= 9 else { return nil }
            } else if character == "." {
                guard let value = Int(current) else { break }
                numbers.append(value)
                current = ""
                if numbers.count == 3 { break }
            } else {
                break
            }
        }
        if let value = Int(current), numbers.count < 3 { numbers.append(value) }
        guard let major = numbers.first else { return nil }
        self.init(major, numbers.count > 1 ? numbers[1] : 0, numbers.count > 2 ? numbers[2] : 0)
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public var shortDescription: String { patch == 0 ? "\(major).\(minor)" : description }
}

/// Parsed `INFO` reply: ordered sections of `key:value` lines.
public struct InfoSnapshot: Sendable, Equatable {
    public struct Section: Sendable, Equatable, Identifiable {
        public var name: String
        public var entries: [(key: String, value: String)]
        public var id: String { name }

        public static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.name == rhs.name && lhs.entries.elementsEqual(rhs.entries) { $0.key == $1.key && $0.value == $1.value }
        }
    }

    public var sections: [Section]
    private var index: [String: String]

    public init(sections: [Section]) {
        self.sections = sections
        var index: [String: String] = [:]
        for section in sections {
            for entry in section.entries where index[entry.key] == nil { index[entry.key] = entry.value }
        }
        self.index = index
    }

    public static func parse(_ text: String) -> InfoSnapshot {
        var sections: [Section] = []
        var current = Section(name: "", entries: [])
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if !current.entries.isEmpty || !current.name.isEmpty { sections.append(current) }
                current = Section(name: line.dropFirst().trimmingCharacters(in: .whitespaces), entries: [])
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            current.entries.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
        }
        if !current.entries.isEmpty || !current.name.isEmpty { sections.append(current) }
        return InfoSnapshot(sections: sections)
    }

    public subscript(key: String) -> String? { index[key] }

    public func int(_ key: String) -> Int64? { index[key].flatMap { Int64($0) } }
    public func double(_ key: String) -> Double? { index[key].flatMap { Double($0) } }

    public func section(_ name: String) -> Section? {
        sections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Keyspace lines (`db0:keys=1,expires=0,avg_ttl=0`).
    public var keyspace: [KeyspaceEntry] {
        (section("Keyspace")?.entries ?? []).compactMap { KeyspaceEntry(name: $0.key, value: $0.value) }
    }

    public var isEmpty: Bool { sections.isEmpty }
}

public struct KeyspaceEntry: Sendable, Hashable, Identifiable {
    public var database: Int
    public var keys: Int64
    public var expires: Int64
    public var averageTTL: Int64
    public var id: Int { database }

    public init(database: Int, keys: Int64, expires: Int64 = 0, averageTTL: Int64 = 0) {
        self.database = database
        self.keys = keys
        self.expires = expires
        self.averageTTL = averageTTL
    }

    init?(name: String, value: String) {
        guard name.hasPrefix("db"), let database = Int(name.dropFirst(2)) else { return nil }
        var fields: [String: Int64] = [:]
        for part in value.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let number = Int64(pair[1]) { fields[String(pair[0])] = number }
        }
        self.init(database: database, keys: fields["keys"] ?? 0, expires: fields["expires"] ?? 0, averageTTL: fields["avg_ttl"] ?? 0)
    }
}

public enum ServerFamily: String, Sendable, Codable {
    case redis = "Redis"
    case valkey = "Valkey"
    case keydb = "KeyDB"
    case dragonfly = "Dragonfly"
    case unknown = "Unknown"
}

public enum ServerRole: String, Sendable, Codable {
    case master
    case replica
    case sentinel
    case unknown
}

/// What the client knows about the server it talks to.
public struct ServerInfo: Sendable, Equatable {
    public var family: ServerFamily
    public var version: ServerVersion?
    public var versionString: String
    /// `standalone`, `cluster` or `sentinel` (INFO `redis_mode` / HELLO `mode`).
    public var mode: String?
    public var role: ServerRole
    public var operatingSystem: String?
    public var processID: Int?
    public var tcpPort: Int?
    public var uptimeSeconds: Int64?
    public var runID: String?
    public var masterEndpoint: Endpoint?
    public var connectedReplicas: Int?

    public init(family: ServerFamily = .unknown, version: ServerVersion? = nil, versionString: String = "",
                mode: String? = nil, role: ServerRole = .unknown) {
        self.family = family
        self.version = version
        self.versionString = versionString
        self.mode = mode
        self.role = role
    }

    public static let unknown = ServerInfo()

    /// From `INFO` (any sections; `server` and `replication` give the most).
    public init(info: InfoSnapshot) {
        let serverName = info["server_name"]?.lowercased()
        if serverName == "valkey" || info["valkey_version"] != nil {
            family = .valkey
            versionString = info["valkey_version"] ?? info["redis_version"] ?? ""
        } else if let dragonfly = info["dragonfly_version"] {
            family = .dragonfly
            versionString = dragonfly
        } else if info["redis_version"] != nil {
            let executable = (info["executable"] ?? "").lowercased()
            family = executable.contains("keydb") || info["mvcc_depth"] != nil ? .keydb : .redis
            versionString = info["redis_version"] ?? ""
        } else {
            family = .unknown
            versionString = ""
        }
        version = ServerVersion(parsing: versionString)
        mode = info["redis_mode"] ?? info["server_mode"]
        switch info["role"]?.lowercased() {
        case "master": role = .master
        case "slave", "replica": role = .replica
        case "sentinel": role = .sentinel
        default: role = mode == "sentinel" ? .sentinel : .unknown
        }
        operatingSystem = info["os"]
        processID = info["process_id"].flatMap { Int($0) }
        tcpPort = info["tcp_port"].flatMap { Int($0) }
        uptimeSeconds = info.int("uptime_in_seconds")
        runID = info["run_id"]
        if let host = info["master_host"], let port = info["master_port"].flatMap({ Int($0) }) {
            masterEndpoint = Endpoint(host: host, port: port)
        }
        connectedReplicas = info["connected_slaves"].flatMap { Int($0) }
    }

    /// From a `HELLO` reply map (server, version, mode, role).
    public init(hello: RESPValue) {
        let server = hello["server"]?.string?.lowercased() ?? "redis"
        family = server == "valkey" ? .valkey : server == "redis" ? .redis : server.contains("dragonfly") ? .dragonfly : .unknown
        versionString = hello["version"]?.string ?? ""
        version = ServerVersion(parsing: versionString)
        mode = hello["mode"]?.string
        switch hello["role"]?.string?.lowercased() {
        case "master": role = .master
        case "replica", "slave": role = .replica
        case "sentinel": role = .sentinel
        default: role = .unknown
        }
    }

    /// "Redis 7.2.4", "Valkey 8.0.1", or "Unknown server".
    public var displayName: String {
        if versionString.isEmpty { return family == .unknown ? "Unknown server" : family.rawValue }
        return "\(family == .unknown ? "Redis-compatible" : family.rawValue) \(versionString)"
    }
}
