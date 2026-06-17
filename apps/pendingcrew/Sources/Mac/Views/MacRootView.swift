#if os(macOS)
import SwiftUI
import AppKit

/// Mac 主视图：三栏（crew 列表 | 群聊 | session 终端），各栏独立折叠、互不强收。
///
/// - 左栏 CrewSidebarView ── crew 列表 + 新建 / 刷新（标准 sidebar 开关折叠）
/// - 主栏 CrewCenterView   ── 选中 crew 的群聊会话页（白板 + 沟通渠道）
/// - 右栏 CrewSessionWindowView ── session 终端（切换条 + 终端 + composer +
///   审批卡片）。toolbar「Session 终端」开关 / 点 session 头像 / 「+」翻它的可见性；
///   **开它不再强收左 sidebar** —— 三栏可同时在（宽屏；窄屏各自手动折叠）。
///
/// Sidebar / Center / SessionWindow 都用 @EnvironmentObject 拿 CrewStore +
/// AppModel；CrewSessionRunner 是 view-local（一个窗口一份，多 run 并存由它自己
/// 管，见 chunk2 T1）。inspector 的呈现态 `inspectorPresented` 提升到这里，经
/// binding 下传给中栏（roster 头像点击 / toolbar 开关从那里翻它）。
struct MacThreePaneView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var crewStore: CrewStore
    @StateObject private var sessionRunner = CrewSessionRunner()
    /// edge 信箱同步代理（接合 v2 block 3）—— window 级常驻，登录态下对已
    /// 接入 PendingBot 的 crew 跑 5s 拉/推循环。
    @StateObject private var relayAgent = CrewRelayAgent()
    /// 右栏 session 终端的可见性。中栏 roster 头像点击 / 「+」/ toolbar 开关翻它。
    /// 与左 sidebar **互不联动**（三栏各自折叠，回到 §9.3「右栏常驻 session」的初衷）。
    @State private var inspectorPresented = false
    /// 左 sidebar 可见性 —— 用户用标准 sidebar 开关控制，不再随右栏开合自动收放。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CrewSidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            // 群聊 + 按需的 session 终端，放进**确定性分栏**（HSplitView 底层是 NSSplitView，
            // 列宽首次布局即确定性协商）。**不再用 `.inspector`** —— 它"present 当帧只测一次
            // 内容宽、之后不重测"才是"展开左侧被切、要手拖 divider"那类回归的病灶（详见
            // docs/tech-debt.md）。终端栏只在 inspectorPresented 时出现；隐藏时 detail 就是群聊
            // 满宽。detail 列本身不设宽度约束（保持弹性），min 宽都落在 HSplitView 的子栏上。
            HSplitView {
                CrewCenterView(inspectorPresented: $inspectorPresented)
                    .environmentObject(sessionRunner)
                    .frame(minWidth: 320)
                if inspectorPresented {
                    CrewSessionWindowView()
                        .environmentObject(sessionRunner)
                        // 右栏内嵌 Claude/Codex 全屏 TUI，列数 = 栏宽 / 字宽。配 11pt 紧凑字体
                        // （见 AgentTerminalView）cell ~6.6pt：min 360≈54 列、ideal 480≈72。
                        // NSSplitView 首帧即给到这个宽，不会像 .inspector 那样被切、要手拖。
                        .frame(minWidth: 360, idealWidth: 480)
                }
            }
        }
        // 左 sidebar 与右栏终端**互不联动**(去掉旧的「开终端自动收 sidebar」互斥)——
        // 用户要三栏共存:crew 列表、群聊、session 终端各自独立折叠(标准 sidebar 开关 /
        // toolbar「Session 终端」开关)。窄屏总宽吃紧时由用户手动收某一栏。
        // 建 crew 后自动起机长（用户要的零摩擦：新建即启动 + 群里报到，无需手动点
        // 「启动 Captain」）。store 在 createCrew 完成后 set crewId；这里持有
        // sessionRunner，best-effort 拉起后置 nil。
        .onChange(of: crewStore.captainAutostartRequest) { _, req in
            guard let crewId = req else { return }
            Task {
                if let detail = crewStore.details[crewId], detail.captain != nil {
                    do {
                        try await sessionRunner.startCaptain(detail: detail, backend: model.backend)
                    } catch {
                        // 不再静默吞错：落到 runner 的共享通道，inspector 成员列表模式会显
                        // （否则建完 crew captain 没起、用户也不知道为什么）。
                        sessionRunner.lastStartError = error.localizedDescription
                    }
                }
                crewStore.captainAutostartRequest = nil
            }
        }
        // 去掉 toolbar 底部那条灰色分隔线（详见 WindowSeparatorRemover）。tick 传
        // selectedCrewId —— 切 crew 时借 updateNSView 重设，抢在 SwiftUI 把它重置回去之后。
        .background(WindowSeparatorRemover(tick: crewStore.selectedCrewId ?? ""))
        .task {
            // 首次进入时把列表 + subjects 都拉一遍 —— subjects 用于创建
            // crew sheet 的 picker，提前 prefetch 避免 sheet 打开时空。
            await crewStore.refreshList()
            await crewStore.refreshSubjects()
            // 机器清单（侧栏按机器分组的数据源）由 authenticatedRoot.task 的
            // registerSelfMachine + refreshMachines 负责（它包着 MacThreePaneView，
            // 首屏即跑），登录态切换再由 PendingCrewApp.onChange 刷一次 —— 这里不重复。
            // relay 同步代理常开（幂等启动）；未登录时 tick 是 no-op。
            // sessionRunner 一并注入 —— relay 拉到 task_request 时在本机自动
            // 起 session（#242 遥控 v1），与 inspector 手动起的 run 同一个切换条。
            relayAgent.start(appModel: model, sessionRunner: sessionRunner)
        }
    }
}

/// 让标题栏与内容无缝、且**不盖住 sidebar**。做三件事：
/// 1. `titlebarSeparatorStyle = .none` —— 去掉 hairline。
/// 2. `titlebarAppearsTransparent = true` —— 标题栏背景透明，不再画自己那层比内容浅
///    的材质（那层材质的下边沿就是用户看到的"灰线"）。
/// 3. `fullSizeContentView` —— 内容铺满到窗口顶。这样**每一栏各自的背景透上来**：
///    sidebar 透出它的侧栏材质（不被一条白 toolbar 盖住）、detail 透出白 canvas
///    （和下面群聊无缝、无灰线）。比窗口级 `.toolbarBackground` 刷单一颜色更对——
///    后者会把 sidebar 那半截也刷白。
///
/// **不设** `backgroundColor`（上一版设动态底色，被材质用暗外观取值成近黑，把 composer
/// 材质带黑了）。标题(navigationTitle)照常显示，不碰 titleVisibility。
///
/// 必须在 view 真正挂上 window 后设（`viewDidMoveToWindow`）；SwiftUI 装配 toolbar 后会把
/// separatorStyle 重置回 .automatic，故延迟 0.3s + `tick`(crew 选择)变化时各补设一次。
private struct WindowSeparatorRemover: NSViewRepresentable {
    /// 任意会变的值（这里传 selectedCrewId）—— 变化时 SwiftUI 调 updateNSView，借机重设。
    var tick: String

    func makeNSView(context: Context) -> NSView { SeparatorKillerView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        SeparatorKillerView.applyChrome(nsView.window)
    }
}

private final class SeparatorKillerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.applyChrome(window)
        // SwiftUI 在 toolbar 装配完后会把 separatorStyle 重置回 .automatic，延迟再设一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            Self.applyChrome(self?.window)
        }
    }

    static func applyChrome(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
#endif
