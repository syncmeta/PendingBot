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
        try await api.get("/v1/me/balance")
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

    private struct RedeemErrorBody: Decodable {
        let error: String?
    }

    static func redeem(code: String, api: APIClient = APIClient()) async throws -> RedeemResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RedeemError.empty }
        do {
            return try await api.post("/v1/me/redeem", body: ["code": trimmed])
        } catch let APIError.http(status, body) {
            throw mapRedeemError(status: status, body: body)
        } catch APIError.unauthorized {
            throw RedeemError.unauthorized
        }
    }

    private static func mapRedeemError(status: Int, body: String) -> RedeemError {
        let kind: String? = body.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(RedeemErrorBody.self, from: $0) }?
            .error
        switch kind {
        case "not_found":         return .notFound
        case "already_used":      return .alreadyUsed
        case "not_authenticated": return .unauthorized
        case "missing_code":      return .empty
        default:                  return .other("HTTP \(status)")
        }
    }

    // MARK: - History

    struct HistoryItem: Decodable, Identifiable {
        let id: String
        let kind: Kind
        /// Postgres-flavoured timestamp string. Parse with
        /// `ServerTimestamp.parse(_:)` for display.
        let createdAt: String
        let deltaCredits: Int
        let taskType: String?
        let modelId: String?
        let entryType: String?
        let reason: String?
        let billingStatus: String?

        enum Kind: String, Decodable {
            case consume, movement
        }

        enum CodingKeys: String, CodingKey {
            case id, kind
            case createdAt = "created_at"
            case deltaCredits = "delta_credits"
            case taskType = "task_type"
            case modelId = "model_id"
            case entryType = "entry_type"
            case reason
            case billingStatus = "billing_status"
        }
    }

    private struct HistoryResponse: Decodable {
        let items: [HistoryItem]
    }

    static func fetchHistory(limit: Int = 50, api: APIClient = APIClient()) async throws -> [HistoryItem] {
        let res: HistoryResponse = try await api.get(
            "/v1/me/billing/history",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return res.items
    }
}
