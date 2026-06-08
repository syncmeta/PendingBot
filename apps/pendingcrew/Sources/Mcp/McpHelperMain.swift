import Foundation

/// crew-comms helper 的进程入口逻辑（re-exec self；spec local-first chunk 4）。
/// 由 `PendingCrewEntry.main()` 在 argv 带 helper flag 时调用，跑完即返回。
///
/// 子命令（flag 形式，因为是同一 app 二进制的 argv，不是子进程参数）：
///   `--mcp-serve --crew <id> --dir <path> --session <id>`  → MCP stdio server
///   `--mcp-hook  --crew <id> --dir <path> --session <id>`  → 吐未读白板的 hook JSON
enum McpHelperMain {
    /// argv 含 helper flag → 跑对应模式、返回 true（caller 应 return，不起 GUI）。
    /// 不含 → 返回 false（正常起 GUI）。
    @discardableResult
    static func runIfHelper(_ args: [String]) -> Bool {
        let serve = args.contains("--mcp-serve")
        let hook = args.contains("--mcp-hook")
        guard serve || hook else { return false }

        let crewId = value("--crew", args) ?? ""
        let sessionId = value("--session", args) ?? ""
        let dir = value("--dir", args).map { URL(fileURLWithPath: $0) }
        let store = LocalWhiteboardStore(directory: dir)

        if serve {
            // newline-delimited JSON-RPC over stdin/stdout（MCP stdio）。
            let server = McpServer(store: store, crewId: crewId, sessionId: sessionId)
            while let line = readLine(strippingNewline: true) {
                if let out = server.handleLine(line) {
                    print(out)
                    fflush(stdout)
                }
            }
        } else {
            // PostToolUse hook：吐本 session 未读白板（带"可信"提示）。无未读 → 不输出。
            let emitter = HookEmitter(store: store, crewId: crewId, sessionId: sessionId,
                                      cursorDir: dir ?? LocalWhiteboardStore.defaultDirectory)
            if let out = emitter.emitAndAdvance() {
                print(out)
                fflush(stdout)
            }
        }
        return true
    }

    private static func value(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
