import Foundation

// pendingcrew-mcp —— PendingCrew 本地 crew-comms helper（spec local-first chunk 4，
// 自包含 Swift executable，编进 app bundle，无外部 runtime 依赖）。
//
// 子命令：
//   serve --crew <id> --dir <path> --session <id>   → MCP stdio server（post_to_crew / read_whiteboard）
//   hook  --crew <id> --dir <path> --session <id>   → 吐未读白板的 hook JSON（Task 3）
//
// claude 经 `--mcp-config` 拉 `serve`、经 `--settings` 的 PostToolUse hook 拉 `hook`。

func argValue(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
let sub = args.first
let crewId = argValue("--crew", args) ?? ""
let sessionId = argValue("--session", args) ?? ""
let dirURL = argValue("--dir", args).map { URL(fileURLWithPath: $0) }
let store = LocalWhiteboardStore(directory: dirURL)

switch sub {
case "serve":
    let server = McpServer(store: store, crewId: crewId, sessionId: sessionId)
    while let line = readLine(strippingNewline: true) {
        if let out = server.handleLine(line) {
            print(out)
            fflush(stdout)   // 管道下确保即时（MCP newline-delimited JSON-RPC）
        }
    }
case "hook":
    // Task 3 接 HookEmitter；占位：暂不输出（无未读 → 不注入）。
    break
default:
    FileHandle.standardError.write(Data(
        "usage: pendingcrew-mcp serve|hook --crew <id> --dir <path> --session <id>\n".utf8))
    exit(2)
}
