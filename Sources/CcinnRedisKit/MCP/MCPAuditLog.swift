import Foundation

/// Appends one JSON line per MCP tool call to `mcp-audit.jsonl` (rotated at 10 MB). Never logs values or secrets.
public actor MCPAuditLog {
    public let directory: URL
    private var handle: FileHandle?
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

    private func append(_ data: Data) {
        do {
            if handle == nil {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                handle = try FileHandle(forWritingTo: fileURL)
            }
            guard let handle else { return }
            let size = try handle.seekToEnd()
            if size > Self.maxBytes {
                try handle.close()
                self.handle = nil
                let rotated = directory.appendingPathComponent("mcp-audit.1.jsonl")
                try? FileManager.default.removeItem(at: rotated)
                try FileManager.default.moveItem(at: fileURL, to: rotated)
                append(data)
                return
            }
            try handle.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("ccinnredis mcp: could not write the audit log: \(error.localizedDescription)\n".utf8))
        }
    }

    public func flush() {
        try? handle?.synchronize()
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }
}
