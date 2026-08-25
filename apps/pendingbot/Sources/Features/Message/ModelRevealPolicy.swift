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

/// 模型名这一格该怎么画。三档,不是两档 —— 加的是 `.pending`。
///
/// 以前只有「真名 / PendingModel」两档,于是「还不知道该画哪个」只能挑一档
/// 先画上,再在事实到货后改口。挑真名就是漏(每次开会话都把上游模型名闪给
/// 用户看),挑 PendingModel 就是对披露型 bot 撒谎再改口。两个都不对:正确
/// 答案是**这一格先不画**,等事实到了再出。
enum ModelNameDisplay: Equatable {
    /// 显示真实模型名。
    case real
    /// 显示 "PendingModel"(盲盒)。
    case blind
    /// 还不知道 —— 整格不渲染,不占位、不闪、不漏。
    case pending
}

/// 判定结果。`display == .blind` 意味着 pill 显示 "PendingModel";
/// `.pending` 意味着 pill 上根本没有模型这一格。
struct ModelRevealDecision: Equatable {
    let display: ModelNameDisplay
    let offersGuess: Bool

    /// 只有 `.real` 算「显示真名」—— `.pending` 不是真名也不是盲盒。
    var showsRealName: Bool { display == .real }
}

enum ModelRevealPolicy {
    /// `facts == nil`:会话模型态还没取到(或取失败)。这一档以前是 fail-open
    /// —— follow_bot 直接显示 bot 固定的模型名,于是每次打开一个盲盒会话都会
    /// 先把真名闪一下再改口成 PendingModel。现在改成 `.pending`:不知道就先
    /// 不画。`alwaysBlind` 在未知态下仍按盲盒(它本来就不看真名);
    /// `alwaysReal` 是用户明确要看真名的档,未知态下照旧回落 bot 固定模型名
    /// —— 那不是漏,是他要的。
    static func decide(
        preference: ModelRevealPreference,
        facts: ModelRevealFacts?
    ) -> ModelRevealDecision {
        // 已经揭晓过的会话是不可逆的事实,任何档位都按已揭晓走。
        let revealed = facts?.modelRevealed ?? false
        if revealed {
            return ModelRevealDecision(display: .real, offersGuess: false)
        }

        switch preference {
        case .alwaysReal:
            return ModelRevealDecision(display: .real, offersGuess: false)

        case .alwaysBlind:
            // 没有模型池就没有候选可猜,只藏名不给入口。
            return ModelRevealDecision(display: .blind, offersGuess: facts?.hasPool ?? false)

        case .followBot:
            guard let facts else {
                // 事实还没到货 —— 既不能说真名(可能是盲盒会话,说了就是漏),
                // 也不能说 PendingModel(可能是披露型 bot,说了要改口)。先不画。
                return ModelRevealDecision(display: .pending, offersGuess: false)
            }
            if facts.revealMode == "disclose" {
                return ModelRevealDecision(display: .real, offersGuess: false)
            }
            return ModelRevealDecision(display: .blind, offersGuess: facts.hasPool)
        }
    }
}
