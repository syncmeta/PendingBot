import SwiftUI

/// 钱包 v2 — PNC 余额 + 包列表（像运营商流量包）+ 近期账本。
/// 读 `/v1/me/wallet/v2`。dual-write 阶段与旧 WalletView 并存；cutover
/// 后成为主钱包页。设计见 docs/billing-v2-design.md §8。
struct WalletV2View: View {
    @State private var wallet: BillingService.WalletV2?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showPurchase = false

    var body: some View {
        List {
            balanceSection
            rechargeSection
            if let w = wallet, !w.packs.isEmpty {
                packsSection(w.packs)
            }
            if let w = wallet, !w.recentLedger.isEmpty {
                ledgerSection(w.recentLedger)
            }
        }
        .platformListStyle()
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("钱包")
        .inlineNavTitle()
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(isPresented: $showPurchase) {
            // 购买成功后刷新余额(webhook 到账有几秒延迟,故成功回调 + 关闭时都刷)。
            PurchaseSheet(onPurchased: { Task { await reload() } })
        }
        .onChange(of: showPurchase) { _, isShown in
            if !isShown { Task { await reload() } }
        }
    }

    // MARK: - Recharge

    @ViewBuilder
    private var rechargeSection: some View {
        Section {
            Button {
                showPurchase = true
            } label: {
                Label("充值 PNC", systemImage: "plus.circle.fill")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .listRowBackground(Theme.Palette.surface)
        }
    }

    // MARK: - Balance

    @ViewBuilder
    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(WalletV2Format.formatPnc(wallet?.totalPncMicros ?? 0))
                        .font(Theme.Fonts.serif(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .monospacedDigit()
                    Text("PNC")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if let state = wallet?.thresholdState, let notice = WalletV2Format.thresholdNotice(state) {
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
                    .foregroundStyle(Theme.Palette.danger)
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
                Text(WalletV2Format.channelLabel(pack.salesChannel))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer()
                Text("\(WalletV2Format.formatPnc(pack.remainingPncMicros)) / \(WalletV2Format.formatPnc(pack.initialPncMicros))")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.ink)
                    .monospacedDigit()
            }
            if let expiry = WalletV2Format.expiryNotice(pack.expiresAt) {
                Text(expiry.text)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(expiry.urgent ? Theme.Palette.danger : Theme.Palette.inkMuted)
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
                Text(WalletV2Format.entryLabel(entry.entryType))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                Text(WalletV2Format.formatTime(entry.createdAt))
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer()
            Text("\(entry.deltaPncMicros > 0 ? "+" : "")\(WalletV2Format.formatPnc(entry.deltaPncMicros))")
                .font(Theme.Fonts.body)
                .foregroundStyle(entry.deltaPncMicros > 0 ? Theme.Palette.success : Theme.Palette.ink)
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
}
