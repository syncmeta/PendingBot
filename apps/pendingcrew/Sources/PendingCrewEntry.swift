import Foundation

/// 进程入口（spec local-first chunk 4：re-exec self）。
///
/// 同一个 app 二进制有两副身份：
/// - 带 `--mcp-serve` / `--mcp-hook` argv（claude 经 `--mcp-config` / `--settings`
///   的 hook 拉起）→ 当 **crew-comms helper** 跑（stdio MCP server / 注入未读白板），
///   不起 GUI。比 embed 独立 executable 更自包含（就一个二进制、`Bundle.main.
///   executablePath` 铁定可寻），也避开 macOS app bundle 嵌可执行文件的签名/拷贝坑。
/// - 否则 → 起正常 SwiftUI GUI（`PendingCrewApp.main()`）。
@main
struct PendingCrewEntry {
    static func main() {
        if McpHelperMain.runIfHelper(CommandLine.arguments) { return }
        PendingCrewApp.main()
    }
}
