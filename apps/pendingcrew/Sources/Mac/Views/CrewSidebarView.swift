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
    /// 本机模式下侧栏的可选登录入口（登录 SSO C2）—— 弹直接登录 sheet（CrewLoginSheet）。
    @State private var showingLogin = false
    /// 折叠起来的机器分组 id 集合（默认全展开）。
    @State private var collapsedMachineIds: Set<String> = []
    /// 登录账号头像 seed —— 在 footer `.task` 里从家族凭据(共享 keychain)解析一次,
    /// 不在 render 路径上碰 keychain。见 `identityFooter`。
    @State private var identityAvatarSeed: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(machineGroups) { group in
                    Section {
                        sectionBody(group)
                    } header: {
                        machineHeader(group)
                    }
                }
            }
            .listStyle(.sidebar)
            // 当前身份 + 切换/登出。device grant 是 subject-scoped(spec v2 §4.4),
            // 想换 subject 必须撤掉这台机器的 grant 重新登录 —— 所以"切换身份"
            // 路径就是签出后再去直接登录页登一遍。这里集中放在 sidebar 底部,
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
                    Task {
                        await crewStore.refreshList()
                        await crewStore.refreshMachines()
                    }
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
        // 本机模式可选登录（登录 SSO C2）：先展示确认卡（有本机凭据时）
        // 或直接登录页（无凭据时）。登录成功后 CrewLoginSheet 自动 dismiss。
        .sheet(isPresented: $showingLogin) {
            CrewLoginSheet()
                .environmentObject(model)
                .frame(minWidth: 420, minHeight: 480)
        }
    }

    // MARK: - 机器分组

    private var machineGroups: [MachineGrouping.Group] {
        MachineGrouping.group(
            crews: crewStore.crews,
            machines: crewStore.machines,
            localDeviceId: DeviceIdentity.current
        )
    }

    @ViewBuilder
    private func sectionBody(_ group: MachineGrouping.Group) -> some View {
        if collapsedMachineIds.contains(group.id) {
            EmptyView()
        } else if group.crews.isEmpty {
            machineEmptyRow(group)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } else {
            CrewDAGTreeView(crews: group.crews)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    @ViewBuilder
    private func machineHeader(_ group: MachineGrouping.Group) -> some View {
        let machine = group.machine
        let isLocal = machine?.deviceId == DeviceIdentity.current
        let collapsed = collapsedMachineIds.contains(group.id)
        HStack(spacing: 6) {
            Button {
                if collapsed { collapsedMachineIds.remove(group.id) }
                else { collapsedMachineIds.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Image(systemName: machine?.displayIcon(isLocal: isLocal) ?? "questionmark.folder")
                        .foregroundStyle(.secondary)
                    Text(machine?.displayName ?? "其它")
                        .lineLimit(1)
                    if isLocal {
                        Text("本机")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Palette.surfaceMuted))
                    }
                    if let m = machine {
                        Circle()
                            .fill(machineOnline(m) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if isLocal {
                Button { showingCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("在本机新建 crew")
            }
        }
    }

    private func machineOnline(_ m: Machine) -> Bool {
        m.deviceId == DeviceIdentity.current || m.status == "online"
    }

    @ViewBuilder
    private func machineEmptyRow(_ group: MachineGrouping.Group) -> some View {
        let isLocal = group.machine?.deviceId == DeviceIdentity.current
        VStack(alignment: .leading, spacing: 4) {
            if isLocal {
                if crewStore.loadingList {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("加载中…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("还没有 crew").font(.callout).foregroundStyle(.secondary)
                    Text("点 + 新建第一个").font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                // 其它机器：local-first,本机看不到其 crew 内容 → 遥控投影是后续(#242)。
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.tertiary)
                    Text("遥控查看（稍后）").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    /// Sidebar 底部固定条。
    /// - 已登录:显示代表的 subject + ⋯ 菜单(签出/切换身份)。
    /// - 未登录:整行就是一个「登录」入口(用户定调:别堆"本机/七七八八"解释)——
    ///   点开窗口内登录面板；面板里再展示本机 PendingBot 直登或扫码登录。
    @ViewBuilder
    private var identityFooter: some View {
        Group {
            if model.isAuthenticated {
                HStack(spacing: 10) {
                    // 登录账号头像:用家族凭据里的 avatar_seed(与登录确认卡 BotAvatar
                    // 同字形,跨 app 一致);缺凭据(如未签名构建)回落 subject id —— 仍每
                    // 账号稳定。原先这里是写死的 SF Symbol 占位,不随身份变(`identityIcon`
                    // 已退役)。
                    BotAvatar(
                        seed: identityAvatarSeed ?? crewStore.subjects.first?.id ?? "?",
                        size: 26
                    )
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
                // 头像 seed 解析放 `.task`(不在 render 路径碰 keychain);subject 解析
                // 出来后 id 变 → 重跑一次拿到稳定回落。家族凭据里的 avatar_seed 与登录
                // 确认卡同字形,缺则回落 subject id。
                .task(id: crewStore.subjects.first?.id) {
                    identityAvatarSeed = CrewLoginIdentity.current()?.avatarSeed
                        ?? crewStore.subjects.first?.id
                }
            } else {
                Button {
                    showingLogin = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text("登录")
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // identity 三件套只在已登录 footer 渲染(未登录 footer 是登录菜单,
    // 自带文案)—— 接合 v2 后不再按 mode 分叉。头像走 `BotAvatar(seed:)`
    // (见 footer),不再用 SF Symbol。
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
}

#endif
