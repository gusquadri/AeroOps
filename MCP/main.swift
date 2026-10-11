// aeroops-mcp: stdio MCP server bundled at AeroOps.app/Contents/MacOS/aeroops-mcp.
// Phase 7 replaces this placeholder with an MCP Swift SDK server that forwards every tool call
// to the running app over ~/.aeroops/bridge.sock.

import Foundation

let usage = """
    usage: aeroops-mcp
      Stdio MCP server for AeroOps (not implemented yet). Register it with an MCP client, e.g.
      claude mcp add --scope user aeroops -- /Applications/AeroOps.app/Contents/MacOS/aeroops-mcp
    """
print(usage)
