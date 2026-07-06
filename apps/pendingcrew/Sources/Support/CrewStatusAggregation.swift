import Foundation

/// crew 级状态点颜色（侧栏头像右上角；crew-sidebar-status spec 2026-07-06 §3）。
/// 优先级 红 > 黄 > 绿 > 灰；不满足任何条件（无 session 记录且无 attention）不画。
enum CrewStatusDotColor: Equatable {
    /// 任一 session 健康异常（未登录/额度到顶）且进程存活 —— crew 自己解决不了的错。
    case red
    /// 机长点亮的 attention（`raise_attention`）。
    case yellow
    /// 任一 session 正在干活（跑 turn）。
    case green
    /// 有 session 记录但全空闲/已退出。
    case gray
}

/// 参与聚合的单个 session 状态信号 —— 从 `CrewSessionRun` 抽出的纯值快照，
/// 让聚合成为可单测的纯函数（不依赖 SwiftUI / ObservableObject）。
struct CrewSessionStatusSignal: Equatable {
    /// 进程存活（`run.status == .running`）。
    let isAlive: Bool
    /// 正在跑 turn（`run.isWorking`；退出后恒 false）。
    let isWorking: Bool
    /// runner 健康异常（`run.health != nil`：未登录/额度到顶）。
    let hasHealthIssue: Bool
}

/// crew 状态点聚合纯函数。数据源：sessions 来自 `CrewSessionRunner.runs`
/// 里本 crew 的 run；attention 来自 `LocalCrewStore` 持久化的 `attentionReason`。
enum CrewStatusAggregation {
    /// 取最高优先级：红（异常且存活）> 黄（attention）> 绿（干活中）> 灰（有记录
    /// 但全闲/退）。`nil` = 无任何 session 记录且无 attention —— 不画点，避免
    /// 所有闲置 crew 都挂灰点造成噪音。
    static func dot(
        sessions: [CrewSessionStatusSignal],
        attentionReason: String?
    ) -> CrewStatusDotColor? {
        if sessions.contains(where: { $0.hasHealthIssue && $0.isAlive }) { return .red }
        if let reason = attentionReason, !reason.isEmpty { return .yellow }
        if sessions.contains(where: { $0.isWorking }) { return .green }
        return sessions.isEmpty ? nil : .gray
    }
}
