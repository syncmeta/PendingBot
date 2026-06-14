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
    let captainBotId: String?
    let status: String?
    let createdAt: String
    let updatedAt: String
    /// 本地 crew DAG 的父边(本 crew 挂在哪些父 crew 之下)。**纯本地概念** ——
    /// `LocalCrewStore` 填实值;edge 端不下发这个字段,`EdgeBackend` 路径恒空。
    /// decode 时缺键 → 空数组(根 crew),不破坏现有 edge 响应解析。
    let parentCrewIds: [String]
    /// 机长跑哪个本机 coding agent（"claude_code" / "codex"）。**本地概念** ——
    /// `LocalCrewStore` 填值;edge 不下发 → 缺键兜底 nil（下游回落 `.codex`）。
    let captainAgentKind: String?

    /// memberwise init —— `LocalCrewStore.summary` 等本地构造点用。
    init(
        id: String,
        title: String,
        responsibleSubjectId: String,
        runtimeLocation: String,
        captainBotId: String?,
        status: String?,
        createdAt: String,
        updatedAt: String,
        parentCrewIds: [String] = [],
        captainAgentKind: String? = nil
    ) {
        self.id = id
        self.title = title
        self.responsibleSubjectId = responsibleSubjectId
        self.runtimeLocation = runtimeLocation
        self.captainBotId = captainBotId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentCrewIds = parentCrewIds
        self.captainAgentKind = captainAgentKind
    }

    /// 显式 decoder —— edge `GET /v1/crews` 不下发 `parentCrewIds` / `captainAgentKind`,缺键兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        responsibleSubjectId = try c.decode(String.self, forKey: .responsibleSubjectId)
        runtimeLocation = try c.decode(String.self, forKey: .runtimeLocation)
        captainBotId = try c.decodeIfPresent(String.self, forKey: .captainBotId)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        parentCrewIds = try c.decodeIfPresent([String].self, forKey: .parentCrewIds) ?? []
        captainAgentKind = try c.decodeIfPresent(String.self, forKey: .captainAgentKind)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, responsibleSubjectId, runtimeLocation
        case captainBotId, status, createdAt, updatedAt, parentCrewIds
        case captainAgentKind
    }

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
