// CcinnRedis — a native Redis client for macOS.
import CcinnRedisKit
import Foundation

// `CcinnRedis mcp …` runs the MCP server headless (no windows, no Dock icon) until stdin closes.
if CommandLine.arguments.dropFirst().first == "mcp" {
    exit(MCPStdioRunner.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
}
CcinnRedisApp.main()
