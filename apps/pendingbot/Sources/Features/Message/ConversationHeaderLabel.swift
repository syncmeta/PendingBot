import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - 会话头部那两行字怎么拼
//
// 拉成纯函数(跟 ModelRevealPolicy 一个路数)是因为 Todo #10 的病**整个**
// 长在这几行的回落上:
//
//   · bot 名字没解析出来 → 顶 `conversation.bot_id`(一串裸 UUID)
//   · 模型目录没加载完   → 顶 slug 的尾巴(正好是上游厂商的模型名)
//   · 会话盲盒事实没到货 → 先按「显示真名」画,到货再改口成 PendingModel
//
// 三条都是同一个错误:**拿内部标识符 / 该藏的信息当占位符**。而占位符的正确
// 答案不是换个词,是「没值就别画这一格」。
//
// 原来这些逻辑是 ConversationView 里的 private computed var,考不了,只能
// 靠肉眼盯着看闪没闪 —— 而它恰恰只在冷启动的头几百毫秒里错。搬出来之后
// 每种「还没到货」的组合都能用断言钉死。
// ─────────────────────────────────────────────────────────────────────

enum ConversationHeaderLabel {

    /// 头部副标题 / 空会话大标题里的那串 "<bot 名> · <模型名>"。
    ///
    /// - Parameters:
    ///   - conversationType: `conversation_type`。`user_user` 没有模型这一格。
    ///   - botDisplayName: 已解析出来的 bot 名;nil / 空 = **还没解析出来**。
    ///     绝不接受 id 作为它的回落 —— 调用方也不许在传进来之前自己顶一个。
    ///   - display: `ModelRevealPolicy` 的判定档位。
    ///   - modelName: 已经过模型目录解析的友好名;nil = 目录还解不出这个 slug。
    ///     同样绝不接受 slug 或 slug 尾巴作为它的回落。
    /// - Returns: 拼好的一行;**空串表示这一行还没有内容,调用方整行别画**。
    static func subtitle(
        conversationType: String?,
        botDisplayName: String?,
        display: ModelNameDisplay,
        modelName: String?
    ) -> String {
        let base = (botDisplayName ?? "").trimmingCharacters(in: .whitespaces)
        // user_user 单聊没有 bot · model 这一格,名字就是全部。
        guard conversationType != "user_user" else { return base }

        let tag: String? = {
            switch display {
            case .pending:
                // 事实还没到货 —— 既不能说真名(可能是盲盒会话,说了就是漏),
                // 也不能说 PendingModel(可能是披露型 bot,说了要改口)。
                return nil
            case .blind:
                return "PendingModel"
            case .real:
                // 目录解不出就不画这一格。回落 slug 尾巴 = 漏上游模型名。
                return modelName
            }
        }()

        switch (base.isEmpty, tag) {
        case (false, .some(let t)): return "\(base) · \(t)"
        case (false, .none):        return base
        case (true,  .some(let t)): return t
        case (true,  .none):        return ""
        }
    }

    /// 空会话的大标题。`subtitle` 还没有内容时回落到会话标题 —— 而不是
    /// 画一格空白,更不是回落到任何 id。
    static func emptyStateTitle(
        conversationType: String?,
        subtitle: String,
        conversationTitle: String
    ) -> String {
        if conversationType == "user_user" { return conversationTitle }
        return subtitle.isEmpty ? conversationTitle : subtitle
    }
}
