import Foundation

/// A tool as advertised in `tools/list`.
public struct MCPToolDefinition: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool,
                destructive: Bool = false, idempotent: Bool = true) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    var json: JSONValue {
        .object([
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent), "openWorldHint": .bool(false),
            ]),
        ])
    }
}

/// Outcome of a tool call: a JSON object, flagged as an error for tool-level failures.
public struct MCPToolResult: Sendable {
    public var payload: JSONValue
    public var isError: Bool

    public init(payload: JSONValue, isError: Bool = false) {
        self.payload = payload
        self.isError = isError
    }

    public static func error(_ message: String, details: [String: JSONValue] = [:]) -> MCPToolResult {
        var fields = details
        fields["error"] = .string(message)
        return MCPToolResult(payload: .object(fields), isError: true)
    }
}

public protocol MCPToolbox: Sendable {
    func tools() async -> [MCPToolDefinition]
    /// Never throws: failures are `isError` results with a helpful message.
    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult
}

/// JSON Schema builders for tool inputs.
public enum MCPSchema {
    public static func object(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
                 "additionalProperties": .bool(false)])
    }

    public static func string(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    public static func integer(_ description: String, minimum: Int64? = nil, maximum: Int64? = nil, nullable: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = ["type": nullable ? .array(["integer", "null"]) : "integer", "description": .string(description)]
        if let minimum { fields["minimum"] = .int(minimum) }
        if let maximum { fields["maximum"] = .int(maximum) }
        return .object(fields)
    }

    public static func stringArray(_ description: String, maxItems: Int64) -> JSONValue {
        .object(["type": "array", "items": .object(["type": "string"]), "maxItems": .int(maxItems), "description": .string(description)])
    }

    /// Validates arguments against a schema built with these helpers: required keys, no extra keys,
    /// primitive types, string-array items and bounds. Returns a message for the model, or nil.
    public static func validate(_ arguments: [String: JSONValue], against schema: JSONValue) -> String? {
        let properties = schema["properties"]?.object ?? [:]
        for name in schema["required"]?.array?.compactMap(\.string) ?? [] where arguments[name] == nil || arguments[name] == .null {
            return "Missing required argument '\(name)'"
        }
        for (name, value) in arguments {
            guard let property = properties[name] else {
                return "Unknown argument '\(name)'. Allowed: \(properties.keys.sorted().joined(separator: ", "))"
            }
            let types: [String] = property["type"]?.string.map { [$0] } ?? property["type"]?.array?.compactMap(\.string) ?? []
            let matches = types.contains { type in
                switch (type, value) {
                case ("string", .string), ("boolean", .bool), ("null", .null), ("integer", .int), ("array", .array), ("object", .object): true
                case ("integer", let .double(number)): number.rounded() == number
                default: false
                }
            }
            guard matches else { return "Argument '\(name)' must be of type \(types.joined(separator: " or "))" }
            if let items = value.array {
                if let max = property["maxItems"]?.int, items.count > max { return "Argument '\(name)' accepts at most \(max) items" }
                if property["items"]?["type"]?.string == "string", items.contains(where: { $0.string == nil }) {
                    return "Argument '\(name)' must be an array of strings"
                }
            }
        }
        return nil
    }
}

/// MCP over newline-delimited JSON-RPC 2.0 (design: shared ccinn series). Requests are handled
/// concurrently (each `tools/call` in its own task); all output goes through this actor, so lines
/// are never interleaved.
public actor MCPServer {
    public typealias Output = @Sendable (Data) -> Void

    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestVersion = "2025-06-18"

    private let name: String
    private let title: String
    private let version: String
    private let instructions: String
    private let toolbox: any MCPToolbox
    private let output: Output
    private var protocolVersion = MCPServer.latestVersion
    private var inflight: [JSONValue: Task<Void, Never>] = [:]

    public init(name: String, title: String, version: String, instructions: String, toolbox: any MCPToolbox, output: @escaping Output) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
        self.toolbox = toolbox
        self.output = output
    }

    public func receive(line: Data) async {
        guard let message = try? JSONValue.decode(line) else {
            sendError(id: .null, code: -32700, message: "Parse error: the message is not valid JSON")
            return
        }
        guard case let .object(fields) = message else {
            sendError(id: .null, code: -32600, message: "Invalid request")
            return
        }
        let id = fields["id"]
        guard let method = fields["method"]?.string else {
            // Responses from the client (we send no requests) are ignored.
            if id == nil { sendError(id: .null, code: -32600, message: "Invalid request: missing method") }
            return
        }
        let params = fields["params"]?.object ?? [:]

        if method == "notifications/cancelled" {
            if let requestID = params["requestId"], let task = inflight.removeValue(forKey: requestID) { task.cancel() }
            return
        }
        if method.hasPrefix("notifications/") { return }
        guard let id else { return } // other notifications

        switch method {
        case "initialize":
            if let requested = params["protocolVersion"]?.string, Self.supportedVersions.contains(requested) {
                protocolVersion = requested
            } else {
                protocolVersion = Self.latestVersion
            }
            send(id: id, result: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "title": .string(title), "version": .string(version)]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            send(id: id, result: .object([:]))
        case "tools/list":
            let tools = await toolbox.tools()
            send(id: id, result: .object(["tools": .array(tools.map(\.json))]))
        case "resources/list":
            send(id: id, result: .object(["resources": .array([])]))
        case "resources/templates/list":
            send(id: id, result: .object(["resourceTemplates": .array([])]))
        case "prompts/list":
            send(id: id, result: .object(["prompts": .array([])]))
        case "tools/call":
            guard let toolName = params["name"]?.string else {
                sendError(id: id, code: -32602, message: "Invalid params: 'name' is required")
                return
            }
            let rawArguments = params["arguments"] ?? .object([:])
            guard let arguments = rawArguments.object else {
                sendError(id: id, code: -32602, message: "Invalid params: 'arguments' must be an object")
                return
            }
            let tools = await toolbox.tools()
            guard tools.contains(where: { $0.name == toolName }) else {
                sendError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
                return
            }
            let toolbox = toolbox
            let task = Task { [weak self] in
                let result = await toolbox.call(name: toolName, arguments: arguments)
                await self?.complete(id: id, result: result)
            }
            inflight[id] = task
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Called by the transport for a line over the size limit.
    public func receiveOversizedLine() {
        sendError(id: .null, code: -32700, message: "Parse error: message exceeds the maximum size")
    }

    private func complete(id: JSONValue, result: MCPToolResult) {
        // Cancelled requests were removed from `inflight` and get no reply.
        guard inflight.removeValue(forKey: id) != nil else { return }
        var body: [String: JSONValue] = [
            "content": .array([.object(["type": "text", "text": .string(result.payload.compactString)])]),
            "isError": .bool(result.isError),
        ]
        if protocolVersion >= "2025-06-18", case .object = result.payload { body["structuredContent"] = result.payload }
        send(id: id, result: .object(body))
    }

    /// Waits until every in-flight tool call has finished (used on shutdown and in tests).
    public func waitForIdle() async {
        while let task = inflight.values.first {
            await task.value
            if let key = inflight.first(where: { $0.value == task })?.key { inflight.removeValue(forKey: key) }
        }
    }

    public func cancelAll() {
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
    }

    private func send(id: JSONValue, result: JSONValue) {
        output(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compactData)
    }

    private func sendError(id: JSONValue, code: Int64, message: String) {
        output(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .int(code), "message": .string(message)])]).compactData)
    }
}
