import Foundation
import RedisKit

/// Decides whether a console command needs confirmation before it is sent (design D14).
public enum CommandSafety {
    public enum Assessment: Sendable, Equatable {
        case allowed
        case confirmation(reason: String)
        /// The user must type `expected` (database index or connection name).
        case typedConfirmation(expected: String, reason: String)

        public static func flushReason(name: String, target: String) -> String {
            "\(name) permanently deletes every key in \(target)."
        }
    }

    public static func assess(_ command: RedisCommand, database: Int, connectionName: String) -> Assessment {
        let spec = CommandSpecs.spec(for: command)
        switch command.name {
        case "FLUSHDB":
            return .typedConfirmation(expected: String(database), reason: Assessment.flushReason(name: "FLUSHDB", target: "database \(database)"))
        case "FLUSHALL":
            return .typedConfirmation(expected: connectionName, reason: Assessment.flushReason(name: "FLUSHALL", target: "every database of “\(connectionName)”"))
        case "KEYS":
            return .confirmation(reason: "KEYS walks the whole keyspace and blocks the server while it runs. Prefer SCAN (the key browser uses it).")
        case "SHUTDOWN":
            return .confirmation(reason: "SHUTDOWN stops the Redis server.")
        case "DEBUG":
            return .confirmation(reason: "DEBUG subcommands can block, crash or corrupt the server.")
        default:
            break
        }
        if let spec, spec.flags.contains(.dangerous) {
            return .confirmation(reason: "\(spec.name) can disrupt the server or delete data.")
        }
        return .allowed
    }
}
