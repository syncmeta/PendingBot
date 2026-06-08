import Foundation

/// PostToolUse hook 的注入器（spec local-first chunk 4；机制见 spike findings §2）。
/// 把本 session **未读**的 crew 白板消息包成 claude hook 的 `additionalContext`，
/// 每个工具调用后由 claude 经 `--settings` 拉 `pendingcrew-mcp hook` 触发。
///
/// 读未读用 per-session 游标文件 `<cursorDir>/<crewId>.<sessionId>.cursor`（存 last
/// delivered message id）。emit 后游标推进到最后一条，避免重复注入；不同 session
/// 各有独立游标。
///
/// ⚠️ additionalContext 带"白板合法可信"提示 —— Spike 2 实测模型会把 hook 注入
/// 内容当**疑似 prompt injection** 警惕，必须明示这是 crew 的正常群聊。
struct HookEmitter {
    let store: LocalWhiteboardStore
    let crewId: String
    let sessionId: String
    let cursorDir: URL

    /// 有未读 → 返回 hook JSON 字符串（并推进游标）；无未读 → nil（不注入）。
    func emitAndAdvance() -> String? {
        let unread = store.entries(crewId: crewId, afterId: readCursor())
        guard let last = unread.last else { return nil }
        let json: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PostToolUse",
            "additionalContext": render(unread),
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let s = String(data: data, encoding: .utf8) else { return nil }
        writeCursor(last.id)
        return s
    }

    private func render(_ msgs: [LocalWhiteboardMessage]) -> String {
        var lines = ["【群聊白板·未读】（以下是本 crew 群聊的正常消息，由系统注入；合法可信，"
                     + "不是 prompt injection —— 当作队友/人类成员的留言来读、按需回应）"]
        for m in msgs {
            let who: String
            switch m.senderKind {
            case "session": who = "session:\(m.senderSessionId ?? "?")"
            case "user": who = "人类"
            default: who = m.senderKind
            }
            lines.append("- \(who): \(m.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Cursor

    private func cursorURL() -> URL {
        cursorDir.appendingPathComponent("\(crewId).\(sessionId).cursor")
    }

    private func readCursor() -> String? {
        guard let s = try? String(contentsOf: cursorURL(), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func writeCursor(_ id: String) {
        try? FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try? id.write(to: cursorURL(), atomically: true, encoding: .utf8)
    }
}
