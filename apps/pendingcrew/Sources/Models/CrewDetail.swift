import Foundation

/// `GET /v1/crews/:crewId` 详情响应。
///
/// 一个 nested struct 包住 crew + parents/children/shares/captain；
/// 一坨字段全平铺到 store 会再走回老 PendingCrew 那种 "10+ @Published
/// 字典爆炸" 的老路（见 AppModel 注释 + spec v2 §11）。Keep it
/// structured —— store 把 detail 按 crewId 存一份完整 `CrewDetail`。
struct CrewDetail: Decodable, Equatable, Hashable {
    let crew: CrewBody
    let parents: [CrewLink]
    let children: [CrewLink]
    let shares: [ResponsibilityShare]
    let captain: Captain?

    struct CrewBody: Decodable, Equatable, Hashable {
        let id: String
        let title: String
        let responsibleSubjectId: String
        let runtimeLocation: String
        let workingDirectory: String?
        let tag: String?
        let captainBotId: String?
        let status: String?
        let createdAt: String
        let updatedAt: String

        var runtimeLocationKind: CrewSummary.RuntimeLocation? {
            CrewSummary.RuntimeLocation(rawValue: runtimeLocation)
        }
    }

    struct CrewLink: Decodable, Equatable, Hashable {
        let crewId: String
        let title: String
        /// child 在这条 parent-child 边上保留的责任份额（bps，0-10000）。
        let childShareBps: Int
    }

    struct ResponsibilityShare: Decodable, Equatable, Hashable {
        let subjectId: String
        let shareBps: Int
        let isTiebreaker: Bool
        let displayName: String
        /// `subjects.subject_type` —— 一般是 `user_account` / `group_account`。
        let kind: String
    }

    struct Captain: Decodable, Equatable, Hashable {
        let botId: String
        let displayName: String
    }
}
