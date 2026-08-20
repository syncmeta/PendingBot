import Foundation

/// 群账号(group_account subject)成员与权限端点封装。对应 edge
/// `/v1/group-subjects/:id/members*` + `/transfer`
/// (apps/edge/src/routes/group-subjects.ts)。
///
/// 权限矩阵(spec v2 §4.3 α,服务端 SECURITY DEFINER grp_* RPC 最终裁决,
/// 客户端只做 UX 预检):
///
/// | 操作                        | owner | admin | member |
/// |----------------------------|-------|-------|--------|
/// | 加 member / 踢 member       | ✅    | ✅    | ❌      |
/// | 升降 admin / 转让 / 解散     | ✅    | ❌    | ❌      |
/// | 钱包充值 / 认缴 / 取出       | ✅    | ✅    | ✅      |
///
/// 约束:单 owner;不能踢 admin(owner 需先 demote);转让后原 owner 自动降
/// 为 admin;owner 不能 leave(先转让或解散)。钱包侧动作见 GroupWalletService。
enum GroupSubjectService {

    // MARK: - 读: 成员列表

    /// `GET /v1/group-subjects/:id/members` 的成员行。RLS 语义:owner/admin
    /// 看全员;member 只看到自己那一行(不泄露花名册)。
    struct MemberRow: Decodable, Identifiable, Hashable {
        let userId: String
        /// owner / admin / member。
        let role: String
        let grantedBy: String?
        let grantedAt: String?

        var id: String { userId }
        var isOwner: Bool { role == "owner" }
        var isAdmin: Bool { role == "admin" }

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case role
            case grantedBy = "granted_by"
            case grantedAt = "granted_at"
        }
    }

    static func members(subjectId: String, api: APIClient = APIClient()) async throws -> [MemberRow] {
        struct Payload: Decodable { let members: [MemberRow] }
        let payload: Payload = try await api.get("/v1/group-subjects/\(subjectId)/members")
        return payload.members
    }

    // MARK: - 写: 加人 / 踢人 / 升降 / 转让

    /// `POST /:id/members {user_id}` — 加成员(owner|admin)。
    static func addMember(subjectId: String, userId: String, api: APIClient = APIClient()) async throws {
        struct Body: Encodable { let user_id: String }
        try await api.postVoid("/v1/group-subjects/\(subjectId)/members", body: Body(user_id: userId))
    }

    /// `DELETE /:id/members/:userId` — 踢成员(owner|admin;不能踢 admin,
    /// owner 需先 demote;不能踢 owner)。
    static func removeMember(subjectId: String, userId: String, api: APIClient = APIClient()) async throws {
        try await api.deleteVoid("/v1/group-subjects/\(subjectId)/members/\(userId)")
    }

    /// `POST /:id/members/:userId/promote` — member→admin(仅 owner)。
    static func promote(subjectId: String, userId: String, api: APIClient = APIClient()) async throws {
        try await api.postVoid("/v1/group-subjects/\(subjectId)/members/\(userId)/promote")
    }

    /// `POST /:id/members/:userId/demote` — admin→member(仅 owner)。
    static func demote(subjectId: String, userId: String, api: APIClient = APIClient()) async throws {
        try await api.postVoid("/v1/group-subjects/\(subjectId)/members/\(userId)/demote")
    }

    /// `POST /:id/transfer {to_user_id}` — 转让群主(仅 owner;目标须已是
    /// 成员)。转让后调用者自动降为 admin。
    static func transferOwnership(subjectId: String, toUserId: String, api: APIClient = APIClient()) async throws {
        struct Body: Encodable { let to_user_id: String }
        try await api.postVoid("/v1/group-subjects/\(subjectId)/transfer", body: Body(to_user_id: toUserId))
    }

    // MARK: - 错误文案

    /// 端点错误 → 中文提示。grp_* RPC 的错误经 edge 翻成典型信封:
    /// 403 subject_forbidden(角色不够)、404 subject_not_found、
    /// 409 conflict(违反矩阵约束,如"不能踢 admin"),message 多为可直显文案。
    static func friendlyMessage(_ error: Error) -> String {
        if let apiErr = error as? APIError {
            switch apiErr.code {
            case "subject_forbidden": return apiErr.errorDescription ?? "没有权限执行此操作"
            case "subject_not_found": return "群账号不存在或已停用"
            default:
                if let desc = apiErr.errorDescription, !desc.isEmpty { return desc }
            }
        }
        return (error as NSError).localizedDescription
    }
}
