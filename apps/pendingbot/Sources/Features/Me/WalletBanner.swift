import SwiftUI

/// 消息 tab 顶部的余额提醒细 banner(非弹窗、可关闭)。读 `/v1/me/wallet/v2`
/// 的 threshold_state:
///   - low      → "余额即将用完"
///   - throttle → "余额极低，可能限速"
/// sufficient / exhausted 不在这里提示(exhausted 会在实际发送时以 402
/// insufficient_balance 卡片拦下,不需要常驻横幅)。
///
/// 节流:每个状态每天最多提示一次(UserDefaults,按 user id 命名空间)。用户手动
/// 关闭当天该状态就不再出现;次日或状态升级(low→throttle)会重新出现。
struct WalletBanner: View {
    @State private var state: String?
    @State private var visible = false

    private static func throttleKey(_ userId: String, _ state: String) -> String {
        "pendingbot.walletBanner.\(userId).\(state).lastShown.v1"
    }

    var body: some View {
        Group {
            if visible, let copy = bannerCopy(state) {
                HStack(spacing: 8) {
                    Image(systemName: copy.icon)
                        .foregroundStyle(copy.color)
                    Text(copy.text)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer(minLength: 8)
                    Button {
                        dismissForToday()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.vertical, 8)
                .background(Theme.Palette.surfaceMuted)
            }
        }
        .task { await load() }
    }

    private struct Copy { let text: String; let icon: String; let color: Color }

    private func bannerCopy(_ state: String?) -> Copy? {
        switch state {
        case "low":
            return Copy(text: "余额即将用完，记得充值。", icon: "exclamationmark.circle",
                        color: Theme.Palette.gold)
        case "throttle":
            return Copy(text: "余额极低，可能限速（只用便宜模型）。", icon: "tortoise.fill",
                        color: Theme.Palette.danger)
        default:
            return nil
        }
    }

    private func load() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        guard let wallet = try? await BillingService.fetchWalletV2() else { return }
        let s = wallet.thresholdState
        guard s == "low" || s == "throttle" else { return }
        // 今天该状态已提示过 → 不再显示。
        let key = Self.throttleKey(userId, s)
        let last = UserDefaults.standard.double(forKey: key)
        if last > 0, Calendar.current.isDateInToday(Date(timeIntervalSince1970: last)) {
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        state = s
        withAnimation { visible = true }
    }

    private func dismissForToday() {
        // load() 已把今天记为已提示;这里只需收起。
        withAnimation { visible = false }
    }
}
