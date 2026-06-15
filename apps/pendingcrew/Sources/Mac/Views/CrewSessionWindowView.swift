#if os(macOS)
import SwiftUI

/// 右栏（inspector）：两模式合一。
///
/// - **成员列表模式**（`sessionRunner.viewingTerminal == false`，平时）：顶部
///   ⚓启动 Captain + 「+ 新 session」，下面是待审批区 + crew 成员富列表（session
///   行带简介 + 最新一步动作，可点进终端）。
/// - **终端模式**（`viewingTerminal == true`）：顶部「‹ 成员」返回，下面是原样的
///   session 切换条 + 终端 + composer + 内联审批卡。
///
/// 终端那一层只观察 `CrewSessionRunner.current`（哪个 run 在前台）。具体 run 的
/// status 变化由内层 `SessionRunContentView` 通过 `@ObservedObject` 观察 ——
/// **必须分两层**：`CrewSessionRun` 是嵌套的 ObservableObject，父 view 只
/// `@EnvironmentObject` 持有 runner 时不会订阅到 run 自己的 `@Published`，否则
/// status 更新了 UI 不刷新。
///
/// **重复轮询说明**：成员列表模式这里自己 poll 本 crew 的白板/roster
/// （`listCrewWhiteboard` / `listCrewMembers`），中栏 CrewChatView 也在 poll 同一
/// 份数据 —— 两端各拉各的。v1 单用户低频可接受，未做共享数据层的重构。
struct CrewSessionWindowView: View {
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var crewStore: CrewStore

    @State private var draft = ""
    @State private var starting = false
    @State private var localError: String?
    /// composer 里给「新 worker session」选的 agent kind。初值从 crew 的
    /// `captainAgentKind` 派生（见 `.onAppear` / `.onChange`），crew 没记 → `.codex`。
    @State private var selectedKind: LocalCodingAgentKind = .codex

    // MARK: - 成员列表模式 state（自轮询白板 + roster，与中栏各拉各的）

    /// 本 crew 白板条目（滤出 isInteraction 当待审批，其余拿来取「最新一步动作」）。
    @State private var entries: [CrewWhiteboardEntry] = []
    /// 本 crew server 成员名册。
    @State private var members: [CrewMember] = []
    @State private var captainBotId: String?
    /// 待审批卡的回复草稿，按 permission_request_id 存。
    @State private var replyDrafts: [String: String] = [:]
    private let rosterPollInterval: UInt64 = 3_000_000_000 // 3s
    /// Sessions this app has already claimed+run (or is running), so the
    /// auto-claim loop (K: captain-created queued sessions) doesn't double-run
    /// them. Includes both manual starts and auto-claimed ones.
    @State private var handledSessionIds: Set<String> = []
    /// 未读角标刷新 ticker（chunk2 T6）—— 仅驱动 inspector 里切换条的角标重算
    /// （store 数据在文件里，无 ObservableObject 推送）。captain 唤醒不在这——它
    /// 必须不依赖 inspector 是否打开，已搬到常驻的 CrewCenterView。
    private let badgeTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// 未读角标的轻量刷新计数（chunk2 T6）—— 每个 tick 自增，逼 badgeCount 重算。
    @State private var badgeTick = 0

    /// spec §9.3 + 用户心智：右栏是**常驻**和 claude/codex 交互的面（像 Codex
    /// Desktop）。没有 session 时就地给一个 composer —— **第一条消息即开始
    /// session**（零配置，用 crew 默认目录/runner/权限模式；无标题、无单独的
    /// 「新建」表单）。运行中再发 = 直接把文本注入终端续聊。
    var body: some View {
        Group {
            if sessionRunner.viewingTerminal {
                terminalMode
            } else {
                memberListMode
            }
        }
        // 填满 inspector 栏 —— 内容是弹性的，跟随固定列宽布局，不溢出。
        .frame(maxWidth: .infinity)
        // 无 navigationTitle —— 这是 inspector 内容,标题会漏到主窗标题栏(显成
        // "Session" 盖掉 crew 名)。窗标题由中栏 toolbar 的 crew 名负责。
        // K (edge→Mac channel): for the selected crew, auto-claim + run sessions
        // the captain queued on the server (status='queued'). local_host = this
        // Mac is the executor; the captain just creates the queued row on edge.
        .task(id: crewStore.selectedDetail?.crew.id) { await autoClaimLoop() }
        // 成员列表模式要的白板/roster 数据 —— 自轮询（与中栏各拉各的，见类型注释）。
        .task(id: crewStore.selectedDetail?.crew.id) { await rosterPollLoop() }
        // 未读角标随 ticker 刷新（T6）。captain 唤醒已移到 CrewCenterView。
        .onReceive(badgeTimer) { _ in
            badgeTick &+= 1
        }
        // 切前台 = 看过了：清掉新选中 run 的未读（T6）。
        .onChange(of: sessionRunner.selectedRunId) { _, newId in
            if let run = sessionRunner.runs.first(where: { $0.runID == newId }) {
                SessionUnreadStore.shared.markViewed(run.sessionId)
            }
        }
        // composer 的 agent kind 默认跟随 crew 建好时选的 captainAgentKind ——
        // 初次出现 + 切 crew 都重算（crew 没记 → `.codex`）。
        .onAppear { selectedKind = Self.resolveAgentKind(crewStore.selectedDetail) }
        .onChange(of: crewStore.selectedDetail?.crew.id) { _, _ in
            selectedKind = Self.resolveAgentKind(crewStore.selectedDetail)
        }
    }

    /// 把 crew 的 `captainAgentKind`（"claude_code" / "codex"）映射成
    /// `LocalCodingAgentKind`；缺省 / nil / 未知值 → `.codex`（机长默认 Codex）。
    static func resolveAgentKind(_ detail: CrewDetail?) -> LocalCodingAgentKind {
        LocalCodingAgentKind.captainDefault(detail?.crew.captainAgentKind)
    }

    // MARK: - 终端模式（原样保留：切换条 + 终端 + composer + 审批卡）

    private var terminalMode: some View {
        HStack(spacing: 0) {
            // 左侧成员头像竖条 —— 始终保留(含新建 session 占位),当前 session/新建态高亮。
            terminalRail
            Divider()
            terminalContent
        }
    }

    /// 终端模式左侧的成员头像竖条:顶「‹」回成员列表;成员头像(session 可点切换,
    /// 选中高亮);末尾「+」起新 session(新建态时「+」高亮)。
    private var terminalRail: some View {
        VStack(spacing: 0) {
            Button { sessionRunner.viewingTerminal = false } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 10)
            .help("返回成员列表")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(memberRowItems) { railAvatar($0) }
                    // 新建 session 占位 —— composing 时高亮,代表"正在建的那个 session"。
                    Button {
                        sessionRunner.composeNew()
                        sessionRunner.viewingTerminal = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(sessionRunner.isComposingNew
                                              ? Theme.Palette.accentBg : .clear))
                            .overlay(
                                Circle().strokeBorder(
                                    Theme.Palette.inkMuted.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                    .help("起一个新 session")
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 52)
    }

    @ViewBuilder
    private func railAvatar(_ item: MemberRowItem) -> some View {
        let isSelected = item.run != nil
            && item.run?.runID == sessionRunner.selectedRunId && !sessionRunner.isComposingNew
        let av = CrewAvatarBadges(sender: item.sender, size: 34)
            .padding(3)
            .background(Circle().fill(isSelected ? Theme.Palette.accentBg : .clear))
        if let run = item.run {
            Button { sessionRunner.select(run.runID) } label: { av }
                .buttonStyle(.plain)
                .help(item.sender.displayName)
        } else {
            av.help(item.sender.displayName)
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            if sessionRunner.isComposingNew {
                // 「新建 session」态：显零配置启动面（composer 在下方）。
                idleState
            } else if let run = sessionRunner.current {
                // `.id(run.runID)` 强制换 run 时整个终端视图重建。
                SessionRunContentView(run: run)
                    .id(run.runID)
                SessionApprovalCardsView(crewId: run.crewId, sessionId: run.sessionId)
            } else {
                idleState
            }
            Divider()
            composer
        }
    }

    // MARK: - 成员列表模式（平时：启动入口 + 待审批 + 成员富列表）

    private var memberListMode: some View {
        VStack(spacing: 0) {
            // 顶部：⚓启动 Captain + 「+ 新 session」。
            if crewStore.selectedDetail != nil {
                memberListHeader
                Divider()
            }
            // 启动 Captain 失败原因（含「未在 PATH 中找到 codex/claude」「无工作目录」）——
            // 按钮就在这屏，错误必须在这显，否则点了像没反应。
            if let err = sessionRunner.lastStartError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !pendingInteractions.isEmpty {
                        approvalsSection
                        Divider()
                    }
                    memberSection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if crewStore.selectedDetail == nil {
                Text("先在左侧选一个 crew").foregroundStyle(.secondary)
            }
        }
    }

    private var memberListHeader: some View {
        HStack(spacing: 6) {
            if !hasRunningCaptain {
                Button {
                    Task { await startCaptain() }
                } label: {
                    Text("⚓ 启动 Captain")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .controlSize(.small)
                .disabled(starting)
                .help("起一个机长 session：读白板、报到、答复待决策")
            }
            Spacer()
            Button {
                sessionRunner.composeNew()
                sessionRunner.viewingTerminal = true
            } label: {
                Label("新 session", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(starting)
            .help("起一个新 session（与在跑的并存）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 时间线里需要人答的交互卡 —— 滤出来挂待审批区（从中栏搬来）。
    private var pendingInteractions: [CrewWhiteboardEntry] {
        entries.filter { $0.isInteraction }
    }

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("待审批 \(pendingInteractions.count)")
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.amber)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            VStack(spacing: 8) {
                ForEach(pendingInteractions) { entry in
                    let reqId = entry.payload?.permissionRequestId ?? entry.id
                    CrewInteractionCard(
                        entry: entry,
                        reply: Binding(get: { replyDrafts[reqId] ?? "" },
                                       set: { replyDrafts[reqId] = $0 })
                    ) { Task { await answer(reqId) } }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: 成员富列表

    /// 本 crew 的本地 PTY run —— 列进成员列表（session 行可点进终端）。
    private var memberSessionRuns: [CrewSessionRun] {
        sessionRunner.runs.filter { $0.crewId == crewStore.selectedDetail?.crew.id }
    }

    private var memberSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("成员 \(memberRowItems.count)")
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            LazyVStack(spacing: 1) {
                ForEach(memberRowItems) { memberRow($0) }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 成员行统一模型：server 成员（去掉已有本地 run 的 code_session）+ 本地 run。
    private struct MemberRowItem: Identifiable {
        let id: String
        let sender: GroupBubbleSender
        /// 非 nil = 本地 session run，可点进终端 + 显简介/最新动作。
        let run: CrewSessionRun?
    }

    private var memberRowItems: [MemberRowItem] {
        let runSessionIds = Set(memberSessionRuns.map { $0.sessionId })
        // 有在跑的 captain run 时，server 的 captain 成员收敛成那条可点的 run 行 ——
        // 否则会重复出现「机长」(不可点) + 「Captain」(可点) 两条（用户要"点头像进
        // session"，留一条带星标可点的即可）。
        let hasCaptainRun = memberSessionRuns.contains { $0.role == .captain }
        let serverRows = members
            .filter { m in
                // code_session 成员已有本地 run 的 → 去重（用 run 行）。
                if m.memberKind == "code_session",
                   m.codeSessionId.map(runSessionIds.contains) ?? false { return false }
                // captain 成员在有在跑 captain run 时 → 去重（用 run 行）。
                if hasCaptainRun,
                   m.memberKind == "captain" || (m.botId != nil && m.botId == captainBotId) {
                    return false
                }
                return true
            }
            .map { MemberRowItem(id: $0.id, sender: groupSenderFor($0), run: nil) }
        let runRows = memberSessionRuns.map {
            MemberRowItem(id: "run-\($0.sessionId)", sender: senderForRun($0), run: $0)
        }
        return serverRows + runRows
    }

    @ViewBuilder
    private func memberRow(_ item: MemberRowItem) -> some View {
        if let run = item.run {
            // session 行：富行 —— 头像 + 名 + 简介 + 最新一步动作，点进终端。
            Button {
                sessionRunner.select(run.runID)
                sessionRunner.viewingTerminal = true
            } label: {
                sessionRowContent(sender: item.sender, run: run)
            }
            .buttonStyle(.plain)
            .help("打开这个 session 的终端")
        } else {
            // captain / human 行：只头像 + 名。
            HStack(spacing: 8) {
                CrewAvatarBadges(sender: item.sender, size: 26)
                Text(item.sender.displayName)
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private func sessionRowContent(sender: GroupBubbleSender, run: CrewSessionRun) -> some View {
        let isSelected = run.runID == sessionRunner.selectedRunId
        HStack(alignment: .top, spacing: 8) {
            CrewAvatarBadges(sender: sender, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.taskBrief.isEmpty ? "新 session" : run.taskBrief)
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text(latestStep(for: run))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.Palette.accentBg : .clear)
        )
        .contentShape(Rectangle())
    }

    /// session 行的「最新一步动作」：取本地白板里该 session 最近一条消息的文本；
    /// 没有就退回 run 状态（running / 已退出）。
    /// **尾巴**：只有走 `post_to_crew` 写进白板的进展才拿得到 —— 纯终端 stdout
    /// （没 post_to_crew）这里看不到，退回状态展示。
    private func latestStep(for run: CrewSessionRun) -> String {
        if let last = LocalWhiteboardStore.shared
            .list(crewId: run.crewId)
            .last(where: { $0.senderSessionId == run.sessionId }) {
            return last.text
        }
        return run.status == .running ? "running" : "已退出"
    }

    /// server 成员 → GroupBubbleSender（与 CrewRosterBar 同映射，头像一致）。从中栏搬来。
    private func groupSenderFor(_ m: CrewMember) -> GroupBubbleSender {
        let isCaptain = m.memberKind == "captain" || (m.botId != nil && m.botId == captainBotId)
        let isSession = m.memberKind == "code_session"
        let isHuman   = m.memberKind == "human"
        let seed = m.botId ?? m.userId ?? m.codeSessionId ?? m.id
        let name: String = {
            if let n = m.displayName, !n.isEmpty { return n }
            if isCaptain { return "机长" }
            if isHuman   { return "我" }
            if isSession { return "session" }
            return "bot"
        }()
        return GroupBubbleSender(
            kind: isHuman ? .user : .bot, id: seed, displayName: name,
            avatarPath: nil, avatarSeed: seed, isCaptain: isCaptain,
            sessionStatus: m.sessionStatus, isSession: isSession)
    }

    /// 本地 run → session 头像 sender（状态点 running=绿/退出=灰）。从中栏搬来。
    /// captain run 带星标（isCaptain）+ captainBotId 作头像 seed —— 与 server
    /// captain 成员头像视觉一致（去重后这条是唯一的机长行）。
    private func senderForRun(_ run: CrewSessionRun) -> GroupBubbleSender {
        let isCaptain = run.role == .captain
        return GroupBubbleSender(
            kind: .bot, id: run.sessionId,
            displayName: run.displayName,
            avatarPath: nil,
            avatarSeed: isCaptain ? (captainBotId ?? run.sessionId) : run.sessionId,
            isCaptain: isCaptain,
            sessionStatus: run.status == .running ? "running" : "exited", isSession: true)
    }

    // MARK: - 成员列表模式数据轮询 + 答复

    /// 3s 轮询本 crew 的白板（取待审批 + 最新动作）和 roster。与中栏 CrewChatView
    /// 各拉各的（见类型注释，v1 可接受）。
    private func rosterPollLoop() async {
        entries = []
        members = []
        while !Task.isCancelled {
            await refreshRoster()
            try? await Task.sleep(nanoseconds: rosterPollInterval)
        }
    }

    private func refreshRoster() async {
        guard let crewId = crewStore.selectedDetail?.crew.id,
              let backend = appModel.backend else { return }
        if let wb = try? await backend.listCrewWhiteboard(crewId: crewId) {
            entries = wb
        }
        if let roster = try? await backend.listCrewMembers(crewId: crewId) {
            members = roster.members
            captainBotId = roster.captainBotId
        }
    }

    private func answer(_ reqId: String) async {
        let reply = (replyDrafts[reqId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, let api = try? appModel.loggedAPIClient() else { return }
        do {
            try await api.answerInteraction(reqId: reqId, reply: reply)
            replyDrafts[reqId] = nil
            await refreshRoster()
        } catch {
            localError = error.localizedDescription
        }
    }

    /// composer 是否处于「续聊当前 run」态（反之 = 起新 session 态）。
    /// 新建态、无 run、当前 run 已退出，都算起新 session。
    private var isContinuing: Bool {
        !sessionRunner.isComposingNew && sessionRunner.current?.status == .running
    }

    // MARK: - session bar (chunk2 T2)

    /// 当前选中 crew 的 runs，captain 置顶，其余按启动顺序。
    private var barRuns: [CrewSessionRun] {
        let crewId = crewStore.selectedDetail?.crew.id
        let runs = sessionRunner.runs.filter { $0.crewId == crewId }
        return runs.filter { $0.role == .captain } + runs.filter { $0.role != .captain }
    }

    /// 未读数（chunk2 T6）：本 session 的 pending 待办 + 上次查看后该 session
    /// 发的白板消息。`badgeTick` 由 2s 轮询 bump，强制重算（store 数据在文件里，
    /// 没有 ObservableObject 推送）。前台选中的 run 不显角标（看着呢）。
    private func badgeCount(for run: CrewSessionRun) -> Int {
        _ = badgeTick // 依赖 tick，让 SwiftUI 每 2s 重算一次
        if run.runID == sessionRunner.selectedRunId { return 0 }
        return SessionUnreadStore.shared.unreadCount(
            crewId: run.crewId, sessionId: run.sessionId,
            approvals: .shared, whiteboard: .shared)
    }

    /// 横向滚动的 session 切换条：每个 run 一个 capsule（名字 + 状态点 +
    /// 未读 badge 占位），点击切前台；已退出的带 ✕ 可移除。
    /// 选中 crew 是否已有在跑的 captain run（启动按钮的显隐 + startCaptain 防重）。
    private var hasRunningCaptain: Bool {
        guard let crewId = crewStore.selectedDetail?.crew.id else { return false }
        return sessionRunner.runs.contains {
            $0.crewId == crewId && $0.role == .captain && $0.status == .running
        }
    }

    private var sessionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if crewStore.selectedDetail != nil && !hasRunningCaptain {
                    Button {
                        Task { await startCaptain() }
                    } label: {
                        Text("⚓ 启动 Captain")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                    .controlSize(.small)
                    .disabled(starting)
                    .help("起一个机长 session：读白板、报到、答复待决策")
                }
                ForEach(barRuns) { run in
                    SessionBarItemView(
                        run: run,
                        isSelected: !sessionRunner.isComposingNew && run.runID == sessionRunner.selectedRunId,
                        badgeCount: badgeCount(for: run),
                        select: { sessionRunner.select(run.runID) },
                        remove: { sessionRunner.remove(run.runID) }
                    )
                }
                // 「+」起一个新 session（不动在跑的 run）。选中态高亮。
                Button { sessionRunner.composeNew() } label: {
                    Label("新 session", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(sessionRunner.isComposingNew ? .accentColor : nil)
                .controlSize(.small)
                .disabled(starting)
                .help("起一个新 session（与在跑的并存）")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            if crewStore.selectedDetail == nil {
                Text("先在左侧选一个 crew").foregroundStyle(.secondary)
            } else {
                Text("给 agent 下第一条指令，开始一个 session")
                    .foregroundStyle(.secondary)
                Text("用 crew 的默认工作目录与权限模式，无需任何配置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let localError {
                Text(localError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if !isContinuing {
                    Picker("", selection: $selectedKind) {
                        Text("Claude Code").tag(LocalCodingAgentKind.claudeCode)
                        Text("Codex").tag(LocalCodingAgentKind.codex)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(starting)
                }
                TextField(isContinuing ? "继续对 agent 说…（⌘↩ 发送）" : "下第一条指令开始…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(starting || crewStore.selectedDetail == nil)
                    .onSubmit { Task { await send() } }
                Button {
                    Task { await send() }
                } label: {
                    if starting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(starting || crewStore.selectedDetail == nil
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - actions

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isContinuing, let run = sessionRunner.current {
            // Running session（且非新建态）→ inject the text straight into the
            // embedded terminal (the agent's interactive prompt picks it up).
            run.send(text)
            draft = ""
        } else {
            // 无 run / 已退出 / 新建态 → 开一个新 session。
            await startSession(firstPrompt: text)
        }
    }

    /// Zero-config start: crew default dir + runner kind + permission mode, with
    /// `firstPrompt` as the initial turn. No title, no task brief. Replicates the
    /// logged server-link prep (register host → create → claim) so cross-device
    /// viewers can follow it; BYOK stays local. The first prompt is injected into
    /// the terminal once the agent's REPL is up.
    private func startSession(firstPrompt: String) async {
        guard let detail = crewStore.selectedDetail else { return }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            localError = "这个 crew 没有工作目录 —— 在建 crew 时设置后再开 session。"
            return
        }
        let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        starting = true
        defer { starting = false }
        localError = nil

        // 接合 v2：本地 crew id 不再对应 edge 的 crew 行，server link（跨设备
        // 遥控可跟看）在 block 3（信箱）重建本地↔edge 绑定后再启用 ——
        // 此前恒为 nil，prepareServerSession 保留不删，届时复用。
        let serverLink: CrewSessionServerLink? = nil
        if let sid = serverLink?.sessionId { handledSessionIds.insert(sid) }
        do {
            var cfg = SessionConfig(kind: selectedKind, initialPrompt: firstPrompt)
            // isolation=on → 独立 worktree;off → crew 共享目录（spec §8/§11）。
            let workdir = SessionWorkspace.resolve(
                crewDirectory: dir, isolation: cfg.isolation, hint: firstPrompt)
            // 本地 session 的合成 id —— 世界观 / mcp-config / hook settings 三处一致。
            let localSessionId = serverLink?.sessionId ?? UUID().uuidString.lowercased()
            // 世界观 + comms 接线按 kind 分叉：claude 走文件标志（--append-system-prompt-file
            // / --settings / --mcp-config）；codex 没这些通道 —— 世界观经
            // developerInstructions（字符串）、MCP 经 mcpServers dict 走协议传入。
            // best-effort：渲染失败 nil 不挡 session 启动。
            var codexDevInstructions: String? = nil
            var codexMcp: [String: Any]? = nil
            // worker session 的白板发送者名：agent 名 + 本地 session id 前缀（与
            // CrewSessionRun.displayName 同款），让 post_to_crew 写的白板不再裸 uuid。
            let workerLabel = selectedKind.displayName + " · " + String(localSessionId.prefix(6))
            switch selectedKind {
            case .claudeCode:
                cfg.appendSystemPromptFile = await renderWorldModelFile(
                    detail: detail, taskBrief: firstPrompt, workdir: workdir, sessionId: localSessionId)
                let comms = prepareLocalCommsConfig(
                    crewId: detail.crew.id, sessionId: localSessionId, label: workerLabel)
                cfg.settingsFile = comms.settings
                cfg.mcpConfigFile = comms.mcp
            case .codex:
                codexDevInstructions = await renderWorldModelString(
                    detail: detail, taskBrief: firstPrompt, workdir: workdir, sessionId: localSessionId)
                codexMcp = LocalSessionLaunch.codexMcpServers(
                    crewId: detail.crew.id, sessionId: localSessionId, label: workerLabel)
            }
            try await sessionRunner.start(
                crewId: detail.crew.id,
                sessionId: localSessionId,
                config: cfg,
                workingDirectory: workdir,
                taskBrief: firstPrompt,
                serverLink: serverLink,
                developerInstructions: codexDevInstructions,
                codexMcpServers: codexMcp
            )
            // 指令已在 argv 里(positional prompt)—— 不再等 REPL 就绪 sleep + 事后注入。
            draft = ""
        } catch {
            localError = error.localizedDescription
        }
    }

    /// 手动启动机长（按钮兜底：建 crew 会自动起，这里给"机长退出后重启"用）。
    /// 核心工序在 `CrewSessionRunner.startCaptain` —— 与建 crew 自动起共用一份，
    /// 不分叉（chunk2 T3）。这里只补 view 持有的 starting / localError 反馈。
    private func startCaptain() async {
        guard let detail = crewStore.selectedDetail else { return }
        starting = true
        defer { starting = false }
        // 走 runner 上的共享错误通道（不是 view-local 的 localError）—— 这样错误能在
        // 按钮所在的成员列表模式里显出来，而不是只在终端模式 composer 里（点了像没反应）。
        sessionRunner.lastStartError = nil
        do {
            try await sessionRunner.startCaptain(detail: detail, backend: appModel.backend)
        } catch {
            sessionRunner.lastStartError = error.localizedDescription
        }
    }

    /// 渲染本地世界观 system prompt → 临时 `.md` → 返回路径供
    /// `--append-system-prompt-file`。接合 v2：恒为本地渲染（无 mode 分叉）。
    /// best-effort：任一步失败返 nil，session 仍照常启动（只是没世界观）。
    /// `appendPersona` 非 nil 时（captain session）把 persona 拼到世界观后面 ——
    /// captain 与 worker 的差异只是「追加 persona + --captain 工具门禁」（chunk2 §2）。
    /// 渲染 + comms 接线的实现提取到 `LocalSessionLaunch`（#242：CrewRelayAgent
    /// 自动起 session 与这里走同一份工序）。这俩 wrapper 只补 view 持有的依赖
    /// （backend 拉 members、selectedKind）。
    private func renderWorldModelFile(detail: CrewDetail, taskBrief: String, workdir: URL, sessionId: String,
                                      appendPersona: String? = nil) async -> String? {
        guard let backend = appModel.backend else { return nil }
        let members = (try? await backend.listCrewMembers(crewId: detail.crew.id))?.members ?? []
        return LocalSessionLaunch.renderWorldModelFile(
            detail: detail, members: members, taskBrief: taskBrief, workdir: workdir,
            sessionId: sessionId, runnerKind: selectedKind, appendPersona: appendPersona)
    }

    /// codex 变体：渲染同一份世界观但返回字符串（→ thread/start.developerInstructions），
    /// 不写临时文件。与上面的 file 版同样从 backend 拉 members。best-effort：失败 nil。
    private func renderWorldModelString(detail: CrewDetail, taskBrief: String, workdir: URL, sessionId: String,
                                        appendPersona: String? = nil) async -> String? {
        guard let backend = appModel.backend else { return nil }
        let members = (try? await backend.listCrewMembers(crewId: detail.crew.id))?.members ?? []
        return LocalSessionLaunch.renderWorldModelString(
            detail: detail, members: members, taskBrief: taskBrief, workdir: workdir,
            sessionId: sessionId, appendPersona: appendPersona)
    }

    private func prepareLocalCommsConfig(crewId: String, sessionId: String,
                                         captain: Bool = false,
                                         label: String? = nil) -> (settings: String?, mcp: String?) {
        LocalSessionLaunch.prepareLocalCommsConfig(
            crewId: crewId, sessionId: sessionId, captain: captain, label: label)
    }

    // MARK: - auto-claim (K: captain-created queued sessions)

    /// Poll the crew's server sessions; when something queues one on edge (e.g.
    /// remote control from the phone, status='queued') and this Mac is free,
    /// claim it + run it locally with the crew's working dir. 登录态能力叠加,
    /// gate 用 isAuthenticated。
    /// 接合 v2：本地 crew 与 edge 队列的绑定在 block 3（信箱）重建后再启用 ——
    /// 本地 crew id 目前在 edge 没有对应行，轮询只会空转。loop 保留不删，届时翻开关。
    private var edgeQueueBindingReady: Bool { false }

    private func autoClaimLoop() async {
        guard edgeQueueBindingReady else { return }
        while !Task.isCancelled {
            if appModel.isAuthenticated,
               let detail = crewStore.selectedDetail,
               sessionRunner.current == nil || sessionRunner.current?.status != .running,
               let api = try? appModel.loggedAPIClient(),
               let sessions = try? await api.listCrewSessions(crewId: detail.crew.id) {
                if let queued = sessions.first(where: { $0.status == "queued" && !handledSessionIds.contains($0.id) }) {
                    handledSessionIds.insert(queued.id) // claim-once guard before the await
                    await runQueuedSession(queued, detail: detail, api: api)
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
        }
    }

    /// Claim + run an already-created (captain-queued) session. Mirrors the
    /// manual start but skips createSession (the row already exists).
    private func runQueuedSession(_ s: CrewSessionSummary, detail: CrewDetail, api: PendingCrewAPI) async {
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else { return }
        let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        do {
            let subjects = try await api.listMySubjects()
            guard let subjectId = subjects.first?.id else { return }
            let hostId = try await appModel.ensureRunnerHost(
                api: api,
                subjectId: subjectId,
                allowedRunnerKinds: [
                    LocalCodingAgentKind.claudeCode.serverRunnerKind,
                    LocalCodingAgentKind.codex.serverRunnerKind,
                ]
            )
            _ = try await api.claimSession(runnerHostId: hostId, sessionId: s.id)
            let link = CrewSessionServerLink(api: api, runnerHostId: hostId, sessionId: s.id)
            let kind: LocalCodingAgentKind = s.runnerKind.contains("codex") ? .codex : .claudeCode
            // codex 走 app-server：世界观经 developerInstructions、MCP 经 mcpServers dict
            // 传入（claude 的 hook/settings 文件通道在此 auto-claim 路径本就没接）。
            var codexDevInstructions: String? = nil
            var codexMcp: [String: Any]? = nil
            if kind == .codex {
                codexDevInstructions = await renderWorldModelString(
                    detail: detail, taskBrief: s.taskBrief, workdir: dir, sessionId: s.id)
                let workerLabel = kind.displayName + " · " + String(s.id.prefix(6))
                codexMcp = LocalSessionLaunch.codexMcpServers(
                    crewId: detail.crew.id, sessionId: s.id, label: workerLabel)
            }
            try await sessionRunner.start(
                crewId: detail.crew.id,
                sessionId: s.id,
                config: SessionConfig(kind: kind, initialPrompt: s.taskBrief),
                workingDirectory: dir,
                taskBrief: s.taskBrief,
                serverLink: link,
                developerInstructions: codexDevInstructions,
                codexMcpServers: codexMcp
            )
            // 登录态 run → 接上事件驱动唤醒（Phase 4b）：一个 crew 一条 hub 连接，
            // 收到「该 crew 有动静」→ 拉本 session inbox → 空闲且有@我的项 → 注入唤醒。
            attachMailboxWaker(crewId: detail.crew.id, api: api)
            // taskBrief 已在 argv —— 不再 0.6s sleep + send(brief)。
        } catch {
            localError = "自动认领 session 失败: \(error.localizedDescription)"
            handledSessionIds.remove(s.id) // allow a retry next poll
        }
    }

    /// 登录态 run 起好后接上 crew 的事件驱动唤醒 waker（Phase 4b）。需要
    /// device-grant token + baseURL —— 用 `appModel.imageAuth`（同一对 (baseURL,
    /// token)）取，非登录态返回 nil 时静默跳过（理论上走到这里必登录，防御性）。
    private func attachMailboxWaker(crewId: String, api: PendingCrewAPI) {
        guard let auth = appModel.imageAuth else { return }
        sessionRunner.ensureMailboxWaker(
            crewId: crewId, api: api, baseURL: auth.baseURL, token: auth.token)
    }

    /// `taskBrief` is the session's first instruction — the edge requires a
    /// non-empty brief, and the first message is the natural one (no separate
    /// title/brief form, like Desktop naming a chat by its opening message).
    private func prepareServerSession(detail: CrewDetail, taskBrief: String) async throws -> CrewSessionServerLink {
        let api = try appModel.loggedAPIClient()
        let subjects = try await api.listMySubjects()
        guard let subjectId = subjects.first?.id else {
            throw PendingCrewBackendError.invalidConfig("没有可用的 subject（device grant 未解析出主体）")
        }
        let hostId = try await appModel.ensureRunnerHost(
            api: api,
            subjectId: subjectId,
            allowedRunnerKinds: [
                LocalCodingAgentKind.claudeCode.serverRunnerKind,
                LocalCodingAgentKind.codex.serverRunnerKind,
            ]
        )
        let sessionId = try await api.createSession(
            crewId: detail.crew.id,
            runnerKind: selectedKind.serverRunnerKind,
            taskBrief: taskBrief
        )
        _ = try await api.claimSession(runnerHostId: hostId, sessionId: sessionId)
        return CrewSessionServerLink(api: api, runnerHostId: hostId, sessionId: sessionId)
    }
}

/// 切换条上的单个 session 项。`@ObservedObject` 订阅 run 的 `@Published status`
/// 驱动状态点/✕（嵌套 ObservableObject —— 父 view 观察不到 run 自己的变更）。
private struct SessionBarItemView: View {
    @ObservedObject var run: CrewSessionRun
    let isSelected: Bool
    let badgeCount: Int
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(run.status == .running ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(run.displayName)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            if run.status != .running {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除这个 session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture(perform: select)
    }
}

/// 单个 run 的内容视图。`@ObservedObject` 订阅 run 的 `@Published`（status /
/// exitCode）驱动 header 刷新；内容区按 backend 类型分支：claude 显示
/// `AgentTerminalView`（真终端），codex 显示 `CodexTranscriptView`（结构化 transcript）。
private struct SessionRunContentView: View {
    @ObservedObject var run: CrewSessionRun

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let term = run.agentTerminalSession {
                AgentTerminalView(session: term)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else if let codex = run.backend as? CodexAppServerBackend {
                CodexTranscriptView(transcript: codex.transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.kind == .claudeCode ? "sparkles" : "wand.and.stars")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.kind.displayName)
                    .font(.callout.weight(.semibold))
                if !run.taskBrief.isEmpty {
                    Text(run.taskBrief)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusBadge(run.status, exitCode: run.exitCode)
            if run.status == .running {
                Button(role: .destructive) {
                    run.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(_ status: CrewSessionRun.Status, exitCode: Int32?) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .running: return ("running", .blue)
            case .completed:
                if let code = exitCode {
                    return code == 0 ? ("退出 0", .green) : ("退出 \(code)", .orange)
                }
                return ("已完成", .green)
            case .cancelled: return ("已取消", .secondary)
            case .failed:
                if let code = exitCode {
                    return ("失败 \(code)", .red)
                }
                return ("失败", .red)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
#endif
