import Foundation

/// Wallet endpoints. PND (Pending Name Dollar, ∂) is the user-facing
/// accounting unit; the wire format still uses the legacy `*_credits`
/// field names (cf. apps/edge/src/lib/billing.ts and the migration
/// note in apps/board/lib/format.ts).
enum BillingService {

    // MARK: - Balance

    struct Balance: Decodable {
        let balanceCredits: Int
        let lifetimeTopupCredits: Int
        let lifetimeSpentCredits: Int
        let minThreshold: Int

        enum CodingKeys: String, CodingKey {
            case balanceCredits = "balance_credits"
            case lifetimeTopupCredits = "lifetime_topup_credits"
            case lifetimeSpentCredits = "lifetime_spent_credits"
            case minThreshold = "min_threshold"
        }
    }

    static func fetchBalance(api: APIClient = APIClient()) async throws -> Balance {
        let b: Balance = try await api.get("/v1/me/balance")
        await MainActor.run { cachedBalanceCredits = b.balanceCredits }
        return b
    }

    /// Cache for the most recent balance the server told us. The Wallet
    /// view checks this before its `.task` initial fetch so the new value
    /// from a finished call is visible the moment the user opens it.
    /// Threading: MainActor-isolated.
    @MainActor
    private static var cachedBalanceCredits: Int?

    /// The most recently seen balance, if any. nil before the first call
    /// to fetchBalance / applySilentUpdate.
    @MainActor
    static var lastKnownBalance: Int? { cachedBalanceCredits }

    /// Push the worker-authoritative balance into the cache without
    /// triggering UI refresh side effects. Used by the realtime call
    /// flow — each /usage round-trip returns balance_credits but the
    /// call screen deliberately doesn't show it (avoiding mid-call
    /// distraction). Wallet picks the new value up on next render.
    @MainActor
    static func applySilentUpdate(balance: Int) {
        cachedBalanceCredits = balance
    }

    // MARK: - Redeem

    struct RedeemResponse: Decodable {
        let ok: Bool
        let credits: Int
        let newBalance: Int

        enum CodingKeys: String, CodingKey {
            case ok, credits
            case newBalance = "new_balance"
        }
    }

    /// User-facing redemption errors. We translate the wire `error`
    /// string into a typed case so the view can render Chinese copy
    /// without parsing raw API messages.
    enum RedeemError: Error, LocalizedError {
        case empty
        case notFound
        case alreadyUsed
        case unauthorized
        case other(String)

        var errorDescription: String? {
            switch self {
            case .empty:        return "请输入兑换码"
            case .notFound:     return "兑换码不存在或已停用"
            case .alreadyUsed:  return "这个码已经被用过了"
            case .unauthorized: return "登录已失效，请重新登录"
            case .other(let m): return m
            }
        }
    }

    static func redeem(code: String, api: APIClient = APIClient()) async throws -> RedeemResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RedeemError.empty }
        do {
            return try await api.post("/v1/me/redeem", body: ["code": trimmed])
        } catch let err as APIError {
            if case .unauthorized = err { throw RedeemError.unauthorized }
            if case let .http(status, _, _, _) = err {
                throw mapRedeemError(status: status, code: err.code)
            }
            throw err
        }
    }

    private static func mapRedeemError(status: Int, code: String?) -> RedeemError {
        // Codes the worker emits per the typed envelope (apps/edge/src/
        // routes/me.ts → /redeem path). Fallback covers legacy bodies
        // and unrecognised codes alike.
        switch code {
        case "redemption_not_found":    return .notFound
        case "redemption_already_used": return .alreadyUsed
        case "unauthorized":            return .unauthorized
        case "invalid_body":            return .empty
        default:                        return .other("HTTP \(status)")
        }
    }

    // MARK: - Summary

    /// Aggregated spend for the wallet's audit charts. The wallet no
    /// longer shows a per-call list — the detailed log lives in the
    /// board's /audit page. All `*Credits` values are PND (∂).
    struct Summary: Decodable {
        let rangeDays: Int
        let totalCredits: Int
        let byDay: [DayPoint]
        let byModel: [Slice]
        let byTask: [Slice]
        let byBot: [BotSlice]

        /// One UTC day's total spend. `day` is "YYYY-MM-DD".
        struct DayPoint: Decodable, Identifiable {
            let day: String
            let credits: Int
            var id: String { day }
        }

        /// A ranked breakdown row keyed by model id or task type.
        struct Slice: Decodable, Identifiable {
            let key: String
            let credits: Int
            var id: String { key }
        }

        /// A ranked breakdown row for a bot — `label` is the resolved
        /// display name, `key` the bot id.
        struct BotSlice: Decodable, Identifiable {
            let key: String
            let label: String
            let credits: Int
            var id: String { key }
        }

        enum CodingKeys: String, CodingKey {
            case rangeDays = "range_days"
            case totalCredits = "total_credits"
            case byDay = "by_day"
            case byModel = "by_model"
            case byTask = "by_task"
            case byBot = "by_bot"
        }
    }

    /// Supported aggregation windows for `fetchSummary`.
    enum SummaryRange: String, CaseIterable, Identifiable {
        case week = "7d"
        case month = "30d"
        case quarter = "90d"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .week:    return "7 天"
            case .month:   return "30 天"
            case .quarter: return "90 天"
            }
        }
    }

    static func fetchSummary(
        range: SummaryRange = .month,
        api: APIClient = APIClient()
    ) async throws -> Summary {
        try await api.get(
            "/v1/me/billing/summary",
            query: [URLQueryItem(name: "range", value: range.rawValue)]
        )
    }

    // MARK: - Log (per-call list)

    /// One audit_log row, shaped for the wallet's consumption list.
    /// `costCredits` is PND (∂); `botName` is the resolved bot
    /// display name (nil for non-bot tasks like group_router).
    struct LogEntry: Decodable, Identifiable {
        let id: String
        let createdAt: String
        let taskType: String
        let modelId: String
        let costCredits: Int
        let billingStatus: String
        let botId: String?
        let botName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case taskType = "task_type"
            case modelId = "model_id"
            case costCredits = "cost_credits"
            case billingStatus = "billing_status"
            case botId = "bot_id"
            case botName = "bot_name"
        }
    }

    struct LogPage: Decodable {
        let items: [LogEntry]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case items
            case nextCursor = "next_cursor"
        }
    }

    static func fetchLog(
        before: String? = nil,
        limit: Int = 50,
        api: APIClient = APIClient()
    ) async throws -> LogPage {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await api.get("/v1/me/billing/log", query: query)
    }
}
