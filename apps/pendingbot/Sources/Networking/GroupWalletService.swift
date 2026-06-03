import Foundation

/// 群钱包(实缴池 + 认缴)端点封装。对应 edge `/v1/group-subjects/:id/*`
/// (apps/edge/src/routes/group-subjects.ts)。模型见 docs/superpowers/specs/
/// 2026-06-02-group-billing-pledge-model-design.md:
///
/// - **实缴(topup)**: 真把 PNC 从个人钱包转进群池;份额随 share-index 衰减,
///   可随时部分取出(withdraw)或退群全额退(leave)。
/// - **认缴(pledge)**: 钱不动,留个人钱包;群消费时按占比当场直扣。设额度 /
///   清零(0)走同一端点。
///
/// 金额单位一律 **PNC**(端点收发整数 credits;内部 micros 不出网)。读端点
/// 返回的展示值是 PNC 小数(已花到小数位很正常)。
enum GroupWalletService {

    // MARK: - 读: 群钱包视图

    /// `GET /v1/group-subjects/:id/wallet` 的返回。owner/admin 看全员明细
    /// (membersComplete=true);member 仅含自己。
    struct Wallet: Decodable {
        let subjectId: String
        /// 调用者在群里的角色:owner / admin / member。
        let role: String
        /// 实缴池余额(PNC)。
        let poolPnc: Double
        /// S = 池 + Σ生效认缴(PNC)。分摊/占比的分母。
        let totalStakePnc: Double
        let me: Member
        /// 有实缴或认缴的成员明细(无份额成员不在此列)。
        let members: [Member]
        /// true = 全员明细可见(owner/admin);false = 仅自己。
        let membersComplete: Bool

        struct Member: Decodable, Identifiable {
            let userId: String
            /// 我实缴的当前可取出份额(share_now,PNC)。
            let contributionShareNowPnc: Double
            /// 我设置的认缴额度(PNC;0 = 未认缴)。
            let pledgePnc: Double
            /// 当前生效认缴 = min(认缴, 个人余额)(PNC)。余额见底 → 0。
            let pledgeEffectivePnc: Double
            /// 我的总份额 = 实缴 share_now + 生效认缴(PNC)。
            let stakePnc: Double
            /// 占比 = stake / S(0…1)。同时是分摊比例 + 实缴可取出比例。
            let shareRatio: Double

            var id: String { userId }

            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case contributionShareNowPnc = "contribution_share_now_pnc"
                case pledgePnc = "pledge_pnc"
                case pledgeEffectivePnc = "pledge_effective_pnc"
                case stakePnc = "stake_pnc"
                case shareRatio = "share_ratio"
            }
        }

        enum CodingKeys: String, CodingKey {
            case subjectId = "subject_id"
            case role
            case poolPnc = "pool_pnc"
            case totalStakePnc = "total_stake_pnc"
            case me
            case members
            case membersComplete = "members_complete"
        }
    }

    static func fetch(subjectId: String, api: APIClient = APIClient()) async throws -> Wallet {
        try await api.get("/v1/group-subjects/\(subjectId)/wallet")
    }

    // MARK: - 写: 实缴 / 认缴 / 取出 / 退群 / 解散

    private struct CreditsBody: Encodable { let credits: Int }

    struct TopupResult: Decodable {
        let ok: Bool
        let contributedPnc: Double
        enum CodingKeys: String, CodingKey { case ok; case contributedPnc = "contributed_pnc" }
    }

    /// `POST /:id/topup {credits}` — 从个人钱包注资进群池。402 余额不足。
    @discardableResult
    static func topup(subjectId: String, credits: Int, api: APIClient = APIClient()) async throws -> TopupResult {
        try await api.post("/v1/group-subjects/\(subjectId)/topup", body: CreditsBody(credits: credits))
    }

    struct PledgeResult: Decodable {
        let ok: Bool
        let pledgePnc: Int
        enum CodingKeys: String, CodingKey { case ok; case pledgePnc = "pledge_pnc" }
    }

    /// `POST /:id/pledge {credits}` — 设/改认缴额度;credits=0 撤销。钱不动。
    @discardableResult
    static func pledge(subjectId: String, credits: Int, api: APIClient = APIClient()) async throws -> PledgeResult {
        try await api.post("/v1/group-subjects/\(subjectId)/pledge", body: CreditsBody(credits: credits))
    }

    struct WithdrawResult: Decodable {
        let ok: Bool
        let withdrawnPnc: Double
        enum CodingKeys: String, CodingKey { case ok; case withdrawnPnc = "withdrawn_pnc" }
    }

    /// `POST /:id/withdraw {credits}` — 部分取出(≤ 当前 share_now),退回个人钱包,留群。
    @discardableResult
    static func withdraw(subjectId: String, credits: Int, api: APIClient = APIClient()) async throws -> WithdrawResult {
        try await api.post("/v1/group-subjects/\(subjectId)/withdraw", body: CreditsBody(credits: credits))
    }

    struct LeaveResult: Decodable {
        let ok: Bool
        let refundedPnc: Double
        let contributionsRefunded: Int
        enum CodingKeys: String, CodingKey {
            case ok
            case refundedPnc = "refunded_pnc"
            case contributionsRefunded = "contributions_refunded"
        }
    }

    /// `POST /:id/leave` — 退群:按 share_now 全额退回个人钱包。
    @discardableResult
    static func leave(subjectId: String, api: APIClient = APIClient()) async throws -> LeaveResult {
        try await api.postEmpty("/v1/group-subjects/\(subjectId)/leave")
    }

    struct DissolveResult: Decodable {
        let ok: Bool
        let refundedContributors: Int
        let totalRefundedPnc: Double
        enum CodingKeys: String, CodingKey {
            case ok
            case refundedContributors = "refunded_contributors"
            case totalRefundedPnc = "total_refunded_pnc"
        }
    }

    /// `POST /:id/dissolve` — 解散群(仅 owner):按比例退所有出资人。
    @discardableResult
    static func dissolve(subjectId: String, api: APIClient = APIClient()) async throws -> DissolveResult {
        try await api.postEmpty("/v1/group-subjects/\(subjectId)/dissolve")
    }

    // MARK: - 错误文案

    /// 把端点错误翻成中文提示。多数路由已带 message(如 402 "余额不足"、403
    /// "非群成员"/"仅群主可解散"),APIError 会原样透出;只有 501
    /// polar_not_configured 无 message,这里兜一句"计费未配置"。
    static func friendlyMessage(_ error: Error) -> String {
        if let apiErr = error as? APIError {
            if apiErr.code == "polar_not_configured" { return "计费未配置,请稍后再试。" }
            if let desc = apiErr.errorDescription, !desc.isEmpty { return desc }
        }
        return (error as NSError).localizedDescription
    }
}
