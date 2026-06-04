#if os(macOS)
import SwiftUI

/// Mac 端"我" tab — T0.1 第一个真实接入业务数据的 Mac 视图。
///
/// 直接消费 `AccountStore`(已是 Mac-compatible: 纯 Foundation + Combine
/// + supabase-swift,Storage 整目录不动)。当前展示:
///   - 头像区(简化 — Mac 端还没接 UserAvatar / BotAvatar,先 monogram)
///   - 显示名(profileDisplayName 优先,退化到 Account.displayName)
///   - 邮箱
///   - Account ID(便于诊断)
///   - 退出登录按钮(走 AccountStore.signOut())
///
/// iOS 上的 MeTabView 同时承载注销账号 / 钱包 / 设置入口 — 那些都还依赖
/// 整套 iOS 业务栈(BillingService 走 UIKit 上的 Apple Pay sheet、
/// SettingsView 一堆 UIPasteboard 等),Mac 接入留给 T0.1 P1+。
struct MacMeView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var signingOut = false

    // 钱包概览(余额 + 阈值提示) + 明细 sheet。数据走跨平台 BillingService。
    @State private var wallet: BillingService.WalletV2?
    @State private var walletLoading = false
    @State private var walletShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let account = store.current {
                    header(account: account)
                    Divider()
                    walletSection
                    Divider()
                    infoSection(account: account)
                    Divider()
                    actions(account: account)
                } else {
                    notSignedIn
                }
            }
            .padding(40)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await loadWallet() }
        .sheet(isPresented: $walletShown) { MacWalletView() }
    }

    private func header(account: Account) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 72, height: 72)
                Text(monogram(for: displayName(account)))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName(account))
                    .font(.system(size: 22, weight: .semibold))
                if let email = account.email, !email.isEmpty {
                    Text(email)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Wallet

    private var walletSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("钱包")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("钱包明细") { walletShown = true }
                    .buttonStyle(.link)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(WalletV2Format.formatPnc(wallet?.totalPncMicros ?? 0))
                    .font(Theme.Fonts.serif(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .monospacedDigit()
                    .redacted(reason: (wallet == nil && walletLoading) ? .placeholder : [])
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
    }

    private func loadWallet() async {
        walletLoading = true
        defer { walletLoading = false }
        wallet = try? await BillingService.fetchWalletV2()
    }

    private func infoSection(account: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账号信息")
                .font(.headline)
                .foregroundStyle(.secondary)
            row("用户 ID", account.id)
            row("Worker", account.workerURL.absoluteString)
            if let seed = store.avatarSeed, !seed.isEmpty {
                row("头像 seed", seed)
            }
        }
    }

    private func actions(account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                Task {
                    signingOut = true
                    defer { signingOut = false }
                    await store.signOut()
                }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(signingOut)
            .buttonStyle(.borderedProminent)

            Text("v\(appVersion) (\(appBuild))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
    }

    private var notSignedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("未登录")
                .font(.system(size: 22, weight: .semibold))
            Text("Mac 端的登录入口还在路上。请先在 iOS 上登录,Mac 端通过同一 Supabase session 同步进入。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func displayName(_ account: Account) -> String {
        store.profileDisplayName?.isEmpty == false
            ? store.profileDisplayName!
            : account.displayName
    }

    private func monogram(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
#endif
