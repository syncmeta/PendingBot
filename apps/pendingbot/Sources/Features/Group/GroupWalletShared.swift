import Foundation

/// Cross-platform formatting + the amount-form model for the group wallet,
/// used by the shared cross-platform `GroupWalletView` (iOS + macOS).
enum GroupWalletFormat {
    /// PNC 小数 → "1,234.56"。
    static func fmt(_ pnc: Double) -> String {
        pncFormatter.string(from: NSNumber(value: pnc)) ?? String(format: "%.2f", pnc)
    }

    /// 占比 0…1 → "12.3%"。
    static func pct(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    private static let pncFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
}

/// 群钱包金额操作 + 上下文(认缴当前值 / 取出上限)。充值/认缴/取出共用一个输入表单。
enum AmountForm: Identifiable {
    case topup
    case pledge(current: Double)
    case withdraw(max: Double)

    var id: String {
        switch self {
        case .topup: return "topup"
        case .pledge: return "pledge"
        case .withdraw: return "withdraw"
        }
    }

    var title: String {
        switch self {
        case .topup: return "充值(注资进群)"
        case .pledge: return "设 / 改认缴额度"
        case .withdraw: return "部分取出"
        }
    }

    var footer: String {
        switch self {
        case .topup:
            return "从你的个人钱包转入群池,按整数 PNC。"
        case .pledge(let cur):
            return "钱不动,留在你个人钱包;群消费时按占比直扣。当前认缴 \(GroupWalletFormat.fmt(cur)) PNC,填 0 撤销。"
        case .withdraw(let max):
            return "从群池退回你个人钱包(非提现)。最多可取 \(GroupWalletFormat.fmt(max)) PNC。"
        }
    }

    /// 认缴允许填 0(撤销);充值/取出必须 > 0。
    var allowsZero: Bool {
        if case .pledge = self { return true }
        return false
    }
}
