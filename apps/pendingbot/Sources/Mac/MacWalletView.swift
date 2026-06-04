#if os(macOS)
import SwiftUI

/// macOS 个人钱包 — 原生重画对齐 iOS `WalletV2View`(PNC 余额 + 充值包 + 近期
/// 账本)。数据走跨平台 `BillingService.fetchWalletV2()`,格式化/标签走共享
/// `WalletV2Format`,设计 token 走共享 `Theme` —— 与 iOS 完全同源,只是渲染层
/// 用 macOS 原生 List(`.inset`)。作为 sheet 从 `MacMeView` 弹出。
///
/// 只读展示:充值动作(Apple Pay / 网页)是单独入口,不在这页(与 iOS 一致)。
struct MacWalletView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var wallet: BillingService.WalletV2?
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                balanceSection
                if let w = wallet, !w.packs.isEmpty {
                    packsSection(w.packs)
                }
                if let w = wallet, !w.recentLedger.isEmpty {
                    ledgerSection(w.recentLedger)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("钱包")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .help("刷新")
                }
            }
            .task { await reload() }
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    // MARK: - Balance

    @ViewBuilder
    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(WalletV2Format.formatPnc(wallet?.totalPncMicros ?? 0))
                        .font(Theme.Fonts.serif(size: 26, weight: .semibold))
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
            loadError = "加载钱包失败，点右上刷新重试。"
        }
    }
}
#endif
