#if os(macOS)
import Foundation

/// Wires the `ask_human` MCP server into a crew session (T4.5 人在回路交互，
/// spec §10).
///
/// Writes a managed `mcp.json` (passed to Claude Code via `--mcp-config`) that
/// points at the bundled `ask-human-mcp.cjs` stdio server, with the edge URL +
/// device-grant token + server session id in its `env`. When the agent calls
/// `ask_human`, that server raises an interaction to the edge and blocks for
/// the human reply (verified: auto mode auto-allows the MCP tool, no allowlist
/// needed).
///
/// Out-of-tree (app caches), so the user's repo stays clean; `teardown()`
/// removes it when the session ends. Self-contained in LocalRunner (Foundation
/// only) so it's unit-testable; the bundled server-script path is injected
/// (`Bundle.main` from the app; a temp path in tests).
struct InteractionChannel {
    let directory: URL

    /// Path to hand Claude Code via `--mcp-config`.
    var mcpConfigPath: String { directory.appendingPathComponent("mcp.json").path }

    /// Default managed-dir parent: app caches (out of the repo).
    static func defaultParent() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Create the managed dir + mcp.json. `serverScriptPath` is the bundled
    /// `ask-human-mcp.cjs`; `edgeURL` / `token` / `edgeSessionId` configure the
    /// server's edge round-trip.
    static func create(
        parent: URL,
        sessionId: String,
        serverScriptPath: String,
        edgeURL: String,
        token: String,
        edgeSessionId: String
    ) throws -> InteractionChannel {
        let dir = parent
            .appendingPathComponent("crew-interaction", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let channel = InteractionChannel(directory: dir)
        try channel.writeConfig(
            serverScriptPath: serverScriptPath, edgeURL: edgeURL, token: token, edgeSessionId: edgeSessionId)
        return channel
    }

    private func writeConfig(
        serverScriptPath: String, edgeURL: String, token: String, edgeSessionId: String
    ) throws {
        // `command: node` resolves via the PATH the runner gives Claude (env()
        // whitelist includes PATH); Claude passes its env down to the MCP server,
        // so PC_* + PATH both reach it. Built via JSONSerialization for safe
        // escaping of the script path.
        let obj: [String: Any] = [
            "mcpServers": [
                "pendingcrew": [
                    "command": "node",
                    "args": [serverScriptPath],
                    "env": [
                        "PC_EDGE_URL": edgeURL,
                        "PC_TOKEN": token,
                        "PC_SESSION_ID": edgeSessionId,
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: mcpConfigPath))
    }

    /// Remove the managed dir. Call when the session ends.
    func teardown() {
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
