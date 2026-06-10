import SwiftUI

/// 我 — left-aligned header column (avatar / name / email, no card
/// background) plus a native-style settings list. Tapping the header
/// pushes into `ProfileBootstrapView` (the random-roll 头像 / 用户名
/// 生成 page) so avatar + nickname share one editing surface.
///
/// 跨平台:iOS 渲染 compact / iPad-landscape 两套;macOS 走 `FeatureSurface`
/// 的「无列表型」装配(壳把整页放右栏,中列空态)。iOS-only 的部分(头像
/// 重roll → `ProfileBootstrapView`,依赖 PhotosUI;「设置」原地 push)用
/// `#if os(iOS)` 围起;macOS 上头像不可点、「设置」改成打开 ⌘, 独立窗口。
struct MeTabView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var pendingConfirm: ConfirmAction?
    @State private var deleting = false
    @State private var error: String?
    @State private var showRandomize = false

    /// Two `.confirmationDialog`s attached to the same view collide on
    /// SwiftUI — one gets shadowed and its `isPresented` flag flips
    /// without the sheet ever appearing (most visible on Mac Catalyst).
    /// Drive a single dialog off this enum instead.
    private enum ConfirmAction: Identifiable {
        case signOut, delete
        var id: Self { self }
    }

    /// Two-way sentiment captured when requesting account deletion. The
    /// outcome is the same — pending-deletion tombstone, finalized 28
    /// days later — but recording which button the user picked tells us
    /// how people feel when they leave.
    enum DeletionSentiment: String {
        case seeYouAgain     = "see_you_again"     // "有缘再见"
        case farewellForever = "farewell_forever"  // "再也不见"
    }

    var body: some View {
        chrome(
            Group {
                if sidebarLayout {
                    NavigationSplitView {
                        VStack(spacing: 0) {
                            coreContent
                            if let topTabSelection {
                                SidebarTabBar(selection: topTabSelection)
                            }
                        }
                        .sidebarColumnWidth()
                    } detail: {
                        EmptyDetailHint(text: "在左侧选项里走走", systemImage: "person.crop.circle")
                    }
                } else {
                    coreContent
                }
            }
        )
    }

    /// Wraps a root view with the tab's shared chrome — the reroll cover
    /// (iOS-only), the error alert, and the sign-out / delete-account
    /// confirmation dialog. Pulled out of `body` so the Mac shell's
    /// `detailColumn` and the `compactRoot` can each be self-contained:
    /// both entry points carry the same actions, regardless of which
    /// SwiftUI container hosts them. The iOS `body` calls this with the
    /// exact same content it used to inline, so its behavior is unchanged.
    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        content
            // 头像/昵称重roll 页(ProfileBootstrapView)是 iOS-only(PhotosUI +
            // 横向分页),Mac 端没有该编辑面 —— cover 整体 iOS 限定。
            #if os(iOS)
            .fullScreenCover(isPresented: $showRandomize) {
                ProfileBootstrapView(allowsBack: true)
                    .environmentObject(AccountStore.shared)
            }
            #endif
            .alert("出错", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .confirmationDialog(
                confirmTitle,
                isPresented: Binding(
                    get: { pendingConfirm != nil },
                    set: { if !$0 { pendingConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                switch pendingConfirm {
                case .signOut:
                    Button("退出登录", role: .destructive) { signOut() }
                    Button("取消", role: .cancel) {}
                case .delete:
                    Button("去意已决，有缘再见", role: .destructive) {
                        Task { await deleteAccount(sentiment: .seeYouAgain) }
                    }
                    Button("去意已决，再也不见", role: .destructive) {
                        Task { await deleteAccount(sentiment: .farewellForever) }
                    }
                    Button("取消", role: .cancel) {}
                case .none:
                    EmptyView()
                }
            } message: {
                if pendingConfirm == .delete {
                    Text("若去意已决，28天后将会删除你在这个应用里的所有数据，期间在任意设备登录可恢复账号\n两个选项触发同一个流程，我只是想知道你的态度")
                }
            }
    }

    private var confirmTitle: String {
        switch pendingConfirm {
        case .signOut: return "确定？"
        case .delete:  return "确定注销账号？"
        case .none:    return ""
        }
    }

    @ViewBuilder
    private var coreContent: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        profileHeader
                            .contentShape(Rectangle())
                            // 点头像进重roll 页 —— iOS-only(ProfileBootstrapView
                            // 是 iOS 限定);macOS 上头像是纯展示,不可点。
                            #if os(iOS)
                            .onTapGesture {
                                showRandomize = true
                                Haptics.tap()
                            }
                            #endif

                        VStack(spacing: 0) {
                            NavigationLink {
                                AddMeMethodsView().platformTabBarVisibility(false)
                            } label: {
                                OptionRow(title: "加我为好友的方式")
                            }
                            .buttonStyle(.plain)

                            optionDivider

                            NavigationLink {
                                WalletV2View().platformTabBarVisibility(false)
                            } label: {
                                OptionRow(title: "钱包")
                            }
                            .buttonStyle(.plain)

                            optionDivider

                            NavigationLink {
                                BotCapabilitiesView().platformTabBarVisibility(false)
                            } label: {
                                OptionRow(title: "机器人能力扩展")
                            }
                            .buttonStyle(.plain)

                            optionDivider

                            NavigationLink {
                                ArenaLeaderboardView().platformTabBarVisibility(false)
                            } label: {
                                OptionRow(title: "猜你喜欢")
                            }
                            .buttonStyle(.plain)

                            optionDivider

                            // 设置入口:iOS 原地 push 共享 `SettingsView`;macOS 用
                            // `SettingsLink` 打开原生 ⌘, 独立设置窗口(D4:两端指向
                            // 同一份设置内容,Mac 走系统 Settings 场景)。
                            settingsEntry
                        }
                        .meGlassGroup()

                        VStack(spacing: 0) {
                            Button {
                                pendingConfirm = .signOut
                                Haptics.tap()
                            } label: {
                                OptionRow(title: "退出登录", role: .destructive, showsChevron: false)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.current == nil)

                            optionDivider

                            Button {
                                pendingConfirm = .delete
                                Haptics.tap()
                            } label: {
                                OptionRow(
                                    title: deleting ? "提交中…" : "注销账号",
                                    role: .destructive,
                                    showsChevron: false
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(deleting || store.current == nil)
                        }
                        .meGlassGroup()

                        Text("很多功能还没做好 不可用")
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 72)
                    .padding(.bottom, 32)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
    }

    /// 设置入口。iOS 是 `NavigationLink` 原地 push 共享 `SettingsView`;
    /// macOS 用 `SettingsLink`(macOS 14+)打开原生 ⌘, 独立设置窗口 ——
    /// 该窗口由 App 的 `Settings` 场景托管,内容同样是共享 `SettingsView`,
    /// 所以两端落到同一份设置内容(D4)。
    @ViewBuilder
    private var settingsEntry: some View {
        #if os(iOS)
        NavigationLink {
            SettingsView().platformTabBarVisibility(false)
        } label: {
            OptionRow(title: "设置")
        }
        .buttonStyle(.plain)
        #else
        SettingsLink {
            OptionRow(title: "设置")
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        #endif
    }

    /// Hairline separating two rows inside one glass group, inset to
    /// align with the row text.
    private var optionDivider: some View {
        Rectangle()
            .fill(Theme.Palette.inkMuted.opacity(0.18))
            .frame(height: 0.5)
            .padding(.leading, 20)
    }

    // ── Header ─────────────────────────────────────────────────────────────

    /// Avatar / nickname / email stacked vertically, centered on the
    /// canvas (no surface card). The whole column is one tap target
    /// → ProfileBootstrapView.
    private var profileHeader: some View {
        VStack(spacing: 16) {
            let seed = store.avatarSeed ?? store.current?.id ?? "?"
            UserAvatar(
                seed: seed,
                attachmentId: store.avatarAttachmentId,
                size: 88
            )
            .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 7)
            VStack(spacing: 6) {
                Text(displayLabel)
                    .font(Theme.Fonts.serif(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let email = store.current?.email, !email.isEmpty {
                    Text(email)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var displayLabel: String {
        let ws = CharacterSet.whitespacesAndNewlines
        if let stored = store.profileDisplayName?.trimmingCharacters(in: ws),
           !stored.isEmpty {
            return stored
        }
        if let dn = store.current?.displayName.trimmingCharacters(in: ws),
           !dn.isEmpty {
            return dn
        }
        return "未命名"
    }

    // ── Actions ────────────────────────────────────────────────────────────

    private func signOut() {
        Task {
            await store.signOut()
            Haptics.success()
        }
    }

    private func deleteAccount(sentiment: DeletionSentiment) async {
        guard !deleting else { return }
        deleting = true; defer { deleting = false }
        do {
            struct Body: Encodable { let sentiment: String }
            try await APIClient().postVoid("v1/me/account-deletion",
                                           body: Body(sentiment: sentiment.rawValue))
            await store.signOut()
            Haptics.success()
        } catch {
            self.error = "注销失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}

// MARK: - FeatureSurface (Mac three-column shell)

/// 「我」是 FeatureSurface 的「无列表型」装配:没有可枚举的 list 内容,
/// 它本身就是一个自包含的设置/账号菜单(NavigationStack 内 push 子页)。
/// 映射(对齐 FeatureSurface.swift 的「无列表型」约定 + 已删的 `MacMeView`
/// 在 detail 列的位置):
///   • `detailColumn` 承载真正的 `MeTabView` 菜单内容(壳的右栏);
///     中列由壳给空态/入口,与「我没有 list」一致。
///   • `listColumn` 给最小占位(协议要求该方法存在;壳实际中列用自己的
///     `WidePlaceholderColumn`,不一定调它)。
///   • `compactRoot` = 同一份菜单内容,自包含(带 chrome)。
/// Selection 用占位 `String`(无实际选中语义),仅为满足
/// `associatedtype Selection: Hashable`。iOS `body` 不受影响,这些方法
/// 是 additive、只有 Mac 壳会调。
extension MeTabView: FeatureSurface {
    typealias Selection = String

    func listColumn(selection: Binding<String?>) -> some View {
        // 「我」没有可枚举 list —— 给一个最小空态占位(壳的中列通常用它
        // 自己的 `WidePlaceholderColumn`,这里只为满足协议)。
        EmptyDetailHint(text: "账号与设置在右侧", systemImage: "person.crop.circle")
    }

    func detailColumn(selection: String?) -> some View {
        // 右栏 = 自包含的「我」菜单(NavigationStack 内 push 子页),带上
        // 与 iOS `body` 同款的 chrome(错误 alert + 退出/注销确认 + iOS-only
        // reroll cover),所以退出登录 / 注销账号从这一列照常工作。
        chrome(coreContent)
    }

    func compactRoot() -> some View {
        // compact 入口同样是自包含菜单 + chrome。Mac 壳当前不走 compact,
        // 但保持与 iOS 行为一致、可编译。
        chrome(coreContent)
    }
}

/// One option row — no background of its own; it lives inside a
/// `meGlassGroup()` container so several rows read as one connected card.
struct OptionRow: View {
    enum Role { case normal, destructive }

    let title: String
    var role: Role = .normal
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Fonts.system(size: 15, weight: .medium))
                .foregroundStyle(role == .destructive
                                 ? Color(hex: 0xB14B3C)
                                 : Theme.Palette.ink)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.glyph(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.55))
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

/// Solid white background for a whole group of option rows — a single
/// rounded rectangle so the rows inside read as one connected card.
/// Thin gray hairline + a soft outer shadow lift it off the canvas.
extension View {
    func meGlassGroup() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .background(shape.fill(Color.white))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 1.5)
    }
}

// MARK: - 模型竞技场榜单

/// Personal model leaderboard — Elo standings replayed from the user's own
/// blind A/B votes (GET /v1/arena/leaderboard). Pure read view.
struct ArenaLeaderboardView: View {
    @Environment(\.api) private var api
    @EnvironmentObject private var catalog: ModelCatalog

    @State private var standings: [ArenaStanding] = []
    @State private var total: Int = 0
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            if loading && standings.isEmpty {
                ProgressView().tint(Theme.Palette.accent)
            } else if standings.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(Array(standings.enumerated()), id: \.element.id) { item in
                            row(rank: item.offset + 1, s: item.element)
                        }
                    } footer: {
                        Text("基于你的 \(total) 次盲评,用 Elo 排名。把机器人主模型设成竞技场(选 2 个以上模型)、对回答再生成、然后投票,榜单会越来越准。")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    .listRowBackground(Theme.Palette.surface)
                }
                .platformListStyle()
                .scrollContentBackground(.hidden)
                .background(Theme.Palette.canvas)
                .refreshable { await load() }
            }
        }
        .navigationTitle("猜你喜欢")
        .inlineNavTitle()
        .task { await load() }
    }

    private func row(rank: Int, s: ArenaStanding) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(Theme.Fonts.rounded(size: 15, weight: .bold))
                .foregroundStyle(rank <= 3 ? Theme.Palette.accent : Theme.Palette.inkMuted)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.displayName(for: s.model_slug))
                    .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text("\(s.wins)胜 \(s.losses)负 \(s.ties)平 · \(s.games) 局")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(s.rating)")
                .font(Theme.Fonts.rounded(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text("还没有评价记录")
                .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
            Text("把机器人主模型设成竞技场(在模型选择里勾选 2 个以上模型),对同一个问题再生成一个回答,然后盲评谁更好——投得越多,这里越能反映你的偏好。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let error {
                Text(error)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    private func load() async {
        guard let api else { return }
        loading = true; defer { loading = false }
        do {
            let board: ArenaLeaderboard = try await api.get("v1/arena/leaderboard")
            standings = board.standings
            total = board.total_comparisons
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
