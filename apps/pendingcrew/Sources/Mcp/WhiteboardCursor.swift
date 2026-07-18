import Foundation

/// Per-session 白板**未读游标**的单一真值 —— PostToolUse hook（`HookEmitter`）与
/// **唤醒/提及注入**（`CrewMailboxWaker` 登录态、`CrewChatView` 本地直投）共用同一份。
///
/// 文件 `<directory>/<crewId>.<sessionId>.cursor` 存 last-delivered 白板消息 id。
/// 两条注入路都「读同一游标 → 取该 session 还没看过的 → 注入后推进同一游标」，
/// 于是一条消息对某 session **至多注入一次**，跨 hook 路与唤醒路不重复
/// （病根：唤醒路此前不接游标，每次唤醒重发最近 15 条已注入过的历史）。
///
/// **推进 forward-only + flock**：claude session 现在有两个**跨进程**写者 ——
/// helper 子进程的 PostToolUse hook 与 app 进程的唤醒注入，同写一份游标。
/// 用 `<crewId>.<sessionId>.cursor.lock` 上的 `flock` 串行化「读游标→比位置→落盘」，
/// 且仅当目标 id 在白板列表中**位于当前游标之后**才写，杜绝并发下游标被推回旧位
/// 导致的重复注入。游标存的是 uuid（无序），所以「更靠后」以白板列表里的下标为准。
struct WhiteboardCursor {
    let directory: URL
    let crewId: String
    let sessionId: String

    private var cursorURL: URL {
        directory.appendingPathComponent("\(crewId).\(sessionId).cursor")
    }
    private var lockURL: URL {
        directory.appendingPathComponent("\(crewId).\(sessionId).cursor.lock")
    }

    /// 当前游标（last-delivered id）；文件缺失/空 → nil。
    func read() -> String? {
        guard let s = try? String(contentsOf: cursorURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 该 session 的**未读**（游标之后的白板消息，按写入序）。游标 nil / 找不到
    /// 对应消息 → 返回全部（首次注入把在场历史都当未读）。
    func unread(in store: LocalWhiteboardStore) -> [LocalWhiteboardMessage] {
        store.entries(crewId: crewId, afterId: read())
    }

    /// 推进游标到 `toId`（forward-only + flock）。仅当 `toId` 在白板列表中位于
    /// 当前游标**之后**才落盘；已在同位或更靠后 → no-op（并发写者不互相回退）。
    /// `toId` 不在列表（已被 lenient 解码丢弃等）→ 不动游标。
    func advance(to toId: String, in store: LocalWhiteboardStore) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

        let all = store.list(crewId: crewId)
        guard let toIdx = all.firstIndex(where: { $0.id == toId }) else { return }
        if let cur = read(), let curIdx = all.firstIndex(where: { $0.id == cur }),
           curIdx >= toIdx {
            return   // 游标已在同位或更靠后 —— 不回退。
        }
        try? toId.write(to: cursorURL, atomically: true, encoding: .utf8)
    }
}
