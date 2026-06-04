import Foundation

/// Wallet endpoint(s). Post billing-v2 migration the only live read is the
/// PNC wallet (`/v1/me/wallet/v2`, Polar/WalletDO source of truth). The old
/// v1 surface — `/v1/me/balance`, `/v1/me/redeem`, `/v1/me/billing/{summary,log}`
/// and their PND `*_credits` types — was only consumed by the now-deleted
/// `WalletView` and has been removed alongside it.
enum BillingService {

    // MARK: - Wallet v2 (PNC / packs)

    /// Billing v2 wallet read (`/v1/me/wallet/v2`). PNC is the unit; internal
    /// values are micros (1 PNC = 1_000_000 micros, $1 = 27 PNC).
    struct WalletV2: Decodable {
        let totalPncMicros: Int
        /// "sufficient" | "low" | "throttle" | "exhausted"
        let thresholdState: String
        let packs: [Pack]
        let recentLedger: [LedgerEntry]

        struct Pack: Decodable, Identifiable {
            let id: String
            let initialPncMicros: Int
            let remainingPncMicros: Int
            let expiresAt: String?
            let status: String
            let salesChannel: String
            let createdAt: String

            enum CodingKeys: String, CodingKey {
                case id
                case initialPncMicros = "initial_pnc_micros"
                case remainingPncMicros = "remaining_pnc_micros"
                case expiresAt = "expires_at"
                case status
                case salesChannel = "sales_channel"
                case createdAt = "created_at"
            }
        }

        struct LedgerEntry: Decodable, Identifiable {
            let id: String
            let packId: String?
            let entryType: String
            /// 账本来源(group_topup / group_refund / iap_ios / …)。后端 pnc_ledger
            /// 的 `source` 列;packs 退役后用于区分群注资/退款等场景。
            let source: String?
            let deltaPncMicros: Int
            /// 扣后余额。WalletDO 模型下后端恒返回 null(余额事实源在 Polar/DO,
            /// 不在每条账本行上),故必须可选 —— 否则整页解码失败。
            let balanceAfterPncMicros: Int?
            let createdAt: String

            enum CodingKeys: String, CodingKey {
                case id
                case packId = "pack_id"
                case entryType = "entry_type"
                case source
                case deltaPncMicros = "delta_pnc_micros"
                case balanceAfterPncMicros = "balance_after_pnc_micros"
                case createdAt = "created_at"
            }
        }

        enum CodingKeys: String, CodingKey {
            case totalPncMicros = "total_pnc_micros"
            case thresholdState = "threshold_state"
            case packs
            case recentLedger = "recent_ledger"
        }
    }

    static func fetchWalletV2(api: APIClient = APIClient()) async throws -> WalletV2 {
        try await api.get("/v1/me/wallet/v2")
    }
}
