#if os(macOS)
import SwiftUI

/// 中栏（spec v2 §9）：选中 crew 的**群聊会话页**（白板 + 沟通渠道）。
///
/// crew 元数据 / 机长 / DAG / 责任比例从这里搬到了 `CrewDetailInspector`
/// (顶栏 ⓘ 打开)。session 终端不再常驻,收进按需 inspector（`CrewSessionWindowView`,
/// 由 MacThreePaneView 挂在 .inspector），从 toolbar 终端开关弹出。
struct CrewCenterView: View {
    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @State private var showingDetail = false
    @State private var showingRemoteSessions = false
    /// chunk2 T5（captain 唤醒=app 注入）：已通知过 captain 的 decision id ——
    /// 防止重复注入同一条。**放在常驻中栏**（而非按需 inspector），captain 编排
    /// 不能依赖 session 终端面板是否打开。
    @State private var notifiedDecisionIds: Set<String> = []

    var body: some View {
        Group {
            if let detail = crewStore.selectedDetail {
                CrewChatView(
                    crewId: detail.crew.id,
                    crewTitle: detail.crew.title,
                    onOpenSession: { runId in
                        // 右栏常驻；点 session 头像只切到「终端」模式 + 选中该 run。
                        sessionRunner.select(runId)
                        sessionRunner.viewingTerminal = true
                    },
                    onNewSession: {
                        sessionRunner.composeNew()
                        sessionRunner.viewingTerminal = true
                    }
                )
            } else if let id = crewStore.selectedCrewId, crewStore.loadingDetailIds.contains(id) {
                ProgressView("加载 crew 详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if crewStore.selectedCrewId != nil {
                empty("详情加载中…")
            } else {
                placeholder
            }
        }
        // 标题走原生 navigationTitle —— 位置/收合行为和系统窗口标题完全一致（不会跑到
        // 红绿灯后面、收 sidebar 也不冒第二个标题），纯文字无胶囊。操作按钮放 trailing
        // （macOS 26 自动给原生白色液态玻璃岛 + 阴影）。
        //
        // 标题文字与按钮组都 gate 在 selectedCrewId（而非 selectedDetail）——后者在切换
        // crew 时会短暂为 nil（detail 异步加载），导致标题清空 + 工具栏项目消失再出现，
        // 表现为"切换后 toolbar 闪一下"。用 selectedCrewId（切换瞬间即非 nil）+ 列表里的
        // title 兜底，整条就稳定不抖。
        .navigationTitle(crewStore.selectedDetail?.crew.title ?? crewStore.selectedCrew?.title ?? "")
        // 灰线/无缝由 WindowSeparatorRemover(标题栏透明 + 内容铺满到顶)统一处理。
        // **不能**在这里 .toolbarBackground 刷色：那是窗口级的，会连 sidebar 那半截 toolbar
        // 一起刷白，把侧栏顶部的半透明材质盖住（"toolbar 挡住 sidebar"）。透明标题栏让
        // sidebar 透出自己的侧栏材质、detail 透出白 canvas，两边各自对，互不打架。
        .toolbar {
            if let crewId = crewStore.selectedCrewId {
                ToolbarItem {
                    Button { showingDetail = true } label: {
                        Label("crew 详情", systemImage: "info.circle")
                    }
                    .disabled(crewStore.selectedDetail == nil)
                }
                ToolbarItem {
                    // 驾驶舱 = 主窗口模式开关(非 sheet);翻 true 后 MacThreePaneView 整片切到
                    // 「侧栏 | 驾驶舱」两栏,驾驶舱铺满。退出在驾驶舱头部。
                    Button { sessionRunner.showingCockpit = true } label: {
                        Label("驾驶舱", systemImage: "speedometer")
                    }
                    .disabled(crewStore.selectedDetail == nil)
                }
                ToolbarItem {
                    Button { showingRemoteSessions = true } label: {
                        Label("服务端 session", systemImage: "rectangle.on.rectangle.angled")
                    }
                    .disabled(crewStore.selectedDetail == nil)
                }
                ToolbarItem {
                    Button { Task { await crewStore.refreshDetail(crewId) } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                // 「Session 终端」开关已去掉 —— 右栏(成员/终端)在原生三栏里常驻;
                // 成员列表 ↔ 终端 的切换由右栏内部(viewingTerminal / 点 session)管。
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let detail = crewStore.selectedDetail {
                CrewDetailInspector(detail: detail)
                    .environmentObject(crewStore)
            }
        }
        .sheet(isPresented: $showingRemoteSessions) {
            if let detail = crewStore.selectedDetail {
                RemoteSessionsView(crewId: detail.crew.id, crewTitle: detail.crew.title)
            }
        }
        // chunk2 T5：captain 唤醒 = app 注入。常驻中栏**事件驱动**订阅待决策（去 2s
        // 轮询）：app 侧答复 + helper 跨进程 raise(目录监听)都推一个 tick,有新的(非
        // captain 自己 raise 的)就把提示注入在跑的 captain PTY。不依赖 inspector 是否打开。
        // `.task(id:)` 随选中 crew 切换重建订阅;无选中 crew 时 crewId=nil,不订阅。
        .task(id: crewStore.selectedCrewId) {
            guard let crewId = crewStore.selectedCrewId else { return }
            notifyCaptainOfNewDecisions()
            for await _ in LocalApprovalStore.shared.approvalChanges(crewId: crewId) {
                if Task.isCancelled { return }
                notifyCaptainOfNewDecisions()
            }
        }
    }

    /// 发现新待决策 → 注入运行中的 captain session（spec §2 唤醒=app 注入）。
    /// 没有在跑的 captain 就什么都不做（等 captain 启动后第一个 tick 再补通知）。
    private func notifyCaptainOfNewDecisions() {
        guard let crewId = crewStore.selectedDetail?.crew.id,
              let captainRun = sessionRunner.runs.first(where: {
                  $0.crewId == crewId && $0.role == .captain && $0.status == .running
              })
        else { return }
        let items = LocalApprovalStore.shared.pending(crewId: crewId).filter {
            $0.kind == "decision"
                && $0.sessionId != captainRun.sessionId
                && !notifiedDecisionIds.contains($0.id)
        }
        for item in items {
            captainRun.send("有新的待决策 #\(item.id)（来自 session \(item.sessionId)）：\(item.summary)\n能拍板就用 answer_decision 工具答它（reqId=\(item.id)）；拍不了就用 post_to_crew 发消息 @human 说明需要人类决策的理由与你的建议。")
            notifiedDecisionIds.insert(item.id)
        }
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        PendingCrewPlaceholderIcon(size: 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
