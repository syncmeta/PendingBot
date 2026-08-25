// Standalone test for ModelRevealPolicy — the pure decision function behind
// the global 「显示 PendingModel 还是真实模型」 setting.
//
// This branch has no iOS unit-test target yet (feat/ios-unit-tests hasn't
// landed on main), and the policy is dependency-free Swift, so it's exercised
// by compiling it together with this file:
//
//     apps/pendingbot/Tests/run-model-reveal-policy-tests.sh
//
// When the real test target lands, port these cases into it and delete the
// script — the assertions translate 1:1 to XCTest/swift-testing.

import Foundation

// ── tiny harness ────────────────────────────────────────────────────────
var failures = 0
var checks = 0

func expect(
    _ actual: ModelRevealDecision,
    _ expected: ModelRevealDecision,
    _ what: String,
    line: Int = #line
) {
    checks += 1
    if actual != expected {
        failures += 1
        print("✘ \(what) (line \(line))")
        print("    expected display=\(expected.display) offersGuess=\(expected.offersGuess)")
        print("    actual   display=\(actual.display) offersGuess=\(actual.offersGuess)")
    }
}

func expectTrue(_ cond: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !cond {
        failures += 1
        print("✘ \(what) (line \(line))")
    }
}

func decide(_ pref: ModelRevealPreference, _ facts: ModelRevealFacts?) -> ModelRevealDecision {
    ModelRevealPolicy.decide(preference: pref, facts: facts)
}

func facts(_ mode: String, revealed: Bool, pool: Bool = true) -> ModelRevealFacts {
    ModelRevealFacts(revealMode: mode, modelRevealed: revealed, hasPool: pool)
}

let real = ModelRevealDecision(display: .real, offersGuess: false)
let blindGuessable = ModelRevealDecision(display: .blind, offersGuess: true)
let blindOnly = ModelRevealDecision(display: .blind, offersGuess: false)
/// 事实还没到货 —— 模型这一格根本不渲染。
let pending = ModelRevealDecision(display: .pending, offersGuess: false)

@main
struct ModelRevealPolicyTests {
    static func main() {
    // ── follow_bot — must reproduce today's behaviour exactly ───────────────

    expect(decide(.followBot, facts("surprise", revealed: false)), blindGuessable,
           "follow_bot: 盲盒未揭晓 → 显示 PendingModel + 可猜")
    expect(decide(.followBot, facts("surprise", revealed: true)), real,
           "follow_bot: 盲盒已揭晓 → 真名,不再给猜")
    expect(decide(.followBot, facts("disclose", revealed: false)), real,
           "follow_bot: bot 设为披露 → 真名,不给猜")
    expect(decide(.followBot, facts("disclose", revealed: true)), real,
           "follow_bot: 披露 + 已揭晓 → 真名")
    expect(decide(.followBot, facts("surprise", revealed: false, pool: false)), blindOnly,
           "follow_bot: 没有模型池 → 不给猜(但仍按盲盒隐藏)")
    expect(decide(.followBot, nil), pending,
           "follow_bot: 会话状态未取到 → 什么都不显示(既不漏真名也不先说 PendingModel)")
    expectTrue(!decide(.followBot, nil).showsRealName,
               "follow_bot: 未知态不算「显示真名」—— 这是 Todo #10 那一闪的病根")

    // ── always_real — overrides the bot in the "show me the truth" direction ─

    expect(decide(.alwaysReal, facts("surprise", revealed: false)), real,
           "always_real: 压过 bot 的 surprise → 真名")
    expect(decide(.alwaysReal, facts("surprise", revealed: false, pool: false)), real,
           "always_real: 无池也一样显示真名")
    expect(decide(.alwaysReal, facts("disclose", revealed: false)), real,
           "always_real: disclose 不变")
    expect(decide(.alwaysReal, nil), real,
           "always_real: 状态未取到 → 仍显示(回落的)真名")
    expect(decide(.alwaysReal, facts("surprise", revealed: true)), real,
           "always_real: 已揭晓 → 真名,不给猜")

    // ── always_blind — overrides the bot in the "keep it a game" direction ──

    expect(decide(.alwaysBlind, facts("disclose", revealed: false)), blindGuessable,
           "always_blind: 压过 bot 的 disclose → PendingModel + 可猜")
    expect(decide(.alwaysBlind, facts("surprise", revealed: false)), blindGuessable,
           "always_blind: surprise 不变")
    expect(decide(.alwaysBlind, facts("surprise", revealed: true)), real,
           "always_blind: 已揭晓的会话不可逆,仍显示真名")
    expect(decide(.alwaysBlind, facts("disclose", revealed: true)), real,
           "always_blind: 披露 bot 且真揭晓过 → 仍显示真名")
    expect(decide(.alwaysBlind, facts("disclose", revealed: false, pool: false)), blindOnly,
           "always_blind: 无池 → 藏名但不给猜(没有候选可猜)")
    expect(decide(.alwaysBlind, nil), blindOnly,
           "always_blind: 状态未取到 → 也不能漏出回落的真名")

    // ── pending 档不能被误当成另外两档 ───────────────────────────────────────

    expectTrue(pending != blindOnly, "pending 不等于 blind —— 一个不画,一个画 PendingModel")
    expectTrue(pending != real, "pending 不等于 real")
    expectTrue(!pending.showsRealName, "pending 不是真名")

    // ── wire format ─────────────────────────────────────────────────────────

    expectTrue(ModelRevealPreference.default == .followBot, "默认档位是 follow_bot")
    expectTrue(ModelRevealPreference.followBot.rawValue == "follow_bot", "follow_bot rawValue")
    expectTrue(ModelRevealPreference.alwaysReal.rawValue == "always_real", "always_real rawValue")
    expectTrue(ModelRevealPreference.alwaysBlind.rawValue == "always_blind", "always_blind rawValue")
    expectTrue(ModelRevealPreference.allCases.count == 3, "只有三档")
    expectTrue(ModelRevealPreference(rawValue: "nonsense") == nil, "未知值不解码成某一档")
    expectTrue(ModelRevealPreference.normalized("nonsense") == .followBot, "未知值归一化到 follow_bot")
    expectTrue(ModelRevealPreference.normalized("always_blind") == .alwaysBlind, "已知值原样归一化")

    // ── report ──────────────────────────────────────────────────────────────

    if failures == 0 {
        print("✔ ModelRevealPolicy — \(checks) checks passed")
        exit(0)
    } else {
        print("✘ ModelRevealPolicy — \(failures)/\(checks) checks FAILED")
        exit(1)
    }
    }
}
