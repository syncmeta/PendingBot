// 纯 Foundation、无平台门 —— app 侧 `CrewSessionRunner` 写、helper 侧
// `list_sessions` 工具读（离线 helper 唯一能碰的共享文件层）。
import Foundation

/// crew-sessions.json 的文件形状：按 crewId 分组的成员实时状态快照。
/// run 状态本体只在 app 内存（`sessionRunner.runs`），机长的 helper 是离线
/// 子进程看不到 —— 快照文件是给机长「点名」用的镜像（quota.json 同款模式）。
struct CrewSessionsSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let sessionId: String
        let name: String          // displayName（「机长」/「Claude Code · ab12cd」）
        let role: String          // "captain" | "worker"
        let brief: String         // 任务简述（captain 为空串）
        /// "working"(在跑回合) | "idle"(存活待命) | "error"(健康异常,进程活着) |
        /// "exited"(已退出,仍在切换条上)
        let state: String
        /// state=="error" 时的人话说明（未登录/额度到顶）。
        var healthDetail: String? = nil
    }

    /// crewId → 该 crew 的 session 条目（含 exited,直到被人从切换条移除）。
    var crews: [String: [Entry]] = [:]
    var updatedAt: String = ""

    static let fileName = "crew-sessions.json"

    /// 机长 `list_sessions` 的渲染：一行一个成员,直接可读。
    func renderRoster(crewId: String) -> String {
        guard let entries = crews[crewId], !entries.isEmpty else {
            return "本 crew 当前没有登记在案的 session（还没起过,或都已被移除）。"
        }
        let lines = entries.map { e -> String in
            let stateLabel: String
            switch e.state {
            case "working": stateLabel = "🟢 干活中"
            case "idle":    stateLabel = "🟡 空闲"
            case "error":   stateLabel = "🔴 异常" + (e.healthDetail.map { "（\($0)）" } ?? "")
            default:        stateLabel = "⚪ 已退出"
            }
            let briefPart = e.brief.isEmpty ? "" : " — \(e.brief)"
            return "- \(e.name) [\(e.role == "captain" ? "机长" : "worker")] \(stateLabel)\(briefPart) (session_id: \(e.sessionId))"
        }
        return lines.joined(separator: "\n") + "\n（快照时间 \(updatedAt)）"
    }
}
