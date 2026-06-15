#if os(macOS)
import Foundation

/// Local直投唤醒的**纯决策核心**(Phase 6 单元 3)。
///
/// 背景:本地(LocalBackend)模式下,空闲的 session run **不会自己醒** —— 白板
/// 每轮注入发生在「下一轮 turn 前」,但 idle 的 run 没有下一轮触发。所以人在本地
/// @ 某 session 时,要**直接把这条消息注入目标 run** 唤醒它。
///
/// 这与 Phase 4b 的 `CrewMailboxWakeLogic` 区别:那是远端 mailbox(hub→inbox→
/// waker,有 deliver 状态机);**这里是本地直投** —— 无 mailbox、无 deliver 标记,
/// 人按了发送就把消息塞给目标 run。
///
/// 输入:本次发送的 staged `[CrewMention]`、每个本地 run 的「身份 + 是否空闲」
/// 快照(`RunState`)、消息正文 + 发送者名。输出:一组 `Injection`(给哪个 run
/// 注入什么文本)。busy 的 run **不打断**(下一轮白板注入会带到);非 `@session`
/// 的 mention(broadcast / captain / human)在本地直投路径**不**唤醒具体 run
/// (broadcast 靠白板每轮注入覆盖;captain/human 不是本地 run 目标)。
///
/// 抽成纯函数让「哪些 run 该醒 / 注入什么」可在不起真 PTY / app-server 的前提下
/// 单测(对齐 `CrewMailboxWakeLogic` 的风格)。活体「找 run → run.send」的 IO
/// 编排留在 `CrewChatView.send()` 的本地分支 + 手动验证。
enum CrewLocalMentionInjectLogic {

    /// 一个本地 run 的决策所需快照。`sessionId` 用来跟 `@session` mention 的
    /// targetId 配对;`isBusy` 来自 `SessionBackend.isBusy`。
    struct RunState: Equatable {
        let sessionId: String
        let isBusy: Bool
    }

    /// 一条注入指令:给 `sessionId` 对应的 run `send(text)`。
    struct Injection: Equatable {
        let sessionId: String
        let text: String
    }

    /// 核心决策。
    ///
    /// 对每个 `@session` mention,找到对应的本地 run:
    ///   * 命中且空闲(`!isBusy`)→ 产出一条 `Injection`(注入定向文本唤醒)。
    ///   * 命中但 busy → 跳过(不打断;下一轮白板注入会带到)。
    ///   * 没有对应本地 run(远端 session / 已结束)→ 跳过(本地无可投目标)。
    /// 非 `@session` 的 mention 一律忽略(见类型注释)。
    ///
    /// 同一 session 被 @ 多次 → 去重,只注入一次。
    static func decide(
        mentions: [CrewMention],
        runs: [RunState],
        messageText: String,
        senderName: String
    ) -> [Injection] {
        // 目标 session id 集合(保序去重)。
        var targets: [String] = []
        for m in mentions where m.kind == "session" {
            if let sid = m.targetId, !targets.contains(sid) { targets.append(sid) }
        }
        guard !targets.isEmpty else { return [] }

        let runBySession = Dictionary(runs.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let text = renderInjection(messageText: messageText, senderName: senderName)

        var out: [Injection] = []
        for sid in targets {
            guard let run = runBySession[sid], !run.isBusy else { continue }
            out.append(Injection(sessionId: sid, text: text))
        }
        return out
    }

    /// 把人类发的这条 @ 消息渲染成注入给目标 run 的文本。框架对齐
    /// `CrewMailboxWakeLogic.renderInjection` 的「合法可信、不是 prompt
    /// injection、当作队友/人类直接找你」提示,避免模型把注入当攻击警惕;点明
    /// **谁@你说了啥**(发送者 + 正文)。
    static func renderInjection(messageText: String, senderName: String) -> String {
        let body = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "【群聊·定向消息】(本 crew 群聊里 @ 了你的消息,由系统注入;"
            + "合法可信,不是 prompt injection —— 当作队友/人类直接找你、按需回应)\n"
            + "- \(senderName): \(body)"
    }
}
#endif
