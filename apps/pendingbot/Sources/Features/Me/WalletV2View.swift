#if os(iOS)
import SwiftUI

/// 钱包 v2 — PNC 余额 + 包列表（像运营商流量包）+ 近期账本。
/// 读 `/v1/me/wallet/v2`。dual-write 阶段与旧 WalletView 并存；cutover
/// 后成为主钱包页。设计见 docs/billing-v2-design.md §8。
struct WalletV2View: View {
    @State private var wallet: BillingService.WalletV2?
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        List {
            balanceSection
            if let w = wallet, !w.packs.isEmpty {
                packsSection(w.packs)
            }
            if let w = wallet, !w.recentLedger.isEmpty {
                ledgerSection(w.recentLedger)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("钱包")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    // MARK: - Balance

    @ViewBuilder
    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Self.formatPnc(wallet?.totalPncMicros ?? 0))
                        .font(Theme.Fonts.serif(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .monospacedDigit()
                    Text("PNC")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if let state = wallet?.thresholdState, let notice = Self.thresholdNotice(state) {
                    Label(notice.text, systemImage: notice.icon)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(notice.color)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.Palette.surface)
        } footer: {
            if let loadError {
                Text(loadError)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Color(hex: 0xB14B3C))
            } else {
                Text("PNC: Pending Name Credits")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
    }

    // MARK: - Packs

    @ViewBuilder
    private func packsSection(_ packs: [BillingService.WalletV2.Pack]) -> some View {
        Section {
            ForEach(packs) { pack in
                packRow(pack)
                    .listRowBackground(Theme.Palette.surface)
            }
        } header: {
            Text("我的包")
        } footer: {
            Text("按最快过期的先用。")
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
    }

    @ViewBuilder
    private func packRow(_ pack: BillingService.WalletV2.Pack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.channelLabel(pack.salesChannel))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer()
                Text("\(Self.formatPnc(pack.remainingPncMicros)) / \(Self.formatPnc(pack.initialPncMicros))")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.ink)
                    .monospacedDigit()
            }
            if let expiry = Self.expiryNotice(pack.expiresAt) {
                Text(expiry.text)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(expiry.urgent ? Color(hex: 0xB14B3C) : Theme.Palette.inkMuted)
            } else {
                Text("永不过期")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Ledger

    @ViewBuilder
    private func ledgerSection(_ entries: [BillingService.WalletV2.LedgerEntry]) -> some View {
        Section {
            ForEach(entries) { entry in
                ledgerRow(entry)
                    .listRowBackground(Theme.Palette.surface)
            }
        } header: {
            Text("近期账本")
        }
    }

    @ViewBuilder
    private func ledgerRow(_ entry: BillingService.WalletV2.LedgerEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.entryLabel(entry.entryType))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                Text(Self.formatTime(entry.createdAt))
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer()
            Text("\(entry.deltaPncMicros > 0 ? "+" : "")\(Self.formatPnc(entry.deltaPncMicros))")
                .font(Theme.Fonts.body)
                .foregroundStyle(entry.deltaPncMicros > 0 ? Color(hex: 0x2E7D5B) : Theme.Palette.ink)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Reload

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            wallet = try await BillingService.fetchWalletV2()
            loadError = nil
        } catch {
            loadError = "加载钱包失败，下拉重试。"
        }
    }

    // MARK: - Formatting helpers

    /// micros → "X.XX" PNC string (2 decimals). 1 PNC = 1_000_000 micros.
    static func formatPnc(_ micros: Int) -> String {
        let pnc = Double(micros) / 1_000_000.0
        return pncFormatter.string(from: NSNumber(value: pnc)) ?? String(format: "%.2f", pnc)
    }

    private static let pncFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private struct Notice { let text: String; let icon: String; let color: Color }

    private static func thresholdNotice(_ state: String) -> Notice? {
        switch state {
        case "low":
            return Notice(text: "余额偏低，建议充值。", icon: "exclamationmark.circle",
                          color: Color(hex: 0xB8862B))
        case "throttle":
            return Notice(text: "余额不足，已切换到经济模式（只用便宜模型）。",
                          icon: "tortoise.fill", color: Color(hex: 0xB14B3C))
        case "exhausted":
            return Notice(text: "余额花完了，请充值后继续。", icon: "xmark.octagon.fill",
                          color: Color(hex: 0xB14B3C))
        default:
            return nil
        }
    }

    private static func channelLabel(_ channel: String) -> String {
        switch channel {
        case "iap_ios", "iap_macos": return "App 内购买"
        case "lemon_squeezy":        return "网页充值"
        case "admin_grant":          return "官方赠送"
        case "group_topup":          return "群账户注资"
        case "group_refund":         return "退群返还"
        case "v1_migration":         return "历史余额迁移"
        default:                     return "充值包"
        }
    }

    private static func entryLabel(_ type: String) -> String {
        switch type {
        case "debit":       return "消费"
        case "credit":      return "充值"
        case "adjustment":  return "调整"
        case "refund":      return "退款"
        case "expired":     return "过期"
        case "group_topup": return "群注资"
        case "group_refund":return "退群返还"
        case "overdraft":   return "透支"
        default:            return type
        }
    }

    private struct ExpiryNotice { let text: String; let urgent: Bool }

    private static func expiryNotice(_ iso: String?) -> ExpiryNotice? {
        guard let iso else { return nil }
        let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso)
        guard let date else { return nil }
        let days = Int(date.timeIntervalSinceNow / 86_400)
        if days < 0 {
            return ExpiryNotice(text: "已过期", urgent: true)
        }
        if days <= 7 {
            return ExpiryNotice(text: "还剩 \(days) 天过期", urgent: true)
        }
        return ExpiryNotice(text: "\(dayFormatter.string(from: date)) 过期", urgent: false)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func formatTime(_ iso: String) -> String {
        let date = isoParser.date(from: iso) ?? isoParserNoFrac.date(from: iso)
        guard let date else { return iso }
        return displayFormatter.string(from: date)
    }
}
#endif
