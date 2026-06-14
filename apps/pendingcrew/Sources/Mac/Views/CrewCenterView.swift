#if os(macOS)
import SwiftUI

/// 中栏（spec v2 §9）：选中 crew 的**群聊会话页**（白板 + 沟通渠道）。
///
/// crew 元数据 / 机长 / DAG / 责任比例从这里搬到了 `CrewDetailInspector`
/// (顶栏 ⓘ 打开)。session 终端不再常驻,收进按需 inspector（`CrewSessionWindowView`,
/// 由 MacThreePaneView 挂在 .inspector），从 toolbar 终端开关弹出。
struct CrewCenterView: View {
    /// session inspector 呈现态（提升在 MacThreePaneView）。toolbar 终端开关翻它。
    @Binding var inspectorPresented: Bool

    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @State private var showingDetail = false
    @State private var showingRemoteSessions = false
    /// chunk2 T5（captain 唤醒=app 注入）：已通知过 captain 的 decision id ——
    /// 防止每个 tick 重复注入同一条。**放在常驻中栏**（而非按需 inspector），
    /// captain 编排不能依赖 session 终端面板是否打开。
    @State private var notifiedDecisionIds: Set<String> = []
    /// 2s 轮询 LocalApprovalStore（helper 跨进程写文件、本进程读），有新待决策
    /// 就注入 captain PTY。
    private let captainTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let detail = crewStore.selectedDetail {
                CrewChatView(
                    crewId: detail.crew.id,
                    crewTitle: detail.crew.title,
                    onOpenSession: { runId in
                        sessionRunner.select(runId)
                        sessionRunner.viewingTerminal = true
                        inspectorPresented = true
                    },
                    onNewSession: {
                        sessionRunner.composeNew()
                        sessionRunner.viewingTerminal = true
                        inspectorPresented = true
                    }
                )
            } else if let id = crewStore.selectedCrewId, crewStore.loadingDetailIds.contains(id) {
                ProgressView("加载 crew 详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if crewStore.selectedCrewId != nil {
                empty("详情加载中…")
            } else {
                empty("在左侧选一个 crew，或者点 \"+\" 新建一个。")
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
        .toolbar {
            if let crewId = crewStore.selectedCrewId {
                ToolbarItem {
                    Button { showingDetail = true } label: {
                        Label("crew 详情", systemImage: "info.circle")
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
                ToolbarItem {
                    Button { inspectorPresented.toggle() } label: {
                        Label("Session 终端", systemImage: "sidebar.trailing")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .help("打开/收起 session 终端")
                }
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
        // chunk2 T5：captain 唤醒 = app 注入。常驻中栏轮询待决策，有新的（非 captain
        // 自己 raise 的）就把提示注入在跑的 captain PTY。不依赖 inspector 是否打开。
        .onReceive(captainTick) { _ in notifyCaptainOfNewDecisions() }
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
}
#endif
