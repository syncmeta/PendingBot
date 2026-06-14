#if os(macOS)
import SwiftUI

/// Mac 主视图：两栏 + 按需 inspector。
///
/// - 左栏 CrewSidebarView ── crew 列表 + 新建 / 刷新
/// - 主栏 CrewCenterView   ── 选中 crew 的群聊会话页（白板 + 沟通渠道）
/// - inspector CrewSessionWindowView ── session 终端（切换条 + 终端 + composer +
///   审批卡片），**不再常驻**：点群聊里的 session 头像 / 「+」/ toolbar 开关才弹出。
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
    /// session inspector 呈现态。中栏 roster 头像点击 / 「+」/ toolbar 开关翻它。
    @State private var inspectorPresented = false
    /// 侧栏可见性。inspector 关时 `.all`(左 sidebar + 中栏并存)；inspector 开时
    /// 经 `onChange` 自动翻 `.detailOnly`(收起左 sidebar 腾宽)—— 否则
    /// sidebar + 中栏 + 固定宽 inspector 三段总宽超屏，窗口挂到屏幕外。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CrewSidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            CrewCenterView(inspectorPresented: $inspectorPresented)
                .environmentObject(sessionRunner)
                // **不设 navigationSplitViewColumnWidth** —— 诊断证明给它 ideal:560 会让
                // 它在 inspector present 时霸占整个容器宽(detail=1040 满宽,inspector 拿到
                // 400 却被挤到重叠/溢出),要手动拖一下才让位。去掉后它当弹性填充栏自动让位。
                //
                // 只给一个 minWidth 下限(不是 ideal,不贪婪):拖宽 inspector 时聊天栏压到
                // 320 就卡住,inspector 不能再宽 —— 根治"拖到 max 把聊天栏挤破"。sidebar
                // 收起时 inspector 仍可到 560；sidebar 开+窗口窄时自然在聊天栏触底处停。
                .frame(minWidth: 320)
        }
        .inspector(isPresented: $inspectorPresented) {
            CrewSessionWindowView()
                .environmentObject(sessionRunner)
                // 可拖动（min/ideal/max）。SwiftUI 原生 .inspector 有个首帧 bug：
                // 内容 hosting view 不会在 present 当帧同步到列宽，要等一次对 inspector
                // divider 的 geometry 变化才复位（用户手动"拖一下"）。CrewSessionWindowView
                // 在 onAppear 后做一次程序化 divider 同步兜这个 bug（见那里 resyncInspectorDivider）。
                .inspectorColumnWidth(min: 300, ideal: 400, max: 560)
        }
        // inspector 开 → 若 sidebar 还展开着就收起它（用户要的：开 inspector 自动让
        // sidebar 收）。**关 inspector 不自动弹回 sidebar** —— sidebar 由用户手动控制。
        .onChange(of: inspectorPresented) { _, open in
            if open, columnVisibility != .detailOnly {
                withAnimation { columnVisibility = .detailOnly }
            }
        }
        // 用户手动展开 sidebar(翻回 .all) 且 inspector 还开着 → 收起 inspector（互斥）。
        // inspector 自己开时只把 columnVisibility 设 .detailOnly，不会触发这里，无回环。
        .onChange(of: columnVisibility) { _, vis in
            if vis == .all && inspectorPresented {
                withAnimation { inspectorPresented = false }
            }
        }
        .task {
            // 首次进入时把列表 + subjects 都拉一遍 —— subjects 用于创建
            // crew sheet 的 picker，提前 prefetch 避免 sheet 打开时空。
            await crewStore.refreshList()
            await crewStore.refreshSubjects()
            // relay 同步代理常开（幂等启动）；未登录时 tick 是 no-op。
            // sessionRunner 一并注入 —— relay 拉到 task_request 时在本机自动
            // 起 session（#242 遥控 v1），与 inspector 手动起的 run 同一个切换条。
            relayAgent.start(appModel: model, sessionRunner: sessionRunner)
        }
    }
}
#endif
