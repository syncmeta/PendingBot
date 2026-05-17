import SwiftUI
import Charts

/// 钱包 — PND 余额、兑换码、消费审计图表。Pull-to-refresh 重拉余额 +
/// summary 两个端点。详细的逐条调用日志不再在客户端展示（迁到了 board
/// 的 /audit 页），这里只看「在哪个机器人 / 任务 / 模型上、哪天花了多少」。
struct WalletView: View {
    @State private var balance: BillingService.Balance?
    @State private var summary: BillingService.Summary?
    @State private var range: BillingService.SummaryRange = .month
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
            spendSection
            breakdownSection(title: "按机器人", rows: botRows, emptyHint: "还没有机器人消费")
            breakdownSection(title: "按任务", rows: taskRows, emptyHint: "还没有任务消费")
            breakdownSection(title: "按模型", rows: modelRows, emptyHint: "还没有模型消费")
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
        } catch {
            redeemFlash = .init(kind: .failure,
                                message: error.localizedDescription)
            Haptics.error()
        }
    }

    // MARK: - Spend (daily chart)

    @ViewBuilder
    private var spendSection: some View {
        Section {
            Picker("时间范围", selection: $range) {
                ForEach(BillingService.SummaryRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: range) { Task { await reloadSummary() } }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatPnd(summary?.totalCredits ?? 0))
                        .font(Theme.Fonts.serif(size: 28, weight: .bold))
                        .foregroundStyle(Theme.Palette.ink)
                        .monospacedDigit()
                    Text("PND · 近 \(summary?.rangeDays ?? range.days) 天")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if loading && summary == nil {
                    HStack { ProgressView(); Text("加载中…") }
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                } else if dailyPoints.isEmpty {
                    Text("这段时间还没有消费。")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                } else {
                    Chart(dailyPoints) { p in
                        BarMark(
                            x: .value("日期", p.date, unit: .day),
                            y: .value("PND", p.credits)
                        )
                        .foregroundStyle(Theme.Palette.ink)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 7)) {
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .frame(height: 140)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.Palette.surface)
        } header: {
            Text("消费趋势")
        }
    }

    // MARK: - Breakdown (by bot / task / model)

    private struct BreakdownRow: Identifiable {
        let id: String
        let label: String
        let credits: Int
    }

    @ViewBuilder
    private func breakdownSection(
        title: String,
        rows: [BreakdownRow],
        emptyHint: String
    ) -> some View {
        Section {
            if rows.isEmpty {
                Text(emptyHint)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("PND", row.credits),
                        y: .value("项", row.label)
                    )
                    .foregroundStyle(Theme.Palette.ink)
                    .annotation(position: .trailing) {
                        Text(formatPnd(row.credits))
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading) { _ in
                        AxisValueLabel()
                    }
                }
                .frame(height: CGFloat(rows.count) * 34 + 12)
                .padding(.vertical, 4)
                .listRowBackground(Theme.Palette.surface)
            }
        } header: {
            Text(title)
        }
    }

    // MARK: - Derived data

    private struct DailyPoint: Identifiable {
        let id: String
        let date: Date
        let credits: Int
    }

    private var dailyPoints: [DailyPoint] {
        (summary?.byDay ?? []).compactMap { p in
            guard let date = Self.dayFormatter.date(from: p.day) else { return nil }
            return DailyPoint(id: p.day, date: date, credits: p.credits)
        }
    }

    private var botRows: [BreakdownRow] {
        (summary?.byBot ?? []).prefix(8).map {
            BreakdownRow(id: $0.key, label: $0.label, credits: $0.credits)
        }
    }

    private var taskRows: [BreakdownRow] {
        (summary?.byTask ?? []).prefix(8).map {
            BreakdownRow(id: $0.key, label: Self.taskLabel($0.key), credits: $0.credits)
        }
    }

    private var modelRows: [BreakdownRow] {
        (summary?.byModel ?? []).prefix(8).map {
            BreakdownRow(id: $0.key, label: $0.key, credits: $0.credits)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Human label for an audit task_type; falls back to the raw value.
    private static func taskLabel(_ key: String) -> String {
        switch key {
        case "message_reply": return "聊天回复"
        case "group_router":  return "群聊路由"
        case "title":         return "起标题"
        case "voice_call":    return "语音通话"
        case "scroll":        return "Scroll"
        case "chat_memo":     return "聊天备忘"
        case "bot_note":      return "机器人笔记"
        default:              return key
        }
    }

    // MARK: - Reload

    private func reload() async {
        loading = true
        defer { loading = false }
        async let bal: BillingService.Balance? = try? BillingService.fetchBalance()
        async let sum: BillingService.Summary? = try? BillingService.fetchSummary(range: range)
        let (b, s) = await (bal, sum)
        balance = b ?? balance
        summary = s ?? summary
        loadError = (b == nil) ? "加载余额失败，下拉重试。" : nil
    }

    private func reloadSummary() async {
        if let s = try? await BillingService.fetchSummary(range: range) {
            summary = s
        }
    }
}

private extension BillingService.SummaryRange {
    /// Day count, used only as a pre-fetch placeholder before the
    /// server echoes `range_days` back.
    var days: Int {
        switch self {
        case .week:    return 7
        case .month:   return 30
        case .quarter: return 90
        }
    }
}

/// File-scope helper so `WalletView` and its nested views can format
/// PND counts without crossing instance boundaries.
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
