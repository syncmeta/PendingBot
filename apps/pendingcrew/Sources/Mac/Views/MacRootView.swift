#if os(macOS)
import SwiftUI

/// Mac 三栏主视图。spec v2 §12.1。
///
/// - 左栏 CrewSidebarView ── crew 列表 + 新建 / 刷新
/// - 中栏 CrewCenterView   ── 选中 crew 的 detail（spec v2 留作群聊位置）
/// - 右栏 CrewSessionWindowView ── 当前 session 的 stdout/stderr
///
/// Sidebar / Center / SessionWindow 都用 @EnvironmentObject 拿 CrewStore +
/// AppModel；CrewSessionRunner 是 view-local（一个窗口一个 active session
/// MVP 阶段 OK；多 session tab 留 v1.1）。
struct MacThreePaneView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var crewStore: CrewStore
    @StateObject private var sessionRunner = CrewSessionRunner()
    /// edge 信箱同步代理（接合 v2 block 3）—— window 级常驻，登录态下对已
    /// 接入 PendingBot 的 crew 跑 5s 拉/推循环。
    @StateObject private var relayAgent = CrewRelayAgent()

    var body: some View {
        NavigationSplitView {
            CrewSidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            CrewCenterView()
                .environmentObject(sessionRunner)
                .navigationSplitViewColumnWidth(min: 420, ideal: 600)
        } detail: {
            CrewSessionWindowView()
                .environmentObject(sessionRunner)
                .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        }
        .task {
            // 首次进入时把列表 + subjects 都拉一遍 —— subjects 用于创建
            // crew sheet 的 picker，提前 prefetch 避免 sheet 打开时空。
            await crewStore.refreshList()
            await crewStore.refreshSubjects()
            // relay 同步代理常开（幂等启动）；未登录时 tick 是 no-op。
            relayAgent.start(appModel: model)
        }
    }
}
#endif
