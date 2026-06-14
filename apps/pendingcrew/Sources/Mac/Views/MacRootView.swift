#if os(macOS)
import SwiftUI
import AppKit

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
                // **detail 必须完全无宽度约束** —— 诊断证明任何约束(navigationSplitView
                // ColumnWidth ideal / .frame minWidth)都会让它在 inspector present 时不肯
                // 让位、霸占整个容器宽,inspector 被挤到溢出(就是那三张被切的图)。无约束时
                // 它当 NavigationSplitView 天然弹性填充栏,inspector 一开就自动让出空间。
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
        // 建 crew 后自动起机长（用户要的零摩擦：新建即启动 + 群里报到，无需手动点
        // 「启动 Captain」）。store 在 createCrew 完成后 set crewId；这里持有
        // sessionRunner，best-effort 拉起后置 nil。
        .onChange(of: crewStore.captainAutostartRequest) { _, req in
            guard let crewId = req else { return }
            Task {
                if let detail = crewStore.details[crewId], detail.captain != nil {
                    try? await sessionRunner.startCaptain(detail: detail, backend: model.backend)
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
            // relay 同步代理常开（幂等启动）；未登录时 tick 是 no-op。
            // sessionRunner 一并注入 —— relay 拉到 task_request 时在本机自动
            // 起 session（#242 遥控 v1），与 inspector 手动起的 run 同一个切换条。
            relayAgent.start(appModel: model, sessionRunner: sessionRunner)
        }
    }
}

/// 去掉 toolbar 底部那条灰色分隔线（`titlebarSeparatorStyle = .none`）。
///
/// 之前几次没生效的真因：在 `viewDidMoveToWindow` 设过一次，但 SwiftUI 把 toolbar
/// 装配完之后会把 separatorStyle 重置回 `.automatic`，我没在它之后补设。这版三重保险：
/// 挂上窗口立刻设一次 + 延迟 0.3s 抢在 SwiftUI 装配之后再设一次 + `tick`(crew 选择)
/// 变化时经 updateNSView 重设。**不碰** titlebarAppearsTransparent / backgroundColor /
/// titleVisibility / fullSizeContentView —— 上一版那套把 composer 材质带黑了，且没解决线。
private struct WindowSeparatorRemover: NSViewRepresentable {
    /// 任意会变的值（这里传 selectedCrewId）—— 变化时 SwiftUI 调 updateNSView，借机重设。
    var tick: String

    func makeNSView(context: Context) -> NSView { SeparatorKillerView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        SeparatorKillerView.killSeparator(nsView.window)
    }
}

private final class SeparatorKillerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.killSeparator(window)
        // SwiftUI 在 toolbar 装配完后会把它重置回 .automatic，延迟再设一次抢在它后面。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            Self.killSeparator(self?.window)
        }
    }

    static func killSeparator(_ window: NSWindow?) {
        window?.titlebarSeparatorStyle = .none
    }
}
#endif
