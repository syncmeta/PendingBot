import SwiftUI

/// 钱包 — PND 余额、兑换码、消费日志。Pull-to-refresh 重拉余额 +
/// log。统计图表/聚合先去掉了，详细的逐条调用列表直接在这里看。
struct WalletView: View {
    @State private var balance: BillingService.Balance?
    @State private var loading = false
    @State private var loadError: String?

    @State private var logItems: [BillingService.LogEntry] = []
    @State private var logCursor: String?
    @State private var logLoadingMore = false
    @State private var logExhausted = false

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
            logSection
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
                    Text(formatPnd(balance?.balanceCredits ?? 0))
                        .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .monospacedDigit()
                    Text("PND")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if let b = balance, b.minThreshold > 0, b.balanceCredits < b.minThreshold {
                    Label("余额已低于阈值 \(formatPnd(b.minThreshold)) PND，下次发消息可能被拒。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Color(hex: 0xB14B3C))
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
                Text("PND: Pending Name Credit")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
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

    // MARK: - Log (per-call list)

    @ViewBuilder
    private var logSection: some View {
        Section {
            if loading && logItems.isEmpty {
                HStack { ProgressView(); Text("加载中…") }
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            } else if logItems.isEmpty {
                Text("还没有消费记录。")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            } else {
                ForEach(logItems) { entry in
                    logRow(entry)
                        .listRowBackground(Theme.Palette.surface)
                }
                if !logExhausted {
                    HStack {
                        Spacer()
                        if logLoadingMore {
                            ProgressView()
                        } else {
                            Button("加载更多") {
                                Task { await loadMore() }
                            }
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                        }
                        Spacer()
                    }
                    .listRowBackground(Theme.Palette.surface)
                }
            }
        } header: {
            Text("消费日志")
        }
    }

    @ViewBuilder
    private func logRow(_ entry: BillingService.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.categoryLabel ?? Self.taskLabel(entry.taskType))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                if let botName = entry.botName, !botName.isEmpty {
                    Text("· \(botName)")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text("-\(formatPnd(entry.costCredits))")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(Self.formatTime(entry.createdAt))
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
                if !entry.modelId.isEmpty {
                    Text("· \(entry.modelId)")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Human label for an audit task_type; falls back to the raw value.
    private static func taskLabel(_ key: String) -> String {
        switch key {
        case "message_reply": return "聊天回复"
        case "group_router":  return "群聊路由"
        case "title":         return "起标题"
        case "voice_call":    return "语音通话"
        case "envelope",
             "scroll":        return "来信"
        case "chat_memo":     return "聊天备忘"
        case "bot_note":      return "机器人笔记"
        default:              return key
        }
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

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func formatTime(_ iso: String) -> String {
        let date = isoParser.date(from: iso)
            ?? isoParserNoFrac.date(from: iso)
        guard let date else { return iso }
        return displayFormatter.string(from: date)
    }

    // MARK: - Reload

    private func reload() async {
        loading = true
        defer { loading = false }
        async let bal: BillingService.Balance? = try? BillingService.fetchBalance()
        async let page: BillingService.LogPage? = try? BillingService.fetchLog()
        let (b, p) = await (bal, page)
        balance = b ?? balance
        if let p {
            logItems = p.items
            logCursor = p.nextCursor
            logExhausted = p.nextCursor == nil
        }
        loadError = (b == nil) ? "加载余额失败，下拉重试。" : nil
    }

    private func loadMore() async {
        guard let cursor = logCursor, !logLoadingMore else { return }
        logLoadingMore = true
        defer { logLoadingMore = false }
        guard let p = try? await BillingService.fetchLog(before: cursor) else { return }
        logItems.append(contentsOf: p.items)
        logCursor = p.nextCursor
        logExhausted = p.nextCursor == nil
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
