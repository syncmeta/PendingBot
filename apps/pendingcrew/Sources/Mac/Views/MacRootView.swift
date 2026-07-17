#if os(macOS)
import SwiftUI
import AppKit

/// Mac 主视图：**原生三栏 `NavigationSplitView`**（crew 列表 | 群聊 | 成员/终端）。
///
/// - 左栏 CrewSidebarView ── crew 列表 + 新建 / 刷新（原生 sidebar：圆角 + 材质 + 折叠开关）
/// - 中栏 CrewCenterView   ── 选中 crew 的群聊会话页（白板 + 沟通渠道）
/// - 右栏 CrewSessionWindowView ── 成员列表 / session 终端 + composer + 审批卡片，**常驻**
///
/// 用原生三栏（而非「2 栏 + detail 内塞 HSplitView」）的两条理由：① 保留原生 sidebar 质感
///（圆角 / 半透明材质 / 原生折叠开关）—— 自绘 HSplitView 给不了；② 列宽由系统协商，窗口
/// 窄了自动收某列，不会像旧 hybrid 那样按 ideal 把窗口撑超屏、把 sidebar 推出屏幕外裁掉
///（docs/tech-debt.md「inspector 被切」那条回归）。
///
/// Sidebar / Center / SessionWindow 都用 @EnvironmentObject 拿 CrewStore + AppModel；
/// CrewSessionRunner 是 view-local（一个窗口一份，多 run 并存由它自己管，见 chunk2 T1）。
struct MacThreePaneView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var crewStore: CrewStore
    @StateObject private var sessionRunner = CrewSessionRunner()
    /// 额度中心（侧栏 start;这里观察快照变化做警戒广播）。
    @ObservedObject private var quotaCenter = QuotaCenter.shared
    /// edge 信箱同步代理（接合 v2 block 3）—— window 级常驻，登录态下对已
    /// 接入 PendingBot 的 crew 跑 5s 拉/推循环。
    @StateObject private var relayAgent = CrewRelayAgent()
    /// 左 sidebar 可见性 —— 由原生 sidebar 折叠开关控制（默认 `.all`：三栏全开）。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sessionRunner.showingCockpit {
                // 驾驶舱模式（cockpit.md）：整片切到「侧栏 | 驾驶舱」两栏 —— 驾驶舱铺满
                // content+detail 的位置（非临时小窗口）。侧栏仍在,作为沿 DAG 选 crew 的
                // 范围选择器(切 crew 即切驾驶舱范围)。退出在驾驶舱头部。
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    CrewSidebarView()
                        .environmentObject(sessionRunner) // 侧栏头像状态点要看 runs
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                } detail: {
                    CockpitView(runner: sessionRunner)
                        .environmentObject(crewStore)
                }
            } else {
                // 原生三栏：列宽交系统协商。两侧 cap 住、中栏弹性吃 slack（免得右栏像旧版那样霸占
                // 大半屏留白）；窗口窄了系统自动收某列，不会按 ideal 撑窗超屏裁掉 sidebar。
                // detail（成员/终端）常驻 —— 切到某 session 时由 CrewSessionWindowView 自己在
                // 「成员列表 ↔ 终端」间切（viewingTerminal），不再需要单独开关收/放一栏。
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    CrewSidebarView()
                        .environmentObject(sessionRunner) // 侧栏头像状态点要看 runs
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                } content: {
                    CrewCenterView()
                        .environmentObject(sessionRunner)
                        .navigationSplitViewColumnWidth(min: 360, ideal: 520)
                } detail: {
                    CrewSessionWindowView()
                        .environmentObject(sessionRunner)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
                }
            }
        }
        // 每个 crew 记住自己右栏打开的 session（#481）：切 crew 时把选中态存回旧
        // crew、恢复新 crew 记住的那份 —— 切回来还是原来打开的 session，不串。
        .onChange(of: crewStore.selectedCrewId) { old, new in
            sessionRunner.switchCrew(from: old, to: new)
        }
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
        // 机长 `start_session` 命令排空后的待起 worker session 队列（chunk2 §2）。
        // **数组**：同一 tick 里连续多条命令落地时,单值 `@Published` 在 SwiftUI 合并
        // 同步赋值会丢掉中间几条 —— 见 `CrewStore.sessionSpawnRequests` 注释。这里立刻
        // 捕获 + 清空,避免同一批命令被 `.onChange` 重复触发处理。
        .onChange(of: crewStore.sessionSpawnRequests) { _, reqs in
            guard !reqs.isEmpty else { return }
            crewStore.sessionSpawnRequests = []
            Task {
                for req in reqs {
                    guard let detail = crewStore.details[req.crewId] else { continue }
                    let kind: LocalCodingAgentKind? = req.runner.flatMap {
                        $0 == "claude" ? .claudeCode : ($0 == "codex" ? .codex : nil)
                    }
                    do {
                        try await sessionRunner.startForBrief(
                            detail: detail, backend: model.backend, brief: req.brief,
                            runnerOverride: kind, isolation: req.isolation,
                            model: req.model, effort: req.effort, title: req.title)
                    } catch {
                        sessionRunner.lastStartError = error.localizedDescription
                    }
                }
            }
        }
        // session 自切模型/effort（set_session_profile）：claude 注入 /model /effort,
        // codex 白板说明。数组语义同 sessionSpawnRequests（防同 tick 丢命令）。
        .onChange(of: crewStore.profileChangeRequests) { _, reqs in
            guard !reqs.isEmpty else { return }
            crewStore.profileChangeRequests = []
            Task { for req in reqs { await sessionRunner.applyProfileChange(req) } }
        }
        // 定时唤醒登记（schedule_wakeup）→ runner 持久化 + 挂定时器。
        .onChange(of: crewStore.wakeupRequests) { _, reqs in
            guard !reqs.isEmpty else { return }
            crewStore.wakeupRequests = []
            for req in reqs { sessionRunner.scheduleWakeup(req) }
        }
        // 群聊收听登记（listen；#465）→ runner 登记 + 白板观察 + 广播直投。
        .onChange(of: crewStore.listenRequests) { _, reqs in
            guard !reqs.isEmpty else { return }
            crewStore.listenRequests = []
            for req in reqs { sessionRunner.applyListen(req) }
        }
        // 跨 crew 汇报线消息 → 唤醒目标 crew 机长（#463）。idle 才直投注入（busy
        // 的机长下轮白板注入自然看到）；机长没在跑 → **直接拉起**（@ 唤醒语义：
        // 不在跑不能只留白板），开场 prompt 带上这条消息;拉起失败才落白板注记。
        .onChange(of: crewStore.crewMessageWakes) { _, wakes in
            guard !wakes.isEmpty else { return }
            crewStore.crewMessageWakes = []
            for wake in wakes {
                let captainRun = sessionRunner.runs.first {
                    $0.crewId == wake.targetCrewId && $0.role == .captain && $0.status == .running
                }
                if let run = captainRun {
                    if !run.backend.isBusy {
                        run.send(CrewLocalMentionInjectLogic.renderInjection(
                            messageText: wake.text, senderName: wake.senderLabel))
                    }
                } else {
                    Task {
                        do {
                            guard let backend = model.backend else { throw CancellationError() }
                            let detail = try await backend.getCrew(wake.targetCrewId)
                            try await sessionRunner.startCaptain(
                                detail: detail, backend: backend,
                                wakeText: "\(wake.senderLabel)：\(wake.text)")
                        } catch {
                            LocalWhiteboardStore.shared.appendSessionMessage(
                                crewId: wake.targetCrewId, sessionId: "system",
                                text: "⚠️ 收到「\(wake.senderLabel)」的消息，自动拉起本 crew 机长失败（\(error.localizedDescription)）——手动起机长后它会在白板看到。",
                                senderName: "系统")
                        }
                    }
                }
            }
        }
        // 额度快照更新 → 过警戒线(≥85%)往活跃 crew 白板广播（按重置周期去重）。
        .onChange(of: quotaCenter.claude) { _, snap in
            sessionRunner.broadcastQuotaWarningIfNeeded(snap)
        }
        .onChange(of: quotaCenter.codex) { _, snap in
            sessionRunner.broadcastQuotaWarningIfNeeded(snap)
        }
        // 去掉 toolbar 底部那条灰色分隔线（详见 WindowSeparatorRemover）。tick 传
        // selectedCrewId —— 切 crew 时借 updateNSView 重设，抢在 SwiftUI 把它重置回去之后。
        .background(WindowSeparatorRemover(tick: crewStore.selectedCrewId ?? ""))
        .task {
            // app 重启后重挂持久化的定时唤醒（schedule_wakeup 不因重启失约）。
            sessionRunner.rearmWakeups()
            // 成员状态快照定时器（机长 list_sessions 的数据源）。
            sessionRunner.startSessionsSnapshotTimer()
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
