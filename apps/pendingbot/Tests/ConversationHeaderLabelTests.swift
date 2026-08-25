// Standalone test for ConversationHeaderLabel — the pure string composition
// behind the chat header's "<bot> · <model>" line.
//
// 同 ModelRevealPolicyTests:本分支还没有 iOS 单测 target,而这两个文件都只
// import Foundation,所以直接 swiftc 一起编就能考。
//
//     apps/pendingbot/Tests/run-model-reveal-policy-tests.sh
//
// 这一组的重点全在**「还没到货」的那几帧**:Todo #10 报的两样东西
// (一串 UUID、上游模型名)都只在冷启动的头几百毫秒里出现过,肉眼靠不住,
// 只能靠断言钉。

import Foundation

// ── tiny harness ────────────────────────────────────────────────────────
var hfailures = 0
var hchecks = 0

func hExpect(_ actual: String, _ expected: String, _ what: String, line: Int = #line) {
    hchecks += 1
    if actual != expected {
        hfailures += 1
        print("✘ \(what) (line \(line))")
        print("    expected \"\(expected)\"")
        print("    actual   \"\(actual)\"")
    }
}

func hExpectTrue(_ cond: Bool, _ what: String, line: Int = #line) {
    hchecks += 1
    if !cond {
        hfailures += 1
        print("✘ \(what) (line \(line))")
    }
}

func subtitle(
    _ type: String? = "user_bot",
    bot: String? = "小绿",
    display: ModelNameDisplay = .real,
    model: String? = "PendingModel 3"
) -> String {
    ConversationHeaderLabel.subtitle(
        conversationType: type, botDisplayName: bot, display: display, modelName: model
    )
}

func runConversationHeaderLabelTests() {
    // ── 正常态 ──────────────────────────────────────────────────────────────

    hExpect(subtitle(), "小绿 · PendingModel 3", "名字 + 真名都在手 → 拼一起")
    hExpect(subtitle(display: .blind), "小绿 · PendingModel", "盲盒 → PendingModel")
    hExpect(subtitle("user_user", bot: "阿泽"), "阿泽",
            "user_user 单聊没有模型这一格,只有名字")
    hExpect(subtitle("group", bot: "群"), "群 · PendingModel 3",
            "群聊照常拼(只有 user_user 例外)")

    // ── Todo #10:还没到货的那几帧 ──────────────────────────────────────────

    hExpect(subtitle(display: .pending), "小绿",
            "会话盲盒事实没到货 → 只剩名字,模型这一格整格不画")
    hExpect(subtitle(display: .real, model: nil), "小绿",
            "目录还解不出这个 slug → 不画模型,不回落 slug 尾巴")
    hExpect(subtitle(bot: nil), "PendingModel 3",
            "名字还没解析出来 → 只剩模型名,绝不顶一串 id")
    hExpect(subtitle(bot: ""), "PendingModel 3", "空名字等同于没名字")
    hExpect(subtitle(bot: "   "), "PendingModel 3", "只有空白的名字也算没名字")
    hExpect(subtitle(bot: nil, display: .pending, model: nil), "",
            "名字和模型都没到货 → 空串(调用方整行别画),不是「· 」也不是 id")
    hExpect(subtitle(bot: nil, display: .real, model: nil), "",
            "该显示真名但目录没到货、名字也没到货 → 仍然空串")
    hExpect(subtitle(bot: nil, display: .blind), "PendingModel",
            "名字没到货但已知是盲盒 → PendingModel 单独成行")
    hExpect(subtitle("user_user", bot: nil), "",
            "user_user 名字没到货 → 空串,不顶 peer id")

    // 边界:任何一帧的输出里都不该出现「·」孤零零挂在一头。
    for d in [ModelNameDisplay.real, .blind, .pending] {
        for bot in [nil, "", "小绿"] as [String?] {
            for model in [nil, "PendingModel 3"] as [String?] {
                let s = subtitle(bot: bot, display: d, model: model)
                hExpectTrue(!s.hasPrefix("·") && !s.hasSuffix("·") && !s.contains("·  "),
                            "不出现悬空的分隔符:display=\(d) bot=\(bot ?? "nil") model=\(model ?? "nil") → \"\(s)\"")
            }
        }
    }

    // ── 空会话大标题 ────────────────────────────────────────────────────────

    hExpect(ConversationHeaderLabel.emptyStateTitle(
                conversationType: "user_bot", subtitle: "小绿 · PendingModel 3",
                conversationTitle: "未命名"),
            "小绿 · PendingModel 3", "有副标题就用副标题")
    hExpect(ConversationHeaderLabel.emptyStateTitle(
                conversationType: "user_bot", subtitle: "", conversationTitle: "未命名"),
            "未命名", "副标题还没有内容 → 回落会话标题,不是空白、更不是 id")
    hExpect(ConversationHeaderLabel.emptyStateTitle(
                conversationType: "user_user", subtitle: "无所谓", conversationTitle: "阿泽"),
            "阿泽", "user_user 恒用会话标题(对方名字)")

    // ── 真正的回归断言:目录空 + 事实没到货,一个字都不许漏 ──────────────────
    //
    // 作者看到的是 `anthropic/claude-opus-5` 的尾巴 `claude-opus-5`,以及一串
    // bot UUID。这两样东西现在**根本进不来这个函数** —— 它只收「已解析的名字
    // 或 nil」。这条断言守的是这个契约:喂 nil 进去,吐不出任何标识符。
    let coldStart = subtitle(bot: nil, display: .pending, model: nil)
    hExpectTrue(coldStart.isEmpty, "冷启动首帧:没有名字、没有目录、没有事实 → 什么都不画")
    hExpectTrue(!coldStart.contains("claude") && !coldStart.contains("-"),
                "冷启动首帧不含任何 slug / UUID 形状的东西")
}
