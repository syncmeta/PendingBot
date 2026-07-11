import SwiftUI

/// 「我」tab 的可选中条目 —— 跟其它 tab 的 `Selection` 同构(`ChatDest` /
/// `PendingPeer`),驱动 iPhone 的 push 路径与 iPad/Mac 右栏的详情选中。
/// 「设置」在 macOS 走 `SettingsLink` 独立窗口、不参与选中,但仍列在此处
/// 让 iOS 端把它当普通可选中行(见 `settingsRow` / `destinationView`)。
enum MeSection: String, Hashable, CaseIterable, Identifiable {
    case addFriendMethods
    case wallet
    case capabilities
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addFriendMethods: return "加我为好友的方式"
        case .wallet:           return "钱包"
        case .capabilities:     return "机器人能力扩展"
        case .settings:         return "设置"
        }
    }
}

/// 我 — left-aligned header column (avatar / name / email, no card
/// background) plus a native-style settings list. Tapping the header
/// pushes into `ProfileBootstrapView` (the random-roll 头像 / 用户名
/// 生成 page) so avatar + nickname share one editing surface.
///
/// 跨平台装配走标准 `FeatureSurface`「列表+详情型」(对齐好友/消息 tab):
///   • iPhone(compact):菜单是落地第一页,点条目 push 对应详情。
///   • iPad/Mac(壳三列):菜单是中间列表列,点条目右栏出详情(中列写
///     selection、右栏读 selection)。
/// 头像重 roll(`ProfileBootstrapView`)两端可用:iOS 全屏 cover、macOS sheet;
/// 「退出登录 / 注销账号」是列表里的动作行(确认弹窗),不进详情列;
/// 「设置」在 macOS 是 `SettingsLink`(开 ⌘, 独立窗口),不占详情列。
struct MeTabView: View {
    @EnvironmentObject private var store: AccountStore

    @State private var pendingConfirm: ConfirmAction?
    @State private var deleting = false
    @State private var error: String?
    @State private var showRandomize = false

    /// iPhone(及任何 standalone 渲染)的 push 路径。点条目 append 一个
    /// `MeSection`,`navigationDestination` 把它渲染成详情。
    @State private var path: [MeSection] = []

    /// 壳中间列表列模式的选中写入口 —— 由 `listColumn(selection:)` 注入。
    /// 非 nil 时点条目写它(壳右栏读同一个 binding 出详情),而不是 push。
    var externalSelection: Binding<MeSection?>? = nil

    /// true = body 渲染「壳中间列表列」(`chrome(menu)`,无 push stack ——
    /// 详情归壳右栏、tab 切换归壳 rail)。默认 false 走 iPhone push body。
    var renderAsMacListColumn = false

    /// Two `.confirmationDialog`s attached to the same view collide on
    /// SwiftUI — one gets shadowed and its `isPresented` flag flips
    /// without the sheet ever appearing (most visible on Mac Catalyst).
    /// Drive a single dialog off this enum instead.
    private enum ConfirmAction: Identifiable {
        case signOut, delete, reset
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
        if renderAsMacListColumn {
            // 壳中间列表列:就是带 chrome 的菜单本身;行点击写 externalSelection,
            // 壳右栏读同一 binding 渲染详情。经 body 渲染(而非在图外对 self 拷贝
            // 求值 chrome(menu))才能让 @EnvironmentObject 正常灌注(见 #294)。
            chrome(menu)
        } else {
            // iPhone(及 standalone):菜单是落地第一页,点条目 push 进详情。
            chrome(compactBody)
        }
    }

    // ── Compact (iPhone) — 列表落地 + push 进详情 ────────────────────────────

    private var compactBody: some View {
        NavigationStack(path: $path) {
            menu
                .navigationDestination(for: MeSection.self) { section in
                    destinationView(for: section)
                        .platformTabBarVisibility(false)
                }
        }
        .platformTabBarVisibility(path.isEmpty)
    }

    /// Wraps a root view with the tab's shared chrome — the reroll surface
    /// (iOS cover / macOS sheet), the error alert, and the sign-out / delete-account
    /// confirmation dialog. Pulled out of `body` so the Mac shell's list
    /// column and the iPhone push root carry the same actions regardless
    /// of which SwiftUI container hosts them.
    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        content
            // 头像/昵称重roll 页(ProfileBootstrapView 已跨平台,Mac onboarding
            // 同款)。呈现容器分平台:iOS 全屏 cover;macOS 没有 fullScreenCover,
            // 走 sheet + 最小尺寸(卡片轮播需要横向空间)。
            #if os(iOS)
            .fullScreenCover(isPresented: $showRandomize) {
                ProfileBootstrapView(allowsBack: true)
                    .environmentObject(AccountStore.shared)
            }
            #else
            .sheet(isPresented: $showRandomize) {
                ProfileBootstrapView(allowsBack: true)
                    .environmentObject(AccountStore.shared)
                    .frame(minWidth: 680, minHeight: 620)
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
                case .reset:
                    if LocalDataReset.sharedLoginPresent {
                        Button("清除(保留与 PendingCrew 共享的登录状态)", role: .destructive) {
                            Task { await LocalDataReset.performReset(accountStore: store, clearSharedLogin: false) }
                        }
                        Button("清除,并清除与 PendingCrew 共享的登录状态", role: .destructive) {
                            Task { await LocalDataReset.performReset(accountStore: store, clearSharedLogin: true) }
                        }
                    } else {
                        Button("清除本机所有数据", role: .destructive) {
                            Task { await LocalDataReset.performReset(accountStore: store, clearSharedLogin: false) }
                        }
                    }
                    Button("取消", role: .cancel) {}
                case .none:
                    EmptyView()
                }
            } message: {
                if pendingConfirm == .delete {
                    Text("若去意已决，28天后将会删除你在这个应用里的所有数据，期间在任意设备登录可恢复账号\n两个选项触发同一个流程，我只是想知道你的态度")
                } else if pendingConfirm == .reset {
                    Text("此操作不可恢复,仅清除本机数据(不会删除你的服务器账号)。")
                }
            }
    }

    private var confirmTitle: String {
        switch pendingConfirm {
        case .signOut: return "确定？"
        case .delete:  return "确定注销账号？"
        case .reset:   return "清除本机所有数据?"
        case .none:    return ""
        }
    }

    // ── Menu (list content shared by compact root + Mac list column) ─────────

    /// 菜单本体:头像头部 + 玻璃分组条目 + 退出/注销动作组。compact 落地与
    /// 壳中间列表列共用同一份内容;两条路径的差异只在「点条目做什么」
    /// (`open(_:)`:push vs 写 selection)。
    @ViewBuilder
    private var menu: some View {
        ZStack {
            // 壳列表列模式(Mac/iPad-regular)不铺 canvas —— 露出合并侧栏的
            // 原生材质,与好友/消息等 tab 一致(见 FriendsTabView 同款 gate)。
            if !renderAsMacListColumn {
                Theme.Palette.canvas.ignoresSafeArea()
            }
            ScrollView {
                VStack(spacing: 28) {
                    profileHeader
                        .contentShape(Rectangle())
                        // 点头像进重roll 页(ProfileBootstrapView 跨平台;
                        // iOS 全屏 cover / macOS sheet,见 chrome())。
                        .onTapGesture {
                            showRandomize = true
                            Haptics.tap()
                        }

                    VStack(spacing: 0) {
                        navRow(.addFriendMethods)
                        optionDivider
                        navRow(.wallet)
                        optionDivider
                        navRow(.capabilities)
                        optionDivider
                        // 设置入口:iOS 当普通可选中行(push / 右栏详情);macOS 用
                        // `SettingsLink` 打开原生 ⌘, 独立设置窗口(D4:两端指向
                        // 同一份设置内容,Mac 走系统 Settings 场景)。
                        settingsRow
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
                            pendingConfirm = .reset
                            Haptics.tap()
                        } label: {
                            OptionRow(title: "清除本机所有数据", role: .destructive, showsChevron: false)
                        }
                        .buttonStyle(.plain)

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
        .background {
            if !renderAsMacListColumn {
                Theme.Palette.canvas.ignoresSafeArea()
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// 一个可导航条目行。点击经 `open(_:)` 分流:壳列表列写 `externalSelection`
    /// (右栏出详情),否则 push 到 `path`(iPhone)。
    @ViewBuilder
    private func navRow(_ section: MeSection) -> some View {
        Button {
            Haptics.tap()
            open(section)
        } label: {
            OptionRow(title: section.title)
        }
        .buttonStyle(.plain)
    }

    /// 设置行的平台分叉:iOS 当普通可选中条目;macOS 用 `SettingsLink`
    /// (macOS 14+)打开原生 ⌘, 独立设置窗口 —— 该窗口由 App 的 `Settings`
    /// 场景托管,内容同样是共享 `SettingsView`,两端落到同一份设置内容(D4)。
    @ViewBuilder
    private var settingsRow: some View {
        #if os(iOS)
        navRow(.settings)
        #else
        SettingsLink {
            OptionRow(title: "设置")
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        #endif
    }

    /// 点条目分流:壳中间列表列(`externalSelection` 非 nil)写 selection,
    /// 由壳右栏渲染详情;否则(iPhone / standalone)push 进 `path`。
    private func open(_ section: MeSection) {
        if let externalSelection {
            externalSelection.wrappedValue = section
        } else {
            path.append(section)
        }
    }

    /// `MeSection` → 详情视图本体(各自带 `.navigationTitle`)。外层
    /// NavigationStack 由调用方提供:compact 走 `navigationDestination`,
    /// 壳右栏在 `detailColumn` 里包一层。
    @ViewBuilder
    private func destinationView(for section: MeSection) -> some View {
        switch section {
        case .addFriendMethods: AddMeMethodsView()
        case .wallet:           WalletV2View()
        case .capabilities:     BotCapabilitiesView()
        case .settings:
            #if os(iOS)
            SettingsView()
            #else
            // macOS 的「设置」走 SettingsLink 独立窗口,selection 不会落到
            // `.settings`,这里只为 switch 穷尽兜个空。
            EmptyView()
            #endif
        }
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
                    // 英文衬线 / 中文无衬线(按串内 CJK 选 design)—— 与消息/好友
                    // 列表标题同款,iOS/Mac 一致;不再用纯 serif(Mac 中文会发"黑")。
                    .font(Theme.Fonts.scriptTitle(displayLabel, size: 24))
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

// MARK: - FeatureSurface (shared three-column shell)

/// 「我」是标准「列表+详情型」装配(对齐 `FriendsTabView` / `MessageTabView`):
///   • `listColumn` = 中间列表列(菜单),点条目写 selection。
///   • `detailColumn` = 右栏,按 selection 渲染对应详情(包一层 NavigationStack,
///     因为各详情自带 `.navigationTitle`、`BotCapabilitiesView` 还要继续 push);
///     无选中 → 空态。
///   • `compactRoot` = iPhone 落地(同 body 的 compact 分支)。
/// Selection = `MeSection`。
extension MeTabView: FeatureSurface {
    typealias Selection = MeSection

    func listColumn(selection: Binding<MeSection?>) -> some View {
        // 返回配置过的 self,经 body(`renderAsMacListColumn` 分支)在图内渲染
        // `chrome(menu)` —— 在图外求值会让 @EnvironmentObject 不灌注(#294)。
        var view = self
        view.externalSelection = selection
        view.renderAsMacListColumn = true
        return view
    }

    func detailColumn(selection: MeSection?) -> some View {
        Group {
            if let section = selection {
                // 包一层 NavigationStack:详情各自带 `.navigationTitle`,
                // `BotCapabilitiesView` 还会继续 push 子页 —— 都要落在右栏自己的
                // 导航栈里。`.id(section)` 保证切条目时是干净实例。
                NavigationStack {
                    destinationView(for: section)
                }
                .id(section)
            } else {
                // 文字去掉,只留图标(与消息/Crew 等 tab 的宽屏右栏空态同款)。
                EmptyDetailHint(systemImage: "person.crop.circle")
            }
        }
    }

    func compactRoot() -> some View {
        chrome(compactBody)
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
                                 ? Theme.Palette.danger
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
            .background(shape.fill(Theme.Palette.surface))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 1.5)
    }
}
