#if os(macOS)
import SwiftUI

/// Mac 端"我" tab — T0.1 第一个真实接入业务数据的 Mac 视图。
///
/// 直接消费 `AccountStore`(已是 Mac-compatible: 纯 Foundation + Combine
/// + supabase-swift,Storage 整目录不动)。当前展示:
///   - 头像区(ServerImage 上传头像优先,退化到确定性 BrandAvatar(seed:))
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

    // 设置 / 资料编辑 sheet(MeView 在 NavigationSplitView 的 detail 里,
    // NavigationLink push 不稳,统一用 sheet)。
    @State private var settingsShown = false
    @State private var profileEditShown = false

    // 注销账号(确认 + request_account_deletion RPC)。
    @State private var deleteConfirmShown = false
    @State private var deleting = false
    @State private var error: String?

    /// Two-way sentiment captured when requesting account deletion. Mirror of
    /// iOS `MeTabView.DeletionSentiment` — same outcome (pending-deletion
    /// tombstone), recorded so we know how people feel when they leave.
    enum DeletionSentiment: String {
        case seeYouAgain     = "see_you_again"     // 有缘再见
        case farewellForever = "farewell_forever"  // 再也不见
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let account = store.current {
                    header(account: account)
                    Divider()
                    walletSection
                    Divider()
                    settingsSection
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
        .background(Theme.Palette.canvas)
        .task { await loadWallet() }
        .sheet(isPresented: $walletShown) { MacWalletView() }
        .sheet(isPresented: $settingsShown) { MacSettingsView() }
        .sheet(isPresented: $profileEditShown) {
            MacProfileEditView().environmentObject(store)
        }
        .alert("出错", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(
            "确定注销账号？",
            isPresented: $deleteConfirmShown,
            titleVisibility: .visible
        ) {
            Button("去意已决，有缘再见", role: .destructive) {
                Task { await deleteAccount(sentiment: .seeYouAgain) }
            }
            Button("去意已决，再也不见", role: .destructive) {
                Task { await deleteAccount(sentiment: .farewellForever) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("若去意已决，28天后将会删除你在这个应用里的所有数据，期间在任意设备登录可恢复账号\n两个选项触发同一个流程，我只是想知道你的态度")
        }
    }

    /// Avatar mirrors `MacContactAvatar`: uploaded image when set, else the
    /// deterministic `BrandAvatar(seed:)`. Whole row taps into 资料编辑.
    private func header(account: Account) -> some View {
        Button {
            profileEditShown = true
        } label: {
            HStack(spacing: 16) {
                let seed = store.avatarSeed?.isEmpty == false ? store.avatarSeed! : account.id
                if let aid = store.avatarAttachmentId, !aid.isEmpty {
                    ServerImage(path: aid,
                                serverURL: HostedConfig.environment.workerURL,
                                contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                } else {
                    BrandAvatar(seed: seed, size: 72)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName(account))
                        .font(Theme.Fonts.serif(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    if let email = account.email, !email.isEmpty {
                        Text(email)
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.glyph(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                settingsShown = true
            } label: {
                HStack(spacing: 8) {
                    Text("设置")
                        .font(Theme.Fonts.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Theme.Fonts.glyph(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.55))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Wallet

    private var walletSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("钱包")
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer()
                Button("钱包明细") { walletShown = true }
                    .buttonStyle(.link)
                    .tint(Theme.Palette.accent)
                    .font(Theme.Fonts.footnote)
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
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Palette.ink)
            row("用户 ID", account.id)
            row("Worker", account.workerURL.absoluteString)
            if let seed = store.avatarSeed, !seed.isEmpty {
                row("头像 seed", seed)
            }
        }
    }

    private func actions(account: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Button(role: .destructive) {
                deleteConfirmShown = true
            } label: {
                Label(deleting ? "提交中…" : "注销账号", systemImage: "trash")
            }
            .disabled(deleting)
            .buttonStyle(.link)
            .tint(Color(hex: 0xB14B3C))

            Text("v\(appVersion) (\(appBuild))")
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.top, 16)
        }
    }

    private func deleteAccount(sentiment: DeletionSentiment) async {
        guard !deleting else { return }
        deleting = true; defer { deleting = false }
        do {
            struct Args: Encodable { let p_sentiment: String }
            try await SupabaseStack.shared
                .rpc("request_account_deletion",
                     params: Args(p_sentiment: sentiment.rawValue))
                .execute()
            await store.signOut()
        } catch {
            self.error = "注销失败：\(error.localizedDescription)"
        }
    }

    private var notSignedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("未登录")
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Mac 端的登录入口还在路上。请先在 iOS 上登录,Mac 端通过同一 Supabase session 同步进入。")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func displayName(_ account: Account) -> String {
        store.profileDisplayName?.isEmpty == false
            ? store.profileDisplayName!
            : account.displayName
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
#endif
