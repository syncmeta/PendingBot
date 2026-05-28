import Foundation

/// `GET /v1/crews` 列表里每行 crew 的 metadata。
///
/// 字段对齐 `apps/edge/src/routes/crews.ts` 里 `GET /v1/crews` 的响应
/// shape；新增字段时 edge 那边也要一起加。
///
/// `runtimeLocation` 是字符串而不是 enum —— spec v2 §6.2 留了 v1.1
/// 后续新增 location kind 的余地，client 端遇到没见过的值应当回落
/// 显示原始字符串，不应 decode 失败。
struct CrewSummary: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let responsibleSubjectId: String
    let runtimeLocation: String
    let tag: String?
    let captainBotId: String?
    let status: String?
    let createdAt: String
    let updatedAt: String

    enum RuntimeLocation: String {
        case localHost = "local_host"
        case peerDevice = "peer_device"
        case flyMachine = "fly_machine"

        var displayIcon: String {
            switch self {
            case .localHost: return "desktopcomputer"
            case .peerDevice: return "personalhotspot"
            case .flyMachine: return "cloud"
            }
        }

        var shortLabel: String {
            switch self {
            case .localHost: return "本机"
            case .peerDevice: return "peer 设备"
            case .flyMachine: return "Fly machine"
            }
        }
    }

    /// 把 wire 字符串映射成 enum；遇到未知值返回 nil（UI 上展示
    /// 原始 `runtimeLocation` 作为兜底）。
    var runtimeLocationKind: RuntimeLocation? {
        RuntimeLocation(rawValue: runtimeLocation)
    }
}
