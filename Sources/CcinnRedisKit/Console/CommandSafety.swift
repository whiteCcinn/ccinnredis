import Foundation
import RedisKit
import RESPWire

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

    /// - Parameters:
    ///   - database: the selected database, or nil when it is not known for sure (then FLUSHDB asks for the connection name).
    ///   - spec: the connected server's spec (includes module commands and their `@dangerous` category).
    public static func assess(_ command: RedisCommand, database: Int?, connectionName: String, spec serverSpec: CommandSpec? = nil) -> Assessment {
        let spec = serverSpec ?? CommandSpecs.spec(for: command)
        switch command.name {
        case "FLUSHDB":
            guard let database else {
                return .typedConfirmation(expected: connectionName, reason: Assessment.flushReason(name: "FLUSHDB", target: "the selected database of “\(connectionName)” (which database is selected is not known)"))
            }
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

/// Which database a console connection has selected, tracked from replies (design D12): only an `OK`
/// reply to SELECT counts, SELECTs queued in MULTI apply when EXEC succeeds, RESET returns to 0.
/// Anything ambiguous makes the database unknown (nil) instead of guessing.
public struct ConsoleSessionState: Sendable, Equatable {
    public private(set) var database: Int?
    public private(set) var inTransaction = false
    /// (position in the transaction, database) of queued SELECTs.
    private var queuedSelects: [(position: Int, database: Int?)] = []
    private var queuedCount = 0

    public init(database: Int?) {
        self.database = database
    }

    public static func == (lhs: ConsoleSessionState, rhs: ConsoleSessionState) -> Bool {
        lhs.database == rhs.database && lhs.inTransaction == rhs.inTransaction && lhs.queuedCount == rhs.queuedCount
            && lhs.queuedSelects.map(\.position) == rhs.queuedSelects.map(\.position)
            && lhs.queuedSelects.map(\.database) == rhs.queuedSelects.map(\.database)
    }

    /// A new connection starts outside a transaction on `database`.
    public mutating func reset(database: Int?) {
        self = ConsoleSessionState(database: database)
    }

    public mutating func apply(_ command: RedisCommand, reply: RESPValue) {
        let name = command.name
        if inTransaction, !["EXEC", "DISCARD", "MULTI", "RESET", "WATCH"].contains(name) {
            guard reply.string == "QUEUED" else { return }
            if name == "SELECT" { queuedSelects.append((queuedCount, Self.index(command))) }
            queuedCount += 1
            return
        }
        switch name {
        case "SELECT":
            guard !reply.isError else { return }
            database = reply.string == "OK" ? Self.index(command) : nil
        case "MULTI":
            guard reply.string == "OK" else { return }
            inTransaction = true
            queuedSelects = []
            queuedCount = 0
        case "EXEC":
            defer { endTransaction() }
            guard let results = reply.array else { return } // aborted (nil) or EXECABORT
            for queued in queuedSelects where queued.position < results.count {
                if results[queued.position].string == "OK" { database = queued.database } else if !results[queued.position].isError { database = nil }
            }
        case "DISCARD":
            if !reply.isError { endTransaction() }
        case "RESET":
            if !reply.isError {
                endTransaction()
                database = 0
            }
        default:
            break
        }
    }

    private mutating func endTransaction() {
        inTransaction = false
        queuedSelects = []
        queuedCount = 0
    }

    private static func index(_ command: RedisCommand) -> Int? {
        guard command.arguments.count == 2 else { return nil }
        return Int(String(decoding: command.arguments[1], as: UTF8.self))
    }
}
