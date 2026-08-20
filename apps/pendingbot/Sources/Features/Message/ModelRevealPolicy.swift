import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - 模型盲盒的全局显示偏好
//
// 盲盒本来只有 bot 一级设置(bots.config.blindBox.revealMode)。这里加的是
// 压在它上面的**用户级**一档:一处管全部,不必逐个 bot 去改。
//
// 跟账号走(/v1/me/profile → users.custom_fields.model_reveal_preference),
// 不是设备本地 —— 「要不要看真名」是口味,不该分设备。
// ─────────────────────────────────────────────────────────────────────

enum ModelRevealPreference: String, CaseIterable, Identifiable {
    /// 跟随每个 bot 自己的设置 —— 加这个开关之前的行为。
    case followBot = "follow_bot"
    /// 总是显示真实模型名,不管 bot 设的是什么。
    case alwaysReal = "always_real"
    /// 总是盲盒(显示 PendingModel、给猜的入口),同样压过 bot。
    case alwaysBlind = "always_blind"

    /// UserDefaults / custom_fields 共用的键名。
    static let storageKey = "model_reveal_preference"
    static let `default`: ModelRevealPreference = .followBot

    /// 服务端来的字符串可能是任何东西(旧客户端写的、手改的 JSON)——
    /// 认不出就回到默认档,绝不 crash、也绝不静默变成另一档。
    static func normalized(_ raw: String?) -> ModelRevealPreference {
        guard let raw, let v = ModelRevealPreference(rawValue: raw) else { return .default }
        return v
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followBot:   return "跟随机器人"
        case .alwaysReal:  return "总是真实模型"
        case .alwaysBlind: return "总是盲盒"
        }
    }
}

/// 会话侧的盲盒事实,来自 `GET /v1/conversations/:id/model`。
///
/// `modelRevealed` 必须是**会话真的揭晓过**这个事实(而不是"按 bot 的
/// disclose 推出来的显示态")—— 揭晓不可逆,`always_blind` 也不该把它盖回去,
/// 所以两者不能混为一谈。
struct ModelRevealFacts: Equatable {
    let revealMode: String   // "surprise" | "disclose"
    let modelRevealed: Bool
    let hasPool: Bool
}

/// 判定结果。`showsRealName == false` 意味着 pill 显示 "PendingModel"。
struct ModelRevealDecision: Equatable {
    let showsRealName: Bool
    let offersGuess: Bool
}

enum ModelRevealPolicy {
    /// `facts == nil`:会话模型态还没取到(或取失败)。此时 pill 会回落到 bot
    /// 固定的模型名 —— 对 `alwaysBlind` 来说那就是漏名,所以这一档在未知态下
    /// 也按盲盒处理。
    static func decide(
        preference: ModelRevealPreference,
        facts: ModelRevealFacts?
    ) -> ModelRevealDecision {
        // 已经揭晓过的会话是不可逆的事实,任何档位都按已揭晓走。
        let revealed = facts?.modelRevealed ?? false
        if revealed {
            return ModelRevealDecision(showsRealName: true, offersGuess: false)
        }

        switch preference {
        case .alwaysReal:
            return ModelRevealDecision(showsRealName: true, offersGuess: false)

        case .alwaysBlind:
            // 没有模型池就没有候选可猜,只藏名不给入口。
            return ModelRevealDecision(showsRealName: false, offersGuess: facts?.hasPool ?? false)

        case .followBot:
            guard let facts else {
                // 老行为:状态未取到 → 显示 bot 固定模型名。
                return ModelRevealDecision(showsRealName: true, offersGuess: false)
            }
            if facts.revealMode == "disclose" {
                return ModelRevealDecision(showsRealName: true, offersGuess: false)
            }
            return ModelRevealDecision(showsRealName: false, offersGuess: facts.hasPool)
        }
    }
}
