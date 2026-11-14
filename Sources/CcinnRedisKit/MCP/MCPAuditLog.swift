import Foundation

/// Appends one JSON line per MCP tool call to `mcp-audit.jsonl` (rotated at 10 MB). Never logs values or secrets.
public actor MCPAuditLog {
    public let directory: URL
    static let maxBytes: UInt64 = 10 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("mcp-audit.jsonl") }

    public func record(connection: String?, tool: String, command: String?, key: String?, duration: Duration, items: Int?, error: String?) {
        var fields: [String: JSONValue] = [
            "time": .string(ISO8601DateFormatter().string(from: Date())),
            "source": "mcp",
            "tool": .string(tool),
            "durationMs": .int(Int64(duration.components.seconds) * 1000 + Int64(duration.components.attoseconds / 1_000_000_000_000_000)),
        ]
        if let connection { fields["connection"] = .string(connection) }
        if let command { fields["command"] = .string(String(ConsoleHistory.redact(command).prefix(500))) }
        if let key { fields["key"] = .string(String(key.prefix(300))) }
        if let items { fields["items"] = .int(Int64(items)) }
        if let error { fields["error"] = .string(String(error.prefix(500))) }
        append(JSONValue.object(fields).compactData + Data([0x0A]))
    }

    /// Several `CcinnRedis mcp` processes (one per MCP client) may share the file: every line is a single
    /// `write(2)` on an `O_APPEND` descriptor, and size check + rotation happen under an exclusive `flock`,
    /// re-opening when another process rotated the file underneath us.
    private func append(_ data: Data) {
        do {
            var fd = try openIfNeeded()
            guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
            if (try? needsRotation(fd)) == true {
                let rotated = Result { try rotate() }
                flock(fd, LOCK_UN)
                try rotated.get()
                fd = try openIfNeeded()
                guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
            }
            let written = data.withUnsafeBytes { buffer in write(fd, buffer.baseAddress, buffer.count) }
            flock(fd, LOCK_UN)
            if written != data.count { throw POSIXError(.EIO) }
        } catch {
            FileHandle.standardError.write(Data("ccinnredis mcp: could not write the audit log: \(error.localizedDescription)\n".utf8))
        }
    }

    private var descriptor: Int32 = -1

    private func openIfNeeded() throws -> Int32 {
        if descriptor >= 0, !fileWasReplaced(descriptor) { return descriptor }
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptor = fd
        return fd
    }

    /// True when the path now names a different file (rotated by another process) or none.
    private func fileWasReplaced(_ fd: Int32) -> Bool {
        var open = stat()
        var current = stat()
        guard fstat(fd, &open) == 0, stat(fileURL.path, &current) == 0 else { return true }
        return open.st_ino != current.st_ino || open.st_dev != current.st_dev
    }

    private func needsRotation(_ fd: Int32) throws -> Bool {
        if fileWasReplaced(fd) { return false } // someone else rotated; the next record reopens
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        return UInt64(max(0, info.st_size)) > Self.maxBytes
    }

    private func rotate() throws {
        let rotated = directory.appendingPathComponent("mcp-audit.1.jsonl")
        // rename(2) atomically replaces the previous rotated file.
        guard Darwin.rename(fileURL.path, rotated.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func flush() {
        if descriptor >= 0 { fsync(descriptor) }
    }

    public func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
    }
}
