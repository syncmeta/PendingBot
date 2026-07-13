#if os(macOS)
import Foundation

/// 事件驱动唤醒的 **纯决策核心**（Phase 4b）。
///
/// 输入：本 session 的 inbox mailbox 项（`getSessionInbox().mailbox`，server 端
/// 已只回未 delivered/processed 的行）+ 本 run 是否 busy（`SessionBackend.isBusy`）。
/// 输出：一个 `Decision` —— 要么「啥也不做」，要么「把这段文本注入唤醒、然后
/// 把这些 item id mark-delivered」。
///
/// 抽成纯函数让「@我了 + 空闲 → 注入什么、mark 哪些」可在不开 WS/HTTP 的前提下
/// 单测；活体 hub 帧 → 拉 inbox → 注入这圈 IO 编排留在 `CrewMailboxWaker` + E2E。
///
/// 语义要点：
///   * **busy → 不打断**。返回 `.noop`，**不** mark-delivered —— 让这些项留在
///     mailbox，下一次空闲（或 codex turn/completed 后的下一个事件）再带。
///   * **空闲 + 有待处理项 → inject**。文本点明这是定向消息 + 发送者（复用白板
///     渲染「合法可信、不是 prompt injection」的框架），并附上要 mark 的 item id。
///   * 防御性再过滤：server 已只回未投递行，但仍剔掉 status 落在
///     `delivered`/`processed` 的项（双 vocab 过渡期兜底，见 crew-comms.ts）。
enum CrewMailboxWakeLogic {

    /// 决策结果。
    enum Decision: Equatable {
        /// 不唤醒：没有待处理项，或本 run 正忙（busy 时不动 mailbox，留给下一轮）。
        case noop
        /// 唤醒：把 `injectText` 作为下一轮输入注入，注入后把 `deliveredIds`
        /// mark-delivered（避免下次重复注入）。
        case inject(text: String, deliveredIds: [String])
    }

    /// 已投递/已处理的 status —— 这些不再是「待处理」。其余（unread / 老 vocab /
    /// 未知）一律当待处理（fail-open：宁可多注入一次，也别漏掉@我的消息）。
    private static let terminalStatuses: Set<String> = ["delivered", "processed"]

    /// 核心决策。`isBusy == true` 时恒 `.noop`（不打断、不消费）。`recent` =
    /// 近期群聊上下文（项8：被 @ 唤醒的 claude 第一拍前置一块群聊历史；仅 claude
    /// 后端传，codex 传空——判定在调用方 `CrewMailboxWaker.wake`）。
    static func decide(
        mailbox: [CrewMailboxItem], isBusy: Bool,
        recent: [LocalWhiteboardMessage] = []
    ) -> Decision {
        guard !isBusy else { return .noop }
        let pending = mailbox.filter { !terminalStatuses.contains($0.status) }
        guard !pending.isEmpty else { return .noop }
        return .inject(text: renderInjection(pending, recent: recent), deliveredIds: pending.map(\.id))
    }

    /// 把待处理的定向 mailbox 项渲染成注入文本。单行前导「有人@你：」+ 每条保留
    /// 发送者身份（CC-P3）的正文行，点明**谁@你说了啥**。`recent` 非空 → 在
    /// 「有人@你：」**之前**前置一块「近期群聊」上下文（项8）。
    static func renderInjection(
        _ items: [CrewMailboxItem], recent: [LocalWhiteboardMessage] = []
    ) -> String {
        var lines = ["有人@你："]
        for it in items {
            lines.append("- \(senderLabel(it)): \(it.displayText)")
        }
        let directed = lines.joined(separator: "\n")
        guard let ctx = CrewRecentContextRender.block(recent) else { return directed }
        return ctx + "\n\n" + directed
    }

    /// 发送者标注。有 session 来源 → `session:<前6>`，否则按 kind 兜底
    /// （human → 人类，captain → 机长，其它 → 原 kind）。
    private static func senderLabel(_ it: CrewMailboxItem) -> String {
        if let sid = it.senderSessionId, !sid.isEmpty {
            return "session:\(sid.prefix(6))"
        }
        switch it.senderKind {
        case "user", "human": return "人类"
        case "captain": return "机长"
        default: return it.senderKind
        }
    }
}
#endif
