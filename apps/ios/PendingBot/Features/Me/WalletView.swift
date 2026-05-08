import SwiftUI

/// 钱包 — PND 余额、兑换码、最近账目。Pull-to-refresh 重拉余额 +
/// history 两个端点。Redeem 成功后乐观更新余额并把新条目并入列表头部。
struct WalletView: View {
    @State private var balance: BillingService.Balance?
    @State private var history: [BillingService.HistoryItem] = []
    @State private var loading = false
    @State private var loadError: String?

    @State private var redeemCode = ""
    @State private var redeemBusy = false
    @State private var redeemFlash: RedeemFlash?

    private struct RedeemFlash: Identifiable {
        let id = UUID()
        let kind: Kind
        let message: String
        enum Kind { case success, failure }
    }

    var body: some View {
        List {
            balanceSection
            redeemSection
            historySection
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatPnd(balance?.balanceCredits ?? 0))
                        .font(Theme.Fonts.serif(size: 40, weight: .bold))
                        .foregroundStyle(Theme.Palette.ink)
                        .monospacedDigit()
                    Text("PND")
                        .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if let b = balance, b.minThreshold > 0, b.balanceCredits < b.minThreshold {
                    Label("余额已低于阈值 \(formatPnd(b.minThreshold)) PND，下次发消息可能被拒。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Color(hex: 0xB14B3C))
                        .padding(.top, 2)
                }

                HStack(spacing: 16) {
                    miniStat(label: "累计入账", value: balance?.lifetimeTopupCredits ?? 0)
                    miniStat(label: "累计消费", value: balance?.lifetimeSpentCredits ?? 0)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .listRowBackground(Theme.Palette.surface)
        } footer: {
            if let loadError {
                Text(loadError)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Color(hex: 0xB14B3C))
            } else {
                Text("PND: Pending Name Dollar")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
    }

    private func miniStat(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.inkMuted)
            Text(formatPnd(value))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.ink)
                .monospacedDigit()
        }
    }

    // MARK: - Redeem

    @ViewBuilder
    private var redeemSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("输入兑换码", text: $redeemCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .disabled(redeemBusy)
                    .submitLabel(.go)
                    .onSubmit { Task { await submitRedeem() } }

                Button {
                    Task { await submitRedeem() }
                } label: {
                    if redeemBusy {
                        ProgressView()
                    } else {
                        Text("兑换")
                            .font(Theme.Fonts.body)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(redeemBusy || redeemCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("兑换码")
        } footer: {
            if let flash = redeemFlash {
                Text(flash.message)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(flash.kind == .success
                                     ? Color(hex: 0x2E7D5B)
                                     : Color(hex: 0xB14B3C))
                    .id(flash.id)
            }
        }
    }

    private func submitRedeem() async {
        let code = redeemCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !redeemBusy else { return }
        redeemBusy = true
        defer { redeemBusy = false }
        do {
            let res = try await BillingService.redeem(code: code)
            redeemCode = ""
            redeemFlash = .init(
                kind: .success,
                message: "兑换成功 +\(formatPnd(res.credits)) PND，新余额 \(formatPnd(res.newBalance)) PND"
            )
            // Optimistic local update; the next reload() will reconcile.
            if let b = balance {
                balance = .init(
                    balanceCredits: res.newBalance,
                    lifetimeTopupCredits: b.lifetimeTopupCredits + res.credits,
                    lifetimeSpentCredits: b.lifetimeSpentCredits,
                    minThreshold: b.minThreshold
                )
            }
            Haptics.success()
            // Pull fresh history so the redemption row appears.
            await reloadHistoryOnly()
        } catch {
            redeemFlash = .init(kind: .failure,
                                message: error.localizedDescription)
            Haptics.error()
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section {
            if history.isEmpty {
                if loading {
                    HStack { ProgressView(); Text("加载中…") }
                        .foregroundStyle(Theme.Palette.inkMuted)
                } else {
                    Text("还没有账目记录。")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            } else {
                ForEach(history) { item in
                    HistoryRow(item: item)
                }
            }
        } header: {
            Text("最近账目")
        }
    }

    private struct HistoryRow: View {
        let item: BillingService.HistoryItem

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.ink)
                    if let sub = subtitle {
                        Text(sub)
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer(minLength: 8)
                Text(amountText)
                    .font(Theme.Fonts.body)
                    .monospacedDigit()
                    .foregroundStyle(item.deltaCredits >= 0
                                     ? Color(hex: 0x2E7D5B)
                                     : Theme.Palette.ink)
            }
            .padding(.vertical, 2)
        }

        private var title: String {
            switch item.kind {
            case .consume:
                return item.modelId ?? item.taskType ?? "调用"
            case .movement:
                switch item.entryType {
                case "redemption":   return "兑换码"
                case "grant":        return "管理员发放"
                case "signup_bonus": return "注册奖励"
                case "topup":        return "充值"
                case "refund":       return "退款"
                case "adjust":       return "调整"
                default:             return item.entryType ?? "账目"
                }
            }
        }

        private var subtitle: String? {
            let date = ServerTimestamp.parse(item.createdAt).map(formatDate) ?? ""
            switch item.kind {
            case .consume:
                let task = item.taskType ?? ""
                let unbilled = item.billingStatus == "unbilled" ? " · 欠费" : ""
                let parts = [task, date].filter { !$0.isEmpty }
                return parts.joined(separator: " · ") + unbilled
            case .movement:
                if let r = item.reason, !r.isEmpty {
                    return [r, date].filter { !$0.isEmpty }.joined(separator: " · ")
                }
                return date.isEmpty ? nil : date
            }
        }

        private var amountText: String {
            let v = item.deltaCredits
            let sign = v > 0 ? "+" : (v < 0 ? "-" : "")
            return "\(sign)\(formatPnd(abs(v)))"
        }

        private func formatDate(_ d: Date) -> String {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: d)
        }
    }

    // MARK: - Reload

    private func reload() async {
        loading = true
        defer { loading = false }
        async let bal: BillingService.Balance? = try? BillingService.fetchBalance()
        async let hist: [BillingService.HistoryItem] = (try? BillingService.fetchHistory(limit: 50)) ?? []
        let (b, h) = await (bal, hist)
        balance = b ?? balance
        history = h
        loadError = (b == nil) ? "加载余额失败，下拉重试。" : nil
    }

    private func reloadHistoryOnly() async {
        if let h = try? await BillingService.fetchHistory(limit: 50) {
            history = h
        }
    }

}

/// File-scope helper so both `WalletView` and its nested `HistoryRow`
/// can format PND counts without crossing instance boundaries.
private func formatPnd(_ n: Int) -> String {
    pndFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

private let pndFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    f.maximumFractionDigits = 0
    return f
}()
