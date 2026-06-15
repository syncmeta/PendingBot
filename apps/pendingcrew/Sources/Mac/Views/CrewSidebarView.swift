#if os(macOS)
import SwiftUI

/// 左栏：crew 列表 + toolbar（新建 / 刷新）。
///
/// MVP 阶段是平铺 list —— DAG 树形 sidebar 留下次（spec v2 §12.1 说明）。
/// `runtimeLocation` 用一个 systemImage + 缩写标签提示用户这是 local /
/// peer / fly。
struct CrewSidebarView: View {
    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var model: AppModel
    @State private var showingCreateSheet = false
    @State private var confirmingSignOut = false
    /// 本机模式下侧栏的可选登录入口（登录 SSO C2）—— 弹 LoginView sheet 扫码。
    @State private var showingLogin = false
    /// 家族 SSO 一键登录的进行中 / 失败态（不静默，用户手动点）。
    @State private var familySSOBusy = false
    @State private var familySSOFailed = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if crewStore.crews.isEmpty {
                        emptyRow
                    } else {
                        // 本地 DAG 折叠树 —— 根 = 无父 crew,子按 parentCrewIds 反推
                        // 嵌套。选中态 / 展开态都在 CrewDAGTreeView 内部处理(不走
                        // List(selection:),因为嵌套自定义行用 List 选择会错位)。
                        CrewDAGTreeView()
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                } header: {
                    Text("Crew")
                }
                // Machines section — 占位提示(v1.1 才接真 Fly machine 列表)。
                // BYOK 模式显示 "登录解锁" prompt;登录模式显示 v1.1 placeholder。
                // 这条目前不可选(没 tag),只展示状态。
                Section {
                    machinesRow
                } header: {
                    Text("Machines")
                }
            }
            .listStyle(.sidebar)
            // 当前身份 + 切换/登出。device grant 是 subject-scoped(spec v2 §4.4),
            // 想换 subject 必须撤掉这台机器的 grant 重新扫码 —— 所以"切换身份"
            // 路径就是签出后再去 LoginView 扫一遍。这里集中放在 sidebar 底部,
            // 让 user 始终能看见"我现在以谁的身份在花钱"。
            identityFooter
        }
        // 完全不设 navigationTitle —— 一旦设了（哪怕空串），SwiftUI 会不停把窗口
        // titleVisibility 设回 .visible，把我们在 WindowChromeConfigurator 里藏标题的
        // 设置顶掉，于是 App 名 "PendingCrew" 又冒回标题栏。不设它，标题由
        // WindowChromeConfigurator 一次性藏死。
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("新建 crew", systemImage: "plus")
                }
                .help("新建 crew")
                Button {
                    Task { await crewStore.refreshList() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新 crew 列表")
                .disabled(crewStore.loadingList)
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateCrewSheet()
        }
        // 只有已登录的 footer 菜单能触发(未登录 footer 是登录入口)——
        // 接合 v2 后没有"退出本机模式"概念,本地 crew 永远在。
        .confirmationDialog(
            "签出当前身份",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("签出", role: .destructive) {
                signOut()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("签出后本机 device grant 立即失效;若需切换到别的身份(本人 / 群账号),签出后重新扫码即可。本机 crew 不受影响。")
        }
        // 本机模式可选登录（登录 SSO C2）：扫码完成后 model.isAuthenticated
        // 翻 true，onChange 自动收 sheet —— LoginView 自身只切 .approved
        // 状态不会 dismiss。
        .sheet(isPresented: $showingLogin) {
            // 右上角给关闭按钮（LoginView 本体是全屏 flow 设计，没有 dismiss）；
            // Esc（cancelAction）同样可关。
            ZStack(alignment: .topTrailing) {
                LoginView()
                Button {
                    showingLogin = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(12)
                .help("关闭")
            }
            .frame(minWidth: 480, minHeight: 560)
        }
        .onChange(of: model.isAuthenticated) { _, authed in
            if authed { showingLogin = false }
        }
        .alert("登录失败", isPresented: $familySSOFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("本机授权凭据可能已失效或网络异常，请改用扫码登录。")
        }
    }

    /// 接合 v2：按 `isAuthenticated`(能力叠加)切两种 placeholder ——
    /// (backend 恒本地,旧 supportsCloudRuntime 已删)。
    /// - 已登录 → "Fly machine — v1.1 上线"(灰显)
    /// - 未登录 → "登录 PendingBot 解锁云端 Fly machine"(灰显 + 锁图标)
    @ViewBuilder
    private var machinesRow: some View {
        if model.isAuthenticated {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fly machine")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("v1.1 上线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("云端 Fly machine")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("登录 PendingBot 解锁")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Sidebar 底部固定条。
    /// - 已登录:显示代表的 subject + ⋯ 菜单(签出/切换身份)。
    /// - 未登录:整行就是一个「登录」入口(用户定调:别堆"本机/七七八八"解释)——
    ///   点开选「用本机 PendingBot 身份登录」(共享组有家族凭据时)或「扫码登录」。
    @ViewBuilder
    private var identityFooter: some View {
        Group {
            if model.isAuthenticated {
                HStack(spacing: 10) {
                    Image(systemName: identityIcon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identityTitle)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(identitySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button {
                            confirmingSignOut = true
                        } label: {
                            Label("签出 / 切换身份", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.medium)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            } else {
                Menu {
                    // 家族 SSO（不静默，登录必须手动点这一下）—— 共享 keychain
                    // 组里有本机 PendingBot 留下的家族凭据才显示。
                    if model.familySSOAvailable {
                        Button {
                            Task {
                                familySSOBusy = true
                                let ok = await model.tryFamilySSO()
                                familySSOBusy = false
                                if !ok { familySSOFailed = true }
                            }
                        } label: {
                            Label("用本机 PendingBot 身份登录", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(familySSOBusy)
                    }
                    Button {
                        showingLogin = true
                    } label: {
                        Label("扫码登录", systemImage: "qrcode")
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text("登录")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // identity 三件套只在已登录 footer 渲染(未登录 footer 是登录菜单,
    // 自带文案)—— 接合 v2 后不再按 mode 分叉。
    private var identityIcon: String {
        crewStore.subjects.first?.kindEnum == .groupAccount
            ? "person.3.fill"
            : "person.crop.circle.fill"
    }

    private var identityTitle: String {
        crewStore.subjects.first?.displayName ?? "已登录"
    }

    private var identitySubtitle: String {
        if let kind = crewStore.subjects.first?.kindEnum {
            return kind == .groupAccount ? "群账号" : "本人账号"
        }
        return "已登录"
    }

    private func signOut() {
        // 接合 v2:签出只是撤掉登录能力叠加,本机 crew / 本机模式不受影响。
        guard model.isAuthenticated else { return }
        model.clearAuth()
        // crewStore.reset() 由 RootView 监听登录态变化自动调,
        // 不在这里重复 wire 以避免双触发顺序歧义。
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if crewStore.loadingList {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…").foregroundStyle(.secondary)
                }
            } else {
                Text("还没有 crew")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("点上面 + 创建第一个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

#endif
