import SwiftUI

/// Shared presentation mapping for crew-session status + event types, used by
/// the T4.5 viewer on **both** PendingBot clients (iOS/iPad `RemoteSessionsView`
/// and macOS `MacRemoteSessionsView`). Labels the same wire vocab the same way
/// across platforms. Pure value transforms over SwiftUI's cross-platform
/// `Color`, so no platform gate.
enum SessionStatusStyle {
    static func runnerLabel(_ kind: String?) -> String {
        switch kind {
        case "local_claude_code": return "Claude Code"
        case "local_codex": return "Codex"
        case "local_opencode": return "OpenCode"
        case "local_kilo": return "Kilo"
        case "cloud_sandbox": return "云沙箱"
        case .none: return "runner 未定"
        case .some(let k): return k
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "queued": return "排队中"
        case "waiting_runner": return "等待 runner"
        case "running": return "运行中"
        case "waiting_permission": return "等待授权"
        case "idle": return "空闲"
        case "paused": return "已暂停"
        case "completed", "finished": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return status
        }
    }

    static func tint(_ status: String) -> Color {
        switch status {
        case "running", "waiting_runner", "waiting_permission": return .blue
        case "completed", "finished": return .green
        case "failed": return .red
        case "cancelled": return .secondary
        default: return .orange
        }
    }

    /// A session a viewer can still stop — pre-terminal states only.
    static func isStoppable(_ status: String) -> Bool {
        switch status {
        case "completed", "finished", "failed", "cancelled": return false
        default: return true
        }
    }

    static func eventLabel(_ eventType: String) -> String {
        switch eventType {
        case "queued": return "已排队"
        case "started": return "已启动"
        case "context_injected": return "注入上下文"
        case "status": return "状态更新"
        case "tool_call": return "工具调用"
        case "tool_result": return "工具结果"
        case "permission_requested": return "请求授权"
        case "permission_resolved": return "授权结果"
        case "artifact_created": return "产出文件"
        case "posted_to_crew": return "发到机组"
        case "blocked": return "被阻塞"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return eventType
        }
    }

    static func eventIcon(_ eventType: String) -> String {
        switch eventType {
        case "started", "queued": return "play.circle"
        case "context_injected": return "tray.and.arrow.down"
        case "tool_call": return "wrench.and.screwdriver"
        case "tool_result": return "arrow.turn.down.right"
        case "permission_requested", "permission_resolved": return "lock.shield"
        case "artifact_created": return "doc.badge.plus"
        case "posted_to_crew": return "bubble.left.and.bubble.right"
        case "blocked", "failed": return "exclamationmark.triangle"
        case "completed": return "checkmark.seal"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }

    static func eventTint(_ eventType: String) -> Color {
        switch eventType {
        case "tool_call", "tool_result": return .orange
        case "permission_requested", "permission_resolved": return .purple
        case "artifact_created", "posted_to_crew": return .teal
        case "blocked", "failed": return .red
        case "completed": return .green
        case "cancelled": return .secondary
        default: return .blue
        }
    }
}
