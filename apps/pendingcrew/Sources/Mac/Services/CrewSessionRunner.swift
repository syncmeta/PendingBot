#if os(macOS)
import Combine
import Foundation
import SwiftUI

/// Bridges a local `CrewSessionRun` to its server-side `crew_sessions` row so
/// cross-device viewers can see a session exists + when it ends. Logged mode
/// only; BYOK runs pass `nil` and stay purely local.
///
/// **Phase 1 scope**: just the row lifecycle close (`finish`). The structured
/// per-event transcript mirror + the realtime SessionProxy socket were ripped
/// out with the one-shot runner — Phase 2 rebuilds live cross-device control as
/// a raw byte tunnel over the embedded terminal's PTY, not as parsed events.
///
/// **Best-effort**: the server call is `try?`'d — a failure (network blip,
/// scope gap, evicted lease) is logged but never disrupts the local agent
/// process. The local run is always the source of truth for the user.
struct CrewSessionServerLink: Sendable {
    let api: PendingCrewAPI
    let runnerHostId: String
    let sessionId: String

    /// Close out the server session row. `localStatus` is the run's terminal
    /// state mapped to the server's completed/failed/cancelled enum.
    func finish(localStatus: CrewSessionRun.Status, summary: String?) async {
        let status: String
        switch localStatus {
        case .completed: status = "completed"
        case .cancelled: status = "cancelled"
        default: status = "failed"
        }
        do {
            try await api.finishSession(
                runnerHostId: runnerHostId,
                sessionId: sessionId,
                status: status,
                summary: summary
            )
        } catch {
            print("[crew-session] finish failed: \(error)")
        }
    }
}

/// local coding agent 跑动的 view-side 视图模型（chunk2 T1：多 run 并存）。
///
/// 每次 `start(...)` 起一个新 `CrewSessionRun` 追加进 `runs` 并选中——旧 run
/// **不再**被自动停掉，N 个 session 并行各自跑各自的 PTY，无并发上限。
/// 右栏 session 切换条（T2）靠 `selectedRunId` 决定哪个 run 在前台。
///
/// 每个 run 内嵌一个真 PTY 终端（`AgentTerminalSession`），跑交互式
/// claude/codex（自动审批）。读=终端原样渲染；控=键盘 + 程序化 send/stop。
@MainActor
final class CrewSessionRunner: ObservableObject {
    @Published private(set) var runs: [CrewSessionRun] = []
    @Published var selectedRunId: UUID?

    /// 「新建 session」态：inspector 显示零配置 composer 而非某个 run。由 roster /
    /// 切换条的「+」置 true，启动成功或切到某个 run 时复位。UI 选择态（与
    /// `selectedRunId` 同类），放这里让 roster（开 inspector 的一端）与 inspector
    /// composer（消费的一端）无需额外 binding 即可共享。
    @Published var isComposingNew = false

    /// inspector 内的模式开关：`false`=成员列表模式（平时看 roster + 待审批），
    /// `true`=终端模式（看某个 session 的终端 + composer）。点 session 行 / 起新
    /// session 翻 true；inspector 顶「‹ 成员」返回翻 false。toolbar 的「Session 终端」
    /// 开关只翻 inspector 呈现态，不强制 true —— 让用户先落在成员列表。
    @Published var viewingTerminal = false

    /// 驾驶舱模式（cockpit.md）：`true` 时主窗口从「三栏群聊」整片切到「侧栏 | 驾驶舱」
    /// 两栏——驾驶舱铺满 content+detail（不是临时小窗口/info 面板）。侧栏仍在,作为
    /// **沿 DAG 选 crew 的范围选择器**。中栏 toolbar「驾驶舱」按钮翻 true,驾驶舱头部
    /// 「退出」翻 false。放 runner 上让 MacThreePaneView（决定布局）与中栏（入口）共享。
    @Published var showingCockpit = false

    /// 最近一次「启动 Captain」失败的人类可读原因（手动按钮 + 建 crew 自动起共用）。
    /// 错误从前台终端模式（composer 里渲染 `localError`）和成员列表模式（按钮所在
    /// 那屏）两处都看不到会让人误以为「点了没反应」—— 所以放在 runner 上，让按钮所在
    /// 的成员列表模式也能显，且自动起（MacRootView，无 view-local error）失败时同样有处可落。
    /// 成功启动或下一次尝试开始时清空。
    @Published var lastStartError: String?

    /// 前台 run：选中的那个；没选中（或选中的已被移除）时回退最后一个 ——
    /// 回退只在前台 crew 内找,不越 crew 顶出别人的终端（#481）。
    /// 保留这个名字让既有 call site（composer / auto-claim）继续编译。
    var current: CrewSessionRun? {
        if let sel = runs.first(where: { $0.runID == selectedRunId }) { return sel }
        if let crewId = activeCrewId { return runs.last { $0.crewId == crewId } }
        return runs.last
    }

    // MARK: - per-crew 右栏选中态（#481）

    /// 右栏当前对应的 crew（`MacThreePaneView` 在 `selectedCrewId` 变化时经
    /// `switchCrew` 同步）。`start()` 用它判断新 run 属不属于前台 crew。
    private(set) var activeCrewId: String?

    /// 单个 crew 记住的右栏 UI 态：打开着哪个 session、终端还是成员列表、新建态。
    private struct PaneState {
        var selectedRunId: UUID?
        var viewingTerminal = false
        var isComposingNew = false
    }

    /// 每个 crew 各自的右栏态 —— 切 crew 存旧恢新，互不串。
    private var paneStates: [String: PaneState] = [:]

    /// 切 crew（#481）：把右栏选中态存回旧 crew，恢复新 crew 自己记住的那份。
    /// 记住的 run 已被移除时退回成员列表默认态（不 fallback 到别的 crew 的 run）。
    func switchCrew(from oldCrewId: String?, to newCrewId: String?) {
        guard oldCrewId != newCrewId else { return }
        if let old = oldCrewId {
            paneStates[old] = PaneState(selectedRunId: selectedRunId,
                                        viewingTerminal: viewingTerminal,
                                        isComposingNew: isComposingNew)
        }
        activeCrewId = newCrewId
        var st = newCrewId.flatMap { paneStates[$0] } ?? PaneState()
        if let rid = st.selectedRunId,
           !runs.contains(where: { $0.runID == rid && $0.crewId == newCrewId }) {
            st = PaneState()
        }
        selectedRunId = st.selectedRunId
        viewingTerminal = st.viewingTerminal
        isComposingNew = st.isComposingNew
    }

    /// 事件驱动唤醒（Phase 4b）：**一个 crew 一个 waker**，该 crew 上的多个登录态
    /// run 共用一条 hub 连接。登录态 run 启动时 `ensureMailboxWaker` 懒建，最后一个
    /// 该 crew 的登录态 run 移除时收掉。BYOK/local-only 不建（无服务端 hub）。
    private var mailboxWakers: [String: CrewMailboxWaker] = [:]

    init() {}

    /// 切换前台 run（退出「新建」态）。
    func select(_ runId: UUID) {
        selectedRunId = runId
        isComposingNew = false
    }

    /// 进入「新建 session」态（composer 显零配置启动面）。
    func composeNew() {
        isComposingNew = true
    }

    /// 停掉指定 run（保留在列表里，状态落 cancelled）。
    func stop(_ runId: UUID) {
        guard let run = runs.first(where: { $0.runID == runId }) else { return }
        let crewId = run.crewId
        run.stop()
        teardownMailboxWakerIfIdle(crewId: crewId)
        teardownPermissionRelay(sessionId: run.sessionId)
    }

    /// 移除指定 run（仍在跑则先停）。被移除的是选中项时，回退选最后一个。
    func remove(_ runId: UUID) {
        guard let idx = runs.firstIndex(where: { $0.runID == runId }) else { return }
        let run = runs[idx]
        let crewId = run.crewId
        if run.status == .running { run.stop() }
        runs.remove(at: idx)
        if selectedRunId == runId {
            // 回退只在同 crew 内找（#481）—— 别把前台切到另一个 crew 的 run。
            selectedRunId = runs.last(where: { $0.crewId == crewId })?.runID
        }
        teardownMailboxWakerIfIdle(crewId: crewId)
        teardownPermissionRelay(sessionId: run.sessionId)
    }

    // MARK: - permission over WS（#204）

    /// 每个登录态 run 一条 permission relay：本地待审批 → SessionProxyDO
    /// permission.request 实时推给远端 viewer；viewer 的 allow/deny 经 WS
    /// 回来 → 解本地 hook 阻塞；本地先答的 → mirror 到服务端 decide。
    /// BYOK / local-only run（无 server session 行）不建。
    private var permissionRelays: [String: SessionPermissionRelay] = [:]

    /// 登录态 run 起好后由 call site 调（同 `ensureMailboxWaker` 的时机与
    /// 依赖：device-grant token + baseURL）。幂等 —— 已有 relay 则 no-op。
    func ensurePermissionRelay(
        crewId: String, sessionId: String, api: PendingCrewAPI, baseURL: URL, token: String
    ) {
        guard permissionRelays[sessionId] == nil else { return }
        let client = SessionProxyClient(
            baseURL: baseURL, sessionId: sessionId, role: .runner, token: token)
        let relay = SessionPermissionRelay(
            crewId: crewId, sessionId: sessionId, client: client,
            mirrorDecide: { serverRequestId, decision in
                // best-effort 一次性 mirror：失败只影响远端卡片的即时清除，
                // 远端仍可自行决定（服务端 RPC 幂等冲突回 409，不炸）。
                try? await api.decidePermissionRequest(id: serverRequestId, decision: decision)
            })
        permissionRelays[sessionId] = relay
        relay.start()
    }

    private func teardownPermissionRelay(sessionId: String) {
        permissionRelays.removeValue(forKey: sessionId)?.stop()
    }

    // MARK: - session 自我配置（set_session_profile；#455）

    /// 应用一条 session 自切模型/effort 请求。
    /// - claude（PTY）：注入 `/model` `/effort` 斜杠命令（与人手打等价、立即生效）。
    ///   两条命令**分两笔隔一拍**发 —— send() 的延迟回车是异步的,背靠背两次 send
    ///   会让第二条正文插进第一条的回车前（变成一坨粘贴文本）。
    /// - codex：app-server 协议无中途切换通道（model 是 thread 级、effort 是 spawn
    ///   期 -c）——白板落一条说明,让 session/机长知道该走 start_session 另起。
    /// - 目标 run 不在跑：白板落说明（fail-loud,不静默吞）。
    func applyProfileChange(_ req: SessionProfileChangeRequest) async {
        guard let run = runs.first(where: { $0.sessionId == req.sessionId && $0.status == .running }) else {
            LocalWhiteboardStore.shared.appendSessionMessage(
                crewId: req.crewId, sessionId: "system",
                text: "⚠️ set_session_profile 未生效：目标 session 已不在跑。", senderName: "系统")
            return
        }
        switch run.kind {
        case .claudeCode:
            if let m = req.model { run.send("/model \(m)"); run.model = m }
            if let e = req.effort {
                if req.model != nil { try? await Task.sleep(nanoseconds: 700_000_000) }
                run.send("/effort \(e)"); run.effort = e
            }
            // 回写 run.model/effort（@Published）→ 成员卡即时反映当前配置。MCP 自切
            // 与人面切换都经此路径,UI 显示保持一致。
        case .codex:
            LocalWhiteboardStore.shared.appendSessionMessage(
                crewId: req.crewId, sessionId: "system",
                text: "ℹ️ \(run.displayName) 请求切换模型/effort，但 codex 不支持中途切换（model 绑 thread、effort 绑启动参数）。要换配置请让机长 start_session 带 model/effort 另起一个 session 接手。",
                senderName: "系统")
        }
    }

    // MARK: - 定时唤醒（schedule_wakeup；#455 额度重置自唤醒）

    /// 待触发的定时唤醒（持久化在 wakeups.json —— app 重启后 `rearmWakeups()` 重挂,
    /// 不因重启丢约）。
    struct PendingWakeup: Codable, Equatable {
        let id: String
        let crewId: String
        let sessionId: String
        let fireAt: String   // ISO8601
        let note: String
    }

    private var wakeupTimers: [String: Timer] = [:]
    private static var wakeupsFile: URL {
        LocalWhiteboardStore.defaultDirectory.appendingPathComponent("wakeups.json")
    }

    /// 登记一条定时唤醒：持久化 + 挂定时器。同 id 重复登记忽略（drain 重放安全）。
    func scheduleWakeup(_ req: SessionWakeupRequest) {
        var pending = Self.loadWakeups()
        guard !pending.contains(where: { $0.id == req.id }) else { return }
        let w = PendingWakeup(id: req.id, crewId: req.crewId, sessionId: req.sessionId,
                              fireAt: req.fireAt, note: req.note)
        pending.append(w)
        Self.saveWakeups(pending)
        arm(w)
    }

    /// app 启动时重挂所有持久化的唤醒（已过期的立即触发 —— 迟到好过失约）。
    func rearmWakeups() {
        for w in Self.loadWakeups() where wakeupTimers[w.id] == nil { arm(w) }
    }

    private func arm(_ w: PendingWakeup) {
        let fireAt = McpServer.parseISO(w.fireAt) ?? Date()
        let delay = max(1, fireAt.timeIntervalSinceNow)
        wakeupTimers[w.id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire(w) }
        }
    }

    private func fire(_ w: PendingWakeup) {
        wakeupTimers[w.id]?.invalidate()
        wakeupTimers[w.id] = nil
        Self.saveWakeups(Self.loadWakeups().filter { $0.id != w.id })
        let now = ISO8601DateFormatter().string(from: Date())
        if let run = runs.first(where: { $0.sessionId == w.sessionId && $0.status == .running }) {
            run.send("""
            【定时唤醒】(你之前用 schedule_wakeup 设的时间到了;系统注入,合法可信)
            - 备注: \(w.note)
            - 现在: \(now)。先 get_quota 确认额度,然后按备注继续。
            """)
        } else {
            // 目标已退 → 白板留痕,机长/人能看到这条"有约没人赴"并决定是否重派。
            LocalWhiteboardStore.shared.appendSessionMessage(
                crewId: w.crewId, sessionId: "system",
                text: "⏰ 定时唤醒到点，但目标 session 已不在跑。备注：\(w.note)",
                senderName: "系统")
        }
    }

    // MARK: - 群聊收听（listen；#465）

    /// 生效中的收听登记（每 session 至多一条，后写覆盖）。**内存态不持久化** ——
    /// 本地 run 不跨 app 重启，收听跟着 run 的生命周期走。
    private var listeners: [CrewListenLogic.Listener] = []
    /// sessionId → 所属 crewId（决定观察哪块白板）。
    private var listenerCrew: [String: String] = [:]
    /// 每 crew 的收听游标（白板 entry id）：只送「开启收听之后」的新消息。
    private var listenCursors: [String: String] = [:]
    private var listenWatchers: [AnyCancellable] = []

    /// 应用一条 `listen` 请求（开/关群聊收听）。开 = 覆盖登记 + 游标钉到白板当前
    /// 末尾（历史消息不回放 —— 白板每轮整块注入本就覆盖）；关 = 撤销登记。
    /// 到期自动失效（`CrewListenLogic.decide` 按 `until` 判定 + 惰性清理）。
    func applyListen(_ req: SessionListenRequest) {
        listeners.removeAll { $0.sessionId == req.sessionId }
        if req.off {
            listenerCrew[req.sessionId] = nil
            return
        }
        guard let until = req.until.flatMap(McpServer.parseISO), until > Date() else { return }
        // 本 crew 还没有别的收听者时才钉游标 —— 已有收听者的游标在跟进中，
        // 重置会把没送完的窗口吞掉。
        if !listenerCrew.values.contains(req.crewId) {
            listenCursors[req.crewId] = LocalWhiteboardStore.shared.list(crewId: req.crewId).last?.id
        }
        listeners.append(CrewListenLogic.Listener(
            sessionId: req.sessionId, until: until, senders: req.senders))
        listenerCrew[req.sessionId] = req.crewId
        startListenWatchIfNeeded()
        // 不再往白板发「👂 …开启了群聊收听…」系统回执 —— 群消息保持精简,收听是
        // session 自己的事,发起方的确认由 McpServer listen 的 toolResult 只回本
        // session（不进白板,用户明确要「只自己看到、不进群」）。登记/投递/到期清理
        // 都在此之上、独立于这条回执,删掉不影响收听功能。
    }

    /// 挂上白板观察（幂等）。进程内 append 走 `changes`（带 crewId）；helper 子进程
    /// 的 `post_to_crew` 写盘走 `directoryChanged`（无 crewId → 扫所有有收听者的
    /// crew，读增量很廉价）。两路对同一批消息先后触发时，游标推进让第二次成 no-op。
    private func startListenWatchIfNeeded() {
        guard listenWatchers.isEmpty else { return }
        LocalWhiteboardStore.shared.startWatching()
        LocalWhiteboardStore.shared.changes
            .sink { [weak self] crewId in
                Task { @MainActor in self?.deliverListens(crewId: crewId) }
            }
            .store(in: &listenWatchers)
        LocalWhiteboardStore.shared.directoryChanged
            .sink { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    for crewId in Set(self.listenerCrew.values) {
                        self.deliverListens(crewId: crewId)
                    }
                }
            }
            .store(in: &listenWatchers)
    }

    /// 把该 crew 白板游标之后的新消息按收听登记投给空闲的收听 run。
    /// busy 不打断（决策核心语义）——漏掉的由下一轮白板整块注入兜底。
    private func deliverListens(crewId: String) {
        pruneExpiredListeners()
        let active = listeners.filter { listenerCrew[$0.sessionId] == crewId }
        guard !active.isEmpty else { return }
        let entries = LocalWhiteboardStore.shared.entries(
            crewId: crewId, afterId: listenCursors[crewId])
        guard let last = entries.last else { return }
        listenCursors[crewId] = last.id
        let runStates = runs.filter { $0.status == .running }
            .map { CrewLocalMentionInjectLogic.RunState(sessionId: $0.sessionId, isBusy: $0.backend.isBusy) }
        let injections = CrewListenLogic.decide(
            entries: entries, listeners: active, runs: runStates, now: Date())
        for inj in injections {
            runs.first { $0.sessionId == inj.sessionId && $0.status == .running }?.send(inj.text)
        }
    }

    /// 惰性清理：过期登记 + 已无收听者的 crew 游标。到期不发通知（像人不再盯群，
    /// 静默回落到「仅 @ 唤醒」）。
    private func pruneExpiredListeners() {
        let now = Date()
        let expired = listeners.filter { $0.until <= now }.map(\.sessionId)
        guard !expired.isEmpty else { return }
        listeners.removeAll { $0.until <= now }
        for sid in expired { listenerCrew[sid] = nil }
        let liveCrews = Set(listenerCrew.values)
        listenCursors = listenCursors.filter { liveCrews.contains($0.key) }
    }

    // MARK: - 成员状态快照（机长 list_sessions 用;#463 组织能力）

    /// 把 runs 实时状态落 crew-sessions.json（离线 helper 的 `list_sessions` 读）。
    /// 2 秒节流定时器周期写 + start/remove 即写 —— run 的 working/health 变化
    /// 最迟 2 秒进快照,机长点名够用,不追帧。
    private var snapshotTimer: Timer?

    func startSessionsSnapshotTimer() {
        guard snapshotTimer == nil else { return }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persistSessionsSnapshot() }
        }
    }

    func persistSessionsSnapshot() {
        var snapshot = CrewSessionsSnapshot()
        snapshot.updatedAt = ISO8601DateFormatter().string(from: Date())
        for run in runs {
            let state: String
            var healthDetail: String? = nil
            if run.status != .running {
                state = "exited"
            } else if let h = run.health {
                state = "error"; healthDetail = h.detail
            } else {
                state = run.isWorking ? "working" : "idle"
            }
            snapshot.crews[run.crewId, default: []].append(CrewSessionsSnapshot.Entry(
                sessionId: run.sessionId, name: run.displayName,
                role: run.role == .captain ? "captain" : "worker",
                brief: run.role == .captain ? "" : run.taskBrief,
                state: state, healthDetail: healthDetail))
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(
            to: LocalWhiteboardStore.defaultDirectory
                .appendingPathComponent(CrewSessionsSnapshot.fileName),
            options: .atomic)
    }

    // MARK: - 撞墙自动挂钩 + 额度警戒广播（#455 增补：不只靠 session 自觉）

    /// session 撞到 usageLimit（健康感知首报,每 session 一次）→ 自动挂一条
    /// 「额度重置后唤醒」。重置时刻取额度快照:claude 解析 /usage 人话文本,
    /// codex 用 ISO;都解析不出 → 45 分钟保守重试（唤醒词让它先 get_quota
    /// 核实,醒来仍受限会自己顺延,不会瞎跑）。
    func autoScheduleQuotaWakeup(for run: CrewSessionRun) {
        guard !Self.loadWakeups().contains(where: {
            $0.sessionId == run.sessionId && $0.note.hasPrefix("[auto]")
        }) else { return }
        Task { @MainActor in
            await QuotaCenter.shared.refresh()   // 撞墙瞬间拿最新重置时刻
            let snap = run.kind == .claudeCode ? QuotaCenter.shared.claude : QuotaCenter.shared.codex
            let resetText = snap?.fiveHourWindow?.resetsAt
            let reset: Date? = run.kind == .claudeCode
                ? resetText.flatMap { ClaudeResetTimeParser.parse($0) }
                : resetText.flatMap { McpServer.parseISO($0) }
            let fireAt = reset.map { $0.addingTimeInterval(180) }
                ?? Date().addingTimeInterval(45 * 60)
            let iso = ISO8601DateFormatter().string(from: fireAt)
            scheduleWakeup(SessionWakeupRequest(
                id: "autoq-\(run.sessionId)-\(Int(fireAt.timeIntervalSince1970))",
                crewId: run.crewId, sessionId: run.sessionId, fireAt: iso,
                note: "[auto] 你之前撞到额度上限被迫停下,现在按重置时刻叫醒你：先 get_quota 核实额度已恢复,再回顾白板与工作区继续未完成的活;若仍受限,自己 schedule_wakeup 顺延。"))
            LocalWhiteboardStore.shared.appendSessionMessage(
                crewId: run.crewId, sessionId: "system",
                text: "⏰ \(run.displayName) 撞到额度上限，已自动挂额度重置唤醒（\(iso)）。",
                senderName: "系统")
        }
    }

    /// 已广播过的警戒键（agent|窗|重置时刻）——一个重置周期只喊一次,不刷屏。
    private var warnedQuotaKeys: Set<String> = []

    /// 额度过警戒线（任一窗已用 ≥85%）→ 往所有有活跃 run 的 crew 白板广播。
    /// session 每轮注入白板 → 不用主动轮询 get_quota 也能"发现"额度将尽,
    /// 接上世界观 §11 教的「收尾成可交接 → schedule_wakeup 约醒」动作。
    func broadcastQuotaWarningIfNeeded(_ snap: AgentQuotaSnapshot?) {
        guard let snap else { return }
        let name = snap.agent == "claude" ? "Claude Code" : "Codex"
        for w in snap.windows where w.usedPercent >= 85 {
            let key = "\(snap.agent)|\(w.label)|\(w.resetsAt ?? "?")"
            guard !warnedQuotaKeys.contains(key) else { continue }
            warnedQuotaKeys.insert(key)
            for crewId in Set(runs.filter({ $0.status == .running }).map(\.crewId)) {
                LocalWhiteboardStore.shared.appendSessionMessage(
                    crewId: crewId, sessionId: "system",
                    text: "⚠️ 额度警戒：\(name) \(w.label)已用 \(w.usedPercent)%"
                        + (w.resetsAt.map { "（\($0) 重置）" } ?? "")
                        + "。各 session 请及时把手头活收尾成可交接状态（该提交的提交、进展发白板），必要时 schedule_wakeup 约在重置后继续；新的重活先缓。",
                    senderName: "系统")
            }
        }
    }

    private static func loadWakeups() -> [PendingWakeup] {
        guard let data = try? Data(contentsOf: wakeupsFile),
              let list = try? JSONDecoder().decode([PendingWakeup].self, from: data) else { return [] }
        return list
    }

    private static func saveWakeups(_ list: [PendingWakeup]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: wakeupsFile, options: .atomic)
    }

    // MARK: - 事件驱动唤醒（Phase 4b）

    /// 为一个 crew 确保有一条 hub waker 在跑（一个 crew 一个，多 run 共用）。
    /// 登录态 run 启动后由 call site 调（传入已鉴权的 `api` + device-grant `token`
    /// + `baseURL`）。已存在则只补拉一次 inbox（刚起的 run 可能已有@我的待处理项，
    /// 不等下一个 hub 事件）。
    func ensureMailboxWaker(crewId: String, api: PendingCrewAPI, baseURL: URL, token: String) {
        if let existing = mailboxWakers[crewId] {
            Task { await existing.drain() }   // 新 run 加入，补一次
            return
        }
        let client = CrewRealtimeClient(baseURL: baseURL, crewId: crewId, token: token)
        let waker = CrewMailboxWaker(crewId: crewId, api: api, client: client, runner: self)
        mailboxWakers[crewId] = waker
        waker.start()
        Task { await waker.drain() }          // 起手补一次，不等首个 hub 事件
    }

    /// 该 crew 已无登录态 running run → 收掉 waker（断 hub）。
    func teardownMailboxWakerIfIdle(crewId: String) {
        let stillActive = runs.contains {
            $0.crewId == crewId && $0.status == .running && $0.hasServerSession
        }
        guard !stillActive, let waker = mailboxWakers.removeValue(forKey: crewId) else { return }
        waker.stop()
    }

    /// 起一个新 session。pre-flight 失败抛错（工具未装 / 超并发上限）。成功后
    /// 把新 run 追加进 `runs` 并选中；agent 在内嵌终端里交互式跑，旧 run 不受影响。
    func start(
        crewId: String,
        /// 本 session 的合成 id（BYOK localSessionId / logged 服务端 id）—— 存到 run 上，
        /// 右栏内联待办卡片靠它从 `LocalApprovalStore` 过滤出本 session 的待决策/待审批。
        sessionId: String,
        /// 完整的 per-session 启动配置（kind / model / effort / initialPrompt /
        /// permissionMode）—— argv 由 `config.argv()` 构建（spec §1/§11）。
        config: SessionConfig,
        workingDirectory: URL,
        taskBrief: String,
        /// 精简标题（单一真值，见 `CrewSessionRun.title`）。nil = 从 `taskBrief` 兜底
        /// derive。captain 起 session 时把 `--label` 传的 title 一并透进来，让 run
        /// 上的 title 与 helper 白板署名逐字一致。
        title: String? = nil,
        additionalEnv: [String: String] = [:],
        /// 当登录时，caller 备好 server-side session（register host → create →
        /// claim）并把 link 传进来，run 在结束时关掉 server row（让跨端列表能看到
        /// session 已结束）。`nil` = BYOK / local-only。
        serverLink: CrewSessionServerLink? = nil,
        /// codex 世界观（字符串）→ `thread/start.developerInstructions`。caller 在
        /// 拿得到 detail/members 处用 `LocalSessionLaunch.renderWorldModelString` 算好传入。
        /// claude 不用这个 —— claude 走 `config.appendSystemPromptFile`（文件路径）。
        developerInstructions: String? = nil,
        /// codex crew MCP 配置 dict → `thread/start.mcpServers`。caller 用
        /// `LocalSessionLaunch.codexMcpServers` 算好传入。claude 不用 —— 走
        /// `config.mcpConfigFile`（文件路径）。
        codexMcpServers: [String: Any]? = nil,
        /// captain / worker 角色标记（session 切换条展示 + captain 置顶）。
        role: CrewSessionRun.Role = .worker
    ) async throws {
        // 没显式选 model → 解析一个具体默认别名显式落进 config（argv 带 --model、
        // run.model 永不为 nil）：显示=实际跑的模型，不再糊「默认」(#489)。codex 若
        // 读不到 ~/.codex/config.toml 的 model 仍为 nil（保持 CLI 默认）。
        var config = config
        if config.model == nil {
            config.model = SessionLaunchOptions.defaultModel(
                for: config.kind, projectDir: workingDirectory)
        }
        // 1. 校验工具可用 + resolve 可执行路径
        guard let executable = LocalCodingAgentExecutable.resolve(config.kind) else {
            throw RunnerError.toolNotInstalled(kind: config.kind)
        }
        // 2. env 白名单（spec v2 §8.4.2）—— 复用 spec 的纯函数构造。
        let env = LocalCodingAgentEnv.build(additionalEnv: additionalEnv, kind: config.kind)
        // 3. 按 kind 选后端：claude = 内嵌真 PTY 终端；codex = app-server（stdio JSON-RPC）。
        let backend: any SessionBackend
        switch config.kind {
        case .claudeCode:
            backend = AgentTerminalSession(
                config: config,
                executable: executable.path,
                workdir: workingDirectory.path,
                env: env
            )
        case .codex:
            // codex 没有 claude 的 hook/settings 通道：世界观经 developerInstructions、
            // MCP 经 thread/start 的 config.mcp_servers、白板每轮作为 turn/start 的首条
            // text input 注入、审批经 server request。
            // 后两者用 in-process provider 复用同一份本地 store（与 claude 的 helper 子进程
            // 读写同一份白板/审批 JSON —— 右栏内联卡片 / 群聊白板对齐）。
            let cb = CodexAppServerBackend(
                executable: executable.path,
                argv: config.argv(),
                cwd: workingDirectory.path,
                env: env,
                model: config.model,
                developerInstructions: developerInstructions,
                mcpServers: codexMcpServers,
                whiteboardProvider: Self.makeWhiteboardProvider(crewId: crewId, sessionId: sessionId),
                approvalProvider: Self.makeApprovalProvider(crewId: crewId, sessionId: sessionId))
            cb.boot(initialPrompt: config.initialPrompt)
            backend = cb
        }
        // 4. 包成 view model
        let run = CrewSessionRun(
            crewId: crewId,
            sessionId: sessionId,
            kind: config.kind,
            taskBrief: taskBrief,
            title: CrewSessionTitle.resolve(explicit: title, brief: taskBrief),
            workingDirectory: workingDirectory,
            model: config.model,
            effort: config.effort,
            permissionModeOverride: config.permissionMode,
            backend: backend,
            serverLink: serverLink,
            role: role
        )
        // 多 run 并存：追加 + 选中，不动旧 run（每个 run 在切换条上都有自己的
        // 停止/移除入口，不会变 orphan）。选中只抢**本 crew**的前台（#481）——
        // 别的 crew 起的 run（机长唤醒 / start_session / 远程排队）记到它自己的
        // pane 态里，等用户切过去时选中，不打断当前 crew 的右栏。
        runs.append(run)
        if activeCrewId == nil || crewId == activeCrewId {
            selectedRunId = run.runID
            isComposingNew = false
        } else {
            var st = paneStates[crewId] ?? PaneState()
            st.selectedRunId = run.runID
            st.isComposingNew = false
            paneStates[crewId] = st
        }
        // 撞额度上限（健康感知首报）→ 自动挂重置唤醒（用户定调:hit limit 才挂钩）。
        run.onUsageLimit = { [weak self] r in self?.autoScheduleQuotaWakeup(for: r) }
        persistSessionsSnapshot()   // 新成员立刻进机长的点名快照
        // 本地 crew:把 worker session 登记成持久成员（成员列表/@ 名单退出后不丢）。
        // captain 已作为 captain 成员在 roster 里,不重复登记;登录态 crew 的
        // membership 归 edge(H1 迁移),store 里查无此 crew → no-op。
        if role != .captain {
            LocalCrewStore.shared.recordSessionMember(
                crewId: crewId, sessionId: sessionId, displayName: run.displayName)
        }
    }

    // MARK: - codex backend providers

    /// codex 每轮 turn 前注入未读白板的 provider —— 复用 claude PostToolUse hook 的
    /// 同一份 `HookEmitter`（per-session 游标读未读 + 渲染 + 推进游标），区别只是
    /// 这里在 app 进程内直接调，不经 helper 子进程。返回的字符串作为 `turn/start`
    /// 的首条 text input 前置注入。无未读 → nil（不注入）。best-effort：
    /// 任何失败（store 读不出 / 渲染失败）→ nil，turn 照常跑（只是这轮没白板）。
    nonisolated static func makeWhiteboardProvider(crewId: String, sessionId: String) -> () -> String? {
        let dir = LocalWhiteboardStore.defaultDirectory
        return {
            let emitter = HookEmitter(
                store: LocalWhiteboardStore(directory: dir),
                crewId: crewId, sessionId: sessionId, cursorDir: dir)
            // HookEmitter 吐的是 claude hook 信封 JSON；codex 这边只要里头的纯文本
            // additionalContext，剥一层拿渲染好的未读串。
            guard let json = emitter.emitAndAdvance(),
                  let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hook = obj["hookSpecificOutput"] as? [String: Any],
                  let ctx = hook["additionalContext"] as? String, !ctx.isEmpty
            else { return nil }
            return ctx
        }
    }

    /// codex 审批 provider —— 镜像 `McpPermissionHook` 的 raise→long-poll→answer，
    /// 但在 app 进程内异步等（不阻塞线程）。codex 经 server request 发来审批，
    /// 这里 raise 一条 `permission` 待审批（归档在本 sessionId 下，右栏内联卡片
    /// 据此过滤）+ 通知半边贴本地白板，再 poll `LocalApprovalStore` 直到人类在待审批
    /// 列表 allow/deny。映射：allow→"accept"，deny / 超时→"decline"（安全侧 fail-safe）。
    /// 超时取 `McpPermissionHook` 一样保守的兜底（v1 不设硬等人上限，但 in-process
    /// 异步等设一个长上限防 turn 永久挂死）。
    nonisolated static func makeApprovalProvider(
        crewId: String, sessionId: String
    ) -> (_ summary: String, _ decisions: [String]) async -> String {
        let dir = LocalWhiteboardStore.defaultDirectory
        return { summary, decisions in
            let approvals = LocalApprovalStore(directory: dir)
            let board = LocalWhiteboardStore(directory: dir)
            let reqId = approvals.raise(
                crewId: crewId, kind: "permission", sessionId: sessionId, summary: summary)
            // 通知半边（与 McpPermissionHook 一致）：贴本地群聊白板，人类在 crew chat
            // 看得见有新审批请求。
            board.appendSessionMessage(
                crewId: crewId, sessionId: sessionId,
                text: "🔔 待审批：\(summary)\n（请在 PendingCrew 待审批列表里 allow / deny）",
                category: "question")
            // long-poll：0.5s 一拍，最多等 ~30min 后保守判 deny（防 turn 永久挂）。
            let pollInterval: UInt64 = 500_000_000 // 0.5s
            let maxWaits = 3600
            var waits = 0
            let chosen: String = await {
                while waits < maxWaits {
                    if let it = approvals.item(crewId: crewId, id: reqId), it.status == "answered" {
                        return it.decision == "allow" ? "allow" : "deny"
                    }
                    try? await Task.sleep(nanoseconds: pollInterval)
                    waits += 1
                }
                return "deny" // 超时 → 安全侧拒绝
            }()
            // 映射到 codex decision —— allow→accept，其余→decline（若 codex 没声明
            // accept/decline 而是别的可选项，退回它声明的第一个/末一个作 fail-safe）。
            if chosen == "allow" {
                return decisions.contains("accept") ? "accept" : (decisions.first ?? "accept")
            } else {
                return decisions.contains("decline") ? "decline" : (decisions.last ?? "decline")
            }
        }
    }

    enum RunnerError: LocalizedError {
        case toolNotInstalled(kind: LocalCodingAgentKind)
        case captainNoWorkingDirectory

        var errorDescription: String? {
            switch self {
            case .toolNotInstalled(let kind):
                return "未在 PATH 中找到 \(kind.binaryName)，请先安装 \(kind.displayName) CLI。"
            case .captainNoWorkingDirectory:
                return "这个 crew 没有工作目录 —— 在建 crew 时设置后再启动 Captain。"
            }
        }
    }

    /// 启动机长 session —— 手动按钮、建 crew 自动起共用这一份（单一事实源）。
    /// 已有在跑的 captain 直接返回（每 crew 同时只允许一个，防重）。无工作目录抛错。
    ///
    /// captain 与 worker 的差异只有两点：世界观后追加 captain persona
    /// （`crew-captain.zh.md`），MCP helper 带 `--captain` 解锁 answer_decision
    /// （chunk2 §2）。机长是调度者不改代码 —— 直接用 crew 目录，不开 isolation worktree。
    /// `initialPrompt` 只让它用 `post_to_crew` 报到一句 ——「建 crew 即在群里发消息」
    /// 走这条（不另写代码发系统消息，保持白板由 agent 自己写的一致语义）。报到之外
    /// 不预先指派任何动作：世界观/白板已随 system prompt 注入，待决策会另行通知，无需
    /// 在开场 prompt 里堆"先读白板再待命"那套（用户定调：报到就行，别搞乱七八糟的）。
    /// 渲染世界观要 roster → 用传入的 `backend` 拉（best-effort，失败照样启动）。
    /// `wakeText` 非 nil = 这次拉起是因为有人 @ 机长而机长没在跑（@ 唤醒语义：
    /// 不在跑就真拉起来,不只留白板）——开场 prompt 带上那条消息,报到后直接处理。
    func startCaptain(detail: CrewDetail, backend: PendingCrewBackend?,
                      wakeText: String? = nil) async throws {
        let crewId = detail.crew.id
        guard !runs.contains(where: {
            $0.crewId == crewId && $0.role == .captain && $0.status == .running
        }) else { return }
        // Keep single captain slot: remove any finished captain runs before starting fresh.
        runs.removeAll { $0.crewId == crewId && $0.role == .captain }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            throw RunnerError.captainNoWorkingDirectory
        }
        let workdir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        let localSessionId = "captain-" + String(UUID().uuidString.lowercased().prefix(8))
        let initialPrompt: String
        if let wakeText {
            initialPrompt = "你是本 crew 的机长。刚有人在群里 @ 你：「\(wakeText)」"
                + "——用 post_to_crew 报到一句,然后处理这条消息。"
        } else {
            initialPrompt = "你是本 crew 的机长，用 post_to_crew 报到一句即可。"
        }
        // persona / members best-effort：加载失败不挡启动（只是少人设/世界观，与 worker 同策略）。
        let persona = try? LocalPromptLoader().rawTemplate(name: "crew-captain", locale: "zh")
        let members = (try? await backend?.listCrewMembers(crewId: crewId))?.members ?? []
        // 机长用建 crew 时选定的 coding agent（crew 没记 → 默认 Codex）。
        let captainKind = LocalCodingAgentKind.captainDefault(detail.crew.captainAgentKind)
        var cfg = SessionConfig(kind: captainKind, initialPrompt: initialPrompt)
        // 世界观 + crew 工具按 kind 分流：claude 走文件 flag（appendSystemPromptFile +
        // settings/mcp-config），codex 走 app-server 通道（developerInstructions 字符串 +
        // mcpServers dict）。captain 两边都带（persona 追加 + helper `--captain` 解锁
        // answer_decision）。**默认 captain = codex**（captainDefault），所以 codex 这支必须接对，
        // 否则机长无世界观、无 crew 工具。
        var developerInstructions: String? = nil
        var codexMcpServers: [String: Any]? = nil
        switch captainKind {
        case .claudeCode:
            cfg.appendSystemPromptFile = LocalSessionLaunch.renderWorldModelFile(
                detail: detail, members: members, taskBrief: initialPrompt, workdir: workdir,
                sessionId: localSessionId, runnerKind: captainKind, appendPersona: persona)
            let comms = LocalSessionLaunch.prepareLocalCommsConfig(
                crewId: crewId, sessionId: localSessionId, captain: true, label: "机长")
            cfg.settingsFile = comms.settings
            cfg.mcpConfigFile = comms.mcp
        case .codex:
            developerInstructions = LocalSessionLaunch.renderWorldModelString(
                detail: detail, members: members, taskBrief: initialPrompt, workdir: workdir,
                sessionId: localSessionId, appendPersona: persona)
            codexMcpServers = LocalSessionLaunch.codexMcpServers(
                crewId: crewId, sessionId: localSessionId, captain: true, label: "机长")
        }
        try await start(
            crewId: crewId,
            sessionId: localSessionId,
            config: cfg,
            workingDirectory: workdir,
            taskBrief: initialPrompt,
            developerInstructions: developerInstructions,
            codexMcpServers: codexMcpServers,
            role: .captain
        )
    }

    /// 起一个 worker session 执行机长派发的 brief。两条来路共用：驾驶舱控制半边（cockpit.md，
    /// 看差 → 真起 worker 补差）和机长 `start_session` 工具。复用 captain 同一套世界观 + comms
    /// 接线，区别：无 persona 追加、`role: .worker`、helper 不带 `--captain`（captain:false，不解锁
    /// answer_decision）。kind / workdir 可被机长的命令参数覆盖：
    /// - `runnerOverride` 非 nil → 强制用它（机长命令里的 `runner: "claude"/"codex"`），
    ///   否则跟 crew 的 `captainAgentKind` 默认一致（`captainDefault`）。
    /// - `isolation` → 经 `SessionWorkspace.resolve` 决定共享 crew 目录还是开独立 worktree
    ///   （worker 改代码可能要隔离，机长调度不改代码所以 `startCaptain` 恒不隔离）。
    func startForBrief(
        detail: CrewDetail, backend: PendingCrewBackend?, brief: String,
        runnerOverride: LocalCodingAgentKind? = nil, isolation: Bool = false,
        model: String? = nil, effort: String? = nil, title: String? = nil
    ) async throws {
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            throw RunnerError.captainNoWorkingDirectory
        }
        let baseDir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        let workdir = SessionWorkspace.resolve(crewDirectory: baseDir, isolation: isolation, hint: brief)
        let localSessionId = "worker-" + String(UUID().uuidString.lowercased().prefix(8))
        let kind = runnerOverride ?? LocalCodingAgentKind.captainDefault(detail.crew.captainAgentKind)
        try await launchWorker(detail: detail, backend: backend, sessionId: localSessionId,
                               brief: brief, kind: kind, workdir: workdir,
                               model: model, effort: effort, title: title)
    }

    /// @ 唤醒一个**已退出**的持久成员：复用原 sessionId 重启（白板读游标 / 成员
    /// 登记 / 审批归档全延续 —— 新进程第一轮就把停摆期间的未读白板接上，群记忆
    /// 不断片；agent 自己的终端上下文不恢复，这是本地 v1 的边界）。kind 从成员
    /// 显示名反推（登记时没单存 kind），推不出落回 crew 默认；在 crew 共享目录跑
    /// （当初若开过 isolation worktree 没持久化，不恢复）。已在跑 → no-op
    /// （在跑的归注入路径管）。
    func restartMember(detail: CrewDetail, backend: PendingCrewBackend?,
                       member: LocalSessionMember, wakeText: String) async throws {
        guard !runs.contains(where: {
            $0.sessionId == member.sessionId && $0.status == .running
        }) else { return }
        // 清掉同 id 的旧已退 run —— 切换条 / 点名快照不留重影。
        runs.removeAll { $0.sessionId == member.sessionId }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            throw RunnerError.captainNoWorkingDirectory
        }
        let workdir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        let kind = LocalCodingAgentKind.inferred(fromDisplayName: member.displayName)
            ?? LocalCodingAgentKind.captainDefault(detail.crew.captainAgentKind)
        let brief = "有人在群里 @ 你：「\(wakeText)」。你是本 crew 的既有成员"
            + "「\(member.displayName)」,此前群里的上下文在白板里(每轮自动注入),接着处理这条。"
        try await launchWorker(detail: detail, backend: backend, sessionId: member.sessionId,
                               brief: brief, kind: kind, workdir: workdir,
                               model: nil, effort: nil, title: member.displayName)
    }

    /// worker 启动共用体（startForBrief 新起 / restartMember 复用原 id 两条来路）。
    /// `title` = 精简标题（单一真值）：既作 helper `--label`（post_to_crew 白板署名），
    /// 又落到 run.title（群聊/成员列表主名）—— 三处同一值。nil = 从 brief 兜底 derive；
    /// 重启成员传原成员名以延续身份。
    private func launchWorker(
        detail: CrewDetail, backend: PendingCrewBackend?, sessionId localSessionId: String,
        brief: String, kind: LocalCodingAgentKind, workdir: URL,
        model: String?, effort: String?, title: String? = nil
    ) async throws {
        let crewId = detail.crew.id
        // 精简标题单一真值：显式 title 优先，否则从 brief 兜底。既当 --label 也当 run.title。
        let resolvedTitle = CrewSessionTitle.resolve(explicit: title, brief: brief)
        // members best-effort：加载失败不挡启动（只是少世界观里的成员名单，与 startCaptain 同策略）。
        let members = (try? await backend?.listCrewMembers(crewId: crewId))?.members ?? []
        var cfg = SessionConfig(kind: kind, model: model, effort: effort, initialPrompt: brief)
        var developerInstructions: String? = nil
        var codexMcpServers: [String: Any]? = nil
        switch kind {
        case .claudeCode:
            cfg.appendSystemPromptFile = LocalSessionLaunch.renderWorldModelFile(
                detail: detail, members: members, taskBrief: brief, workdir: workdir,
                sessionId: localSessionId, runnerKind: kind, appendPersona: nil)
            let comms = LocalSessionLaunch.prepareLocalCommsConfig(
                crewId: crewId, sessionId: localSessionId, captain: false, label: resolvedTitle)
            cfg.settingsFile = comms.settings
            cfg.mcpConfigFile = comms.mcp
        case .codex:
            developerInstructions = LocalSessionLaunch.renderWorldModelString(
                detail: detail, members: members, taskBrief: brief, workdir: workdir,
                sessionId: localSessionId, appendPersona: nil)
            codexMcpServers = LocalSessionLaunch.codexMcpServers(
                crewId: crewId, sessionId: localSessionId, captain: false, label: resolvedTitle)
        }
        try await start(
            crewId: crewId,
            sessionId: localSessionId,
            config: cfg,
            workingDirectory: workdir,
            taskBrief: brief,
            title: resolvedTitle,
            developerInstructions: developerInstructions,
            codexMcpServers: codexMcpServers,
            role: .worker
        )
    }
}

/// 单次 session 的 UI 视图模型。
///
/// agent 跑在后端里（claude = 内嵌真终端；codex = app-server），UI 通过
/// `agentTerminalSession` 有条件地嵌入终端视图。这里只追踪后端进程的
/// running/exited 生命周期，并在结束时关掉 server row。
@MainActor
final class CrewSessionRun: ObservableObject, Identifiable {
    enum Status: Equatable {
        case running
        case completed
        case cancelled
        case failed
    }

    /// session 在 crew 里的角色 —— captain（调度者）/ worker（干活的）。
    /// 切换条展示用，captain 置顶。
    enum Role: Equatable {
        case captain
        case worker
    }

    let runID = UUID()
    let crewId: String
    /// 本 session 的合成 id（BYOK = startSession 生成的 localSessionId；logged =
    /// 服务端 session id）。与 MCP `--session` / 世界观 / `LocalApprovalStore` 条目
    /// 的 sessionId 三处一致 —— 右栏内联待办卡片靠它过滤出本 session 的待决策/待审批。
    let sessionId: String
    let kind: LocalCodingAgentKind
    let taskBrief: String
    /// 精简标题（≤18 字、无项目名）——**单一真值**：群聊气泡名 = 成员列表主名 =
    /// helper `--label` 白板署名，都取它。机长起 session 可经 start_session 传；
    /// 没传就从 `taskBrief` 兜底 derive（`CrewSessionTitle`）。空 = 用 `displayName`
    /// 的 kind+id6 兜底（旧行为）。
    let title: String
    let workingDirectory: URL
    /// 当前生效的 model slug（起 session 时选的，或运行态 `/model` 切换后回写的）。
    /// 运行态切换要能被人面成员卡观察到 → `@Published var`（切换后 `applyProfileChange`
    /// 回写这里，MCP 自切与人面切换共用同一回写路径）。nil = 对应 CLI 默认。
    @Published var model: String?
    /// 当前生效的 thinking effort 档位（同 `model`，运行态切换后回写）。nil = CLI 默认。
    @Published var effort: String?
    /// Spec v2 §10 — session-level override for permission_mode（informational）。
    let permissionModeOverride: String?
    /// captain / worker 角色（切换条展示 + captain 置顶）。
    let role: Role
    let startedAt = Date()

    /// 切换条 / 群聊 / 成员列表统一的显示名：captain 直接叫「机长」；worker 优先用
    /// 精简 `title`（单一真值），没 title 才退回 agent 名 + session id 前缀。
    var displayName: String {
        if role == .captain { return "机长" }
        return title.isEmpty ? kind.displayName + " · " + String(sessionId.prefix(6)) : title
    }

    /// 后端实现（claude = AgentTerminalSession；codex = app-server，按 kind 分流）。
    let backend: any SessionBackend

    /// 类型转换访问：仅当后端是终端（claude）时非 nil，供 `AgentTerminalView` 使用。
    var agentTerminalSession: AgentTerminalSession? { backend as? AgentTerminalSession }

    /// 是否有服务端 session 行（登录态）。事件驱动唤醒（Phase 4b）只对这类 run
    /// 拉 inbox —— BYOK/local-only run（serverLink == nil）没有服务端 mailbox。
    var hasServerSession: Bool { serverLink != nil }

    @Published private(set) var status: Status = .running
    @Published private(set) var exitCode: Int32?
    /// 干活中(跑回合) vs 空闲(存活等指令) —— 镜像后端 `isWorking`，驱动头像/切换条状态点。
    /// (与 backend.isBusy 区分:那个是唤醒注入门禁;这个是 UI 活跃信号,见 SessionBackend。)
    @Published private(set) var isWorking = false
    /// runner 健康异常(未登录/额度到顶) —— 镜像后端 `health`。非 nil 时成员状态点
    /// 转红、成员行副行显示 detail,并往本 crew 白板 fail-loud 一条(每 Kind 一次)。
    @Published private(set) var health: CrewSessionHealth?
    /// 首次撞 usageLimit 时回调（与白板播报同一次去重）——runner 挂上
    /// `autoScheduleQuotaWakeup`,实现「撞墙 → 自动约额度重置唤醒」。
    var onUsageLimit: ((CrewSessionRun) -> Void)?

    /// 用户主动停 → 终端退出时落 `.cancelled` 而非 `.failed`。
    private var cancelled = false
    /// Guards double-finalize.
    private var finalized = false
    /// 已经往白板 fail-loud 过的健康异常 Kind（每 Kind 只喊一次，TUI 重绘不刷屏）。
    private var announcedHealthKinds: Set<CrewSessionHealth.Kind> = []
    /// Server row lifecycle close (logged mode only; nil for BYOK/local-only).
    private let serverLink: CrewSessionServerLink?
    private var statusObservation: Task<Void, Never>?
    private var workingObservation: Task<Void, Never>?
    private var healthObservation: Task<Void, Never>?

    nonisolated var id: UUID { runID }

    init(
        crewId: String,
        sessionId: String,
        kind: LocalCodingAgentKind,
        taskBrief: String,
        title: String = "",
        workingDirectory: URL,
        model: String? = nil,
        effort: String? = nil,
        permissionModeOverride: String? = nil,
        backend: any SessionBackend,
        serverLink: CrewSessionServerLink? = nil,
        role: Role = .worker
    ) {
        self.crewId = crewId
        self.sessionId = sessionId
        self.kind = kind
        self.taskBrief = taskBrief
        // clamp 兜底：无论从哪条来路传进来，落到 run 上的 title 都 ≤18 字、单行。
        self.title = CrewSessionTitle.clamp(title)
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.permissionModeOverride = permissionModeOverride
        self.backend = backend
        self.serverLink = serverLink
        self.role = role
        self.status = Self.map(backend.status, cancelled: false)
        self.isWorking = backend.isWorking
        observeBackendStatus()
        observeBackendWorking()
        observeBackendHealth()
    }

    /// 镜像后端健康异常到 run 上,并往白板 fail-loud（每 Kind 一次）——用户不用
    /// 进终端就知道「claude 没登录 / 额度到顶 / codex token 失效」（分诊第 7 点）。
    private func observeBackendHealth() {
        healthObservation = Task { [weak self] in
            guard let self else { return }
            for await h in self.backend.healthPublisher.values {
                if Task.isCancelled { return }
                self.health = h
                guard let h, !self.announcedHealthKinds.contains(h.kind) else { continue }
                self.announcedHealthKinds.insert(h.kind)
                LocalWhiteboardStore.shared.appendSessionMessage(
                    crewId: self.crewId, sessionId: self.sessionId,
                    text: "⚠️ \(self.displayName) 出问题了：\(h.detail)",
                    category: "error", senderName: self.displayName)
                if h.kind == .usageLimit { self.onUsageLimit?(self) }
            }
        }
    }

    /// 镜像后端 `isWorking`(claude=输出活跃度;codex=turn 进行中)到 run 上,供 UI 观察。
    private func observeBackendWorking() {
        workingObservation = Task { [weak self] in
            guard let self else { return }
            for await working in self.backend.isWorkingPublisher.values {
                if Task.isCancelled { return }
                self.isWorking = working
            }
        }
    }

    /// 跟踪后端的 running/exited，映射到 run 的生命周期 status，并在退出时
    /// finalize（关 server row）。用 `backend.statusPublisher` 的 Combine stream 驱动。
    private func observeBackendStatus() {
        statusObservation = Task { [weak self] in
            guard let self else { return }
            for await backendStatus in self.backend.statusPublisher.values {
                if Task.isCancelled { return }
                switch backendStatus {
                case .running:
                    self.status = .running
                case let .exited(code):
                    self.exitCode = code
                    self.finalize(exitCode: code)
                }
            }
        }
    }

    /// 发文本给 agent（首条指令 / 续聊 / steer）。终端原样接收。
    func send(_ text: String) { backend.send(text) }

    /// 打断进行中的回合（Esc）。
    func interrupt() { backend.interrupt() }

    /// 主动停掉 session（终止子进程）。后端退出后落 `.cancelled`。
    func stop() {
        guard status == .running else { return }
        cancelled = true
        backend.stop()
    }

    deinit {
        statusObservation?.cancel()
        workingObservation?.cancel()
    }

    /// 终端进程退出 —— 落 terminal status + 关 server row。Idempotent。
    private func finalize(exitCode: Int32?) {
        guard !finalized else { return }
        finalized = true
        status = Self.map(.exited(exitCode), cancelled: cancelled)
        isWorking = false
        statusObservation?.cancel()
        workingObservation?.cancel()
        if let link = serverLink {
            let finalStatus = status
            Task { await link.finish(localStatus: finalStatus, summary: nil) }
        }
    }

    /// Map the terminal's running/exited state to the run lifecycle.
    private static func map(_ status: SessionStatus, cancelled: Bool) -> Status {
        switch status {
        case .running:
            return .running
        case let .exited(code):
            if cancelled { return .cancelled }
            return (code ?? 0) == 0 ? .completed : .failed
        }
    }
}
#endif
