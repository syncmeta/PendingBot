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
                // 中栏 min 调小 —— 让 macOS 在窗口贴屏幕边时能压缩中栏腾给 inspector，
                // 而不是把窗口往屏幕外撑（两边被切的根因）。
                .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        }
        .inspector(isPresented: $inspectorPresented) {
            CrewSessionWindowView()
                .environmentObject(sessionRunner)
                // **弹性**宽（不固定）—— 窗口窄时能自己缩，不再两边切。成员列表 / 终端
                // 两模式共用这个列（宽度跟内容模式无关，开 session 不会变宽）。
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
        }
        // 根治超屏：inspector 一开就收起左 sidebar 腾出宽度，关掉再放回来。
        .onChange(of: inspectorPresented) { _, open in
            withAnimation { columnVisibility = open ? .detailOnly : .all }
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
