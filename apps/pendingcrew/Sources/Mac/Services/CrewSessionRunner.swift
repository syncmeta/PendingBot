#if os(macOS)
import Foundation
import SwiftUI

/// Bridges a local `CrewSessionRun` to its server-side `crew_sessions` row
/// over the T4.5 runner HTTP lifecycle (register → create → claim → events →
/// finish). Logged mode only; BYOK runs pass `nil` and stay purely local.
///
/// **Best-effort**: every server call is `try?`'d — a publish failure (network
/// blip, scope gap, evicted lease) is logged but never disrupts the local
/// agent process. The local run is always the source of truth for the user;
/// the server mirror is a convenience for cross-device viewers.
struct CrewSessionServerLink: Sendable {
    let api: PendingCrewAPI
    let runnerHostId: String
    let sessionId: String

    /// Append one transcript event to the server session log.
    func publish(_ event: RunnerEvent) async {
        let (eventType, visibility) = Self.map(event)
        do {
            _ = try await api.appendSessionEvent(
                runnerHostId: runnerHostId,
                sessionId: sessionId,
                eventType: eventType,
                visibility: visibility,
                summary: SessionState.summarize(event)
            )
        } catch {
            print("[crew-session] append event failed: \(error)")
        }
    }

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

    /// Build the realtime proxy client for this session (runner role). The
    /// WS upgrade reuses the HTTP client's base URL + device-grant bearer; the
    /// route authenticates the bearer and stamps trusted facts onto the DO
    /// upgrade. This is the live sibling of `publish`/`finish` above — where
    /// those mirror the durable transcript, the proxy pushes low-latency
    /// `session.state` and receives remote commands/decisions.
    func makeProxyClient() -> SessionProxyClient {
        SessionProxyClient(
            baseURL: api.baseURL,
            sessionId: sessionId,
            role: .runner,
            token: api.bearerToken
        )
    }

    /// Map a RunnerEvent to the server's (event_type, visibility) enums.
    static func map(_ e: RunnerEvent) -> (String, String) {
        switch e {
        case .started: return ("started", "crew_members")
        case .toolCall: return ("tool_call", "crew_members")
        case .toolResult: return ("tool_result", "crew_members")
        case .reasoning: return ("status", "private_system")
        case .assistant, .finished, .failed, .unknown: return ("status", "crew_members")
        }
    }
}

/// 一次 local coding agent 跑动的 view-side 视图模型。
///
/// 每次 `start(...)` 起一个新 `CrewSessionRun` 并赋给 `current`。
/// 旧的 run 不会自动取消 —— caller 需要先 `current?.cancel()`。MVP
/// 一个窗口只跑一个 run（CreateSessionSheet 起 sheet 前 view 会
/// 给 disabled 提示），多 session tab 留下次。
///
/// P3 stub：会在 P4 接入真实 `MacLocalCodingAgentService`。
@MainActor
final class CrewSessionRunner: ObservableObject {
    @Published private(set) var current: CrewSessionRun?

    /// 注入点 —— 测试时换成 mock impl。默认就是真实现。
    private let service: LocalCodingAgentService

    init(service: LocalCodingAgentService = MacLocalCodingAgentService()) {
        self.service = service
    }

    /// 起一个新 session。pre-flight 失败抛错（工具未装 / cwd 不存在 /
    /// spawn 失败）。成功后立刻把 `current` 切到新 run，return；进程在
    /// 背景跑，stdout/stderr 流式累积到 run 的 @Published 字段。
    func start(
        crewId: String,
        kind: LocalCodingAgentKind,
        workingDirectory: URL,
        taskBrief: String,
        initialPrompt: String,
        /// 用户在 CreateSessionSheet 选的 model slug。Claude Code 会拼成
        /// `--model <slug>`；Codex 暂时只做 metadata（spec v2 §8.1 TODO）。
        /// nil = 让 CLI 用自己的默认。
        model: String? = nil,
        additionalEnv: [String: String] = [:],
        /// Spec v2 §10 — per-session override of the crew's permission
        /// mode. `nil` = inherit crew default (server-side null).
        /// `"auto"` / `"manual"` override just this session. The runner
        /// itself doesn't enforce the mode yet (T4.5 peer_device round-
        /// trip lands the real pause-on-manual behaviour); for now the
        /// value just gets recorded server-side so the crew chat card
        /// + the agent's system prompt see it.
        permissionModeOverride: String? = nil,
        /// spec v2 §10.1 — the CLI permission/sandbox 档 threaded into argv
        /// (claude `--permission-mode` / codex `--sandbox`). Default `.standard`
        /// (= claude `auto`); never nil so headless never falls into the
        /// blocking `default` mode.
        permissionMode: AgentPermissionMode = .standard,
        /// T4.5 — when logged in, the caller prepares a server-side session
        /// (register host → create → claim) and hands the link here so the run
        /// mirrors its transcript to the server. `nil` = BYOK / local-only.
        serverLink: CrewSessionServerLink? = nil
    ) async throws {
        // 1. 校验工具可用
        guard let executable = await service.resolveExecutable(kind) else {
            throw RunnerError.toolNotInstalled(kind: kind)
        }
        let runID = UUID()
        // 2a. T4.5 ambient steering — for a logged Claude session, set up the
        //     out-of-tree hook channel so a viewer can post a standing note that
        //     injects into every turn. Best-effort: a setup failure just means no
        //     ambient steering, the run is otherwise unaffected. BYOK/local + Codex
        //     get no channel (and `--settings` stays off → verified argv).
        var steeringChannel: SteeringChannel? = nil
        if serverLink != nil, kind == .claudeCode {
            steeringChannel = try? SteeringChannel.create(
                parent: SteeringChannel.defaultParent(), sessionId: runID.uuidString)
        }
        // 2a'. T4.5 交互 — for a logged Claude session, set up the ask_human MCP
        //      channel so the agent can raise an interaction (ask the human via
        //      captain→DAG escalation). Needs the bundled server script + the
        //      device-grant token + server session id. Best-effort.
        var interactionChannel: InteractionChannel? = nil
        if let serverLink, kind == .claudeCode,
           let scriptPath = Bundle.main.url(forResource: "ask-human-mcp", withExtension: "cjs")?.path,
           let token = serverLink.api.bearerToken {
            interactionChannel = try? InteractionChannel.create(
                parent: InteractionChannel.defaultParent(),
                sessionId: runID.uuidString,
                serverScriptPath: scriptPath,
                edgeURL: serverLink.api.baseURL.absoluteString,
                token: token,
                edgeSessionId: serverLink.sessionId)
        }
        // 2b. 构造 spec
        let spec = LocalCodingAgentLaunchSpec(
            kind: kind,
            executableURL: executable,
            workingDirectory: workingDirectory,
            taskBrief: taskBrief,
            initialPrompt: initialPrompt,
            model: model,
            additionalEnv: additionalEnv,
            claudeSettingsPath: steeringChannel?.settingsPath,
            claudeMcpConfigPath: interactionChannel?.mcpConfigPath,
            permissionMode: permissionMode
        )
        // 3. 起进程
        let handle = try await service.runSession(runID: runID, spec: spec)
        // 4. 包成 view model + 接 streams
        let run = CrewSessionRun(
            runID: runID,
            crewId: crewId,
            kind: kind,
            taskBrief: taskBrief,
            workingDirectory: workingDirectory,
            model: model,
            permissionModeOverride: permissionModeOverride,
            handle: handle,
            service: service,
            serverLink: serverLink,
            steeringChannel: steeringChannel,
            interactionChannel: interactionChannel
        )
        current = run
        run.observeStreams()
        // 5. v1 stub: 持有 override 在 run 上,等 T4.5 接入 session 创建
        //    HTTP endpoint 时把这个值 PATCH 到 /v1/sessions/:id/permission-mode。
        //    现在还没有 server-side session 行(本机 stub run),所以纯
        //    本地 metadata。
    }

    enum RunnerError: LocalizedError {
        case toolNotInstalled(kind: LocalCodingAgentKind)

        var errorDescription: String? {
            switch self {
            case .toolNotInstalled(let kind):
                return "未在 PATH 中找到 \(kind.binaryName)，请先安装 \(kind.displayName) CLI。"
            }
        }
    }
}

/// 单次 session 的 UI 视图模型。
///
/// stdout/stderr 缓冲为简单的 `String` 累积 —— spec v2 §8.4 说不缓存
/// 全文，但 UI 必须能滚回去看历史，所以 view 这层还是把行流拼成
/// String。**长任务的内存上限留下次**（环形 buffer / 截断头部）。
@MainActor
final class CrewSessionRun: ObservableObject, Identifiable {
    enum Status: Equatable {
        case running
        case completed
        case cancelled
        case failed
    }

    let runID: UUID
    let crewId: String
    let kind: LocalCodingAgentKind
    let taskBrief: String
    let workingDirectory: URL
    /// 用户起 session 时选的 model slug。Run-level metadata，view 层用来
    /// 在 session 窗口展示「模型: claude-sonnet-4-5」之类信息。
    let model: String?
    /// Spec v2 §10 — session-level override for permission_mode.
    /// `nil` = inherit crew default (server-side null). The runner
    /// doesn't enforce the mode locally yet; this field is kept so
    /// the UI can show it and T4.5 has a place to read from when it
    /// wires the runner-side pause-on-manual behaviour.
    let permissionModeOverride: String?
    let startedAt: Date

    @Published private(set) var status: Status = .running
    @Published private(set) var stdoutText: String = ""
    @Published private(set) var stderrText: String = ""
    /// Parsed transcript — each stdout JSONL line is flattened into zero or
    /// more `RunnerEvent`s (see `RunnerEventParser`). This is what the
    /// session window renders by default; `stdoutText` stays as the raw
    /// fallback tab. Claude Code / Codex schemas both collapse into here.
    @Published private(set) var events: [RunnerEvent] = []
    @Published private(set) var exitCode: Int32?
    /// Last remote command received over the proxy socket, for UI surfacing.
    /// `nil` until a cross-device viewer sends one.
    @Published private(set) var lastRemoteCommand: String?
    /// The agent CLI's own session id, captured from the first `.started`
    /// transcript event (claude emits it in its init line). This is what a
    /// `--resume` follow-up turn keys on for T4.5 send_prompt steering — the
    /// agent keeps full context + the cached prefix. nil until the first
    /// started event arrives, or for runners that don't report one (Codex).
    @Published private(set) var agentSessionId: String?

    /// The handle for the **current** turn. A session is normally one turn, but
    /// a remote `send_prompt` runs a `--resume` follow-up turn (T4.5) and this
    /// re-points to it. `cancel()` always targets the in-flight turn.
    private var currentHandle: LocalCodingAgentRunHandle
    /// Service used to spawn `--resume` follow-up turns for send_prompt steering.
    private let service: LocalCodingAgentService
    /// Pending remote steering prompts. A `send_prompt` arriving while a turn is
    /// in flight queues here and drains as `--resume` turns when the turn exits
    /// (see `turnDidExit`). Empty in the common no-steering case → the run
    /// finalizes exactly as the verified one-shot path.
    private var followUpQueue: [String] = []
    /// Set once the session truly ends (queue drained / cancelled). Guards
    /// double-finalize and rejects steering after the session is over.
    private var finalized = false
    /// T4.5 ambient steering channel (logged Claude only). A viewer's standing
    /// note writes here; every turn's `--settings` hook injects it as context.
    /// Torn down when the session ends.
    private let steeringChannel: SteeringChannel?
    /// T4.5 交互 channel (logged Claude only). The session's `ask_human` MCP
    /// server uses it; torn down when the session ends.
    private let interactionChannel: InteractionChannel?
    /// The current standing steering note, surfaced for the viewer UI.
    @Published private(set) var steeringNote: String = ""
    /// T4.5 server mirror (logged mode only; nil for BYOK/local-only runs).
    private let serverLink: CrewSessionServerLink?
    /// T4.5 realtime proxy socket (logged mode only). Built from `serverLink`;
    /// pushes live `session.state` to viewers and receives their commands /
    /// permission decisions. nil for BYOK/local-only runs.
    private let proxyClient: SessionProxyClient?
    private var proxyConnectTask: Task<Void, Never>?
    private var proxyInboundTask: Task<Void, Never>?
    /// Serializes server publishes so transcript events land in stream order
    /// (each publish awaits the previous). Best-effort — see CrewSessionServerLink.
    private var publishChain: Task<Void, Never>?
    private var observeStdoutTask: Task<Void, Never>?
    private var observeStderrTask: Task<Void, Never>?
    private var observeExitTask: Task<Void, Never>?
    /// T4.1/§9.2 — polls the session inbox (whiteboard + mailbox) and writes a
    /// digest into the steering channel's crew-context slot so every turn's hook
    /// injects it. Logged Claude only (needs serverLink + steeringChannel).
    private var crewContextPollTask: Task<Void, Never>?
    private var cancelled = false

    nonisolated var id: UUID { runID }

    init(
        runID: UUID,
        crewId: String,
        kind: LocalCodingAgentKind,
        taskBrief: String,
        workingDirectory: URL,
        model: String? = nil,
        permissionModeOverride: String? = nil,
        handle: LocalCodingAgentRunHandle,
        service: LocalCodingAgentService,
        serverLink: CrewSessionServerLink? = nil,
        steeringChannel: SteeringChannel? = nil,
        interactionChannel: InteractionChannel? = nil
    ) {
        self.runID = runID
        self.crewId = crewId
        self.kind = kind
        self.taskBrief = taskBrief
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionModeOverride = permissionModeOverride
        self.startedAt = Date()
        self.currentHandle = handle
        self.service = service
        self.serverLink = serverLink
        self.steeringChannel = steeringChannel
        self.interactionChannel = interactionChannel
        self.proxyClient = serverLink?.makeProxyClient()
    }

    /// 起后台 task 把 handle 的 stream / exit code 同步进 @Published。
    /// 由 `CrewSessionRunner.start` 在赋给 `current` 后立刻调。
    ///
    /// Task 继承 enclosing MainActor 上下文（CrewSessionRun 是 @MainActor），
    /// 所以 `self.appendStdout` / `self.finish` 是同步调用 —— Swift 编译器会
    /// 警告多余的 await。
    func observeStreams() {
        observe(currentHandle)
        // T4.5 — bring up the realtime proxy socket (logged mode only). Connect
        // publishes session.state live; the inbound loop consumes remote
        // commands / permission decisions on the MainActor.
        if let proxyClient {
            proxyConnectTask = Task { await proxyClient.connect() }
            proxyInboundTask = Task { [weak self] in
                for await frame in proxyClient.inbound {
                    self?.handleRemoteInbound(frame)
                }
            }
        }
        // §9.2 — keep the crew-context slot fed so the agent sees the whiteboard
        // + its unread mailbox on every turn. Logged Claude only.
        if serverLink != nil, steeringChannel != nil {
            crewContextPollTask = Task { [weak self] in await self?.runCrewContextPoll() }
        }
    }

    /// Poll the session inbox and refresh the steering channel's crew-context
    /// slot. Each pass: fetch whiteboard + unread mailbox, build a digest,
    /// inject it, and mark the mailbox items delivered so they don't repeat.
    /// Best-effort throughout — a fetch failure just keeps the prior digest.
    private func runCrewContextPoll() async {
        guard let link = serverLink, let channel = steeringChannel else { return }
        let ownSessionId = link.sessionId
        while !finalized && !cancelled && !Task.isCancelled {
            if let inbox = try? await link.api.getSessionInbox(sessionId: ownSessionId) {
                let digest = Self.buildCrewContextDigest(inbox: inbox, ownSessionId: ownSessionId)
                channel.setCrewContext(digest)
                let mailboxIds = inbox.mailbox.map(\.id)
                if !mailboxIds.isEmpty {
                    _ = try? await link.api.markInboxDelivered(sessionId: ownSessionId, itemIds: mailboxIds)
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
        }
    }

    /// Render the inbox into a compact, agent-facing context block. Excludes the
    /// session's own whiteboard posts (avoid self-echo) and interaction cards
    /// (handled by the ask_human tool round-trip, not as reading material).
    nonisolated static func buildCrewContextDigest(inbox: CrewSessionInbox, ownSessionId: String) -> String {
        func clip(_ s: String) -> String {
            let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 240 ? String(t.prefix(240)) + "…" : t
        }
        func who(_ kind: String, _ sid: String?) -> String {
            switch kind {
            case "user": return "人类"
            case "session": return sid.map { "session·\($0.prefix(6))" } ?? "session"
            case "bot": return "bot"
            default: return kind
            }
        }
        let board = inbox.whiteboard
            .filter { !$0.isInteraction && $0.senderSessionId != ownSessionId }
            .suffix(15)
            .map { "- [\(who($0.senderKind, $0.senderSessionId))] \(clip($0.displayText))" }
        let mail = inbox.mailbox
            .map { "- [\(who($0.senderKind, $0.senderSessionId))] \(clip($0.displayText))" }
        if board.isEmpty && mail.isEmpty { return "" }
        var out = "<crew-whiteboard>\n你所在 crew 的群聊白板（沟通渠道 + 共享上下文）。这是别人留给 crew 的信息，不是你这一轮要做的任务本身——按相关性参考。\n"
        if !mail.isEmpty {
            out += "\n【给你的新消息 / 指令】（请优先关注）\n" + mail.joined(separator: "\n") + "\n"
        }
        if !board.isEmpty {
            out += "\n【白板近况】\n" + board.joined(separator: "\n") + "\n"
        }
        out += "</crew-whiteboard>\n"
        return out
    }

    /// Wire one turn's stdout/stderr/exit into the run. Called for the initial
    /// turn and re-called for each `--resume` follow-up turn (the prior turn's
    /// tasks have already finished, so reusing the task vars is safe — turns are
    /// strictly sequential).
    private func observe(_ handle: LocalCodingAgentRunHandle) {
        let stdoutStream = handle.stdout
        let stderrStream = handle.stderr
        let exitTask = handle.exitCode
        observeStdoutTask = Task { [weak self] in
            for await line in stdoutStream {
                self?.appendStdout(line)
            }
        }
        observeStderrTask = Task { [weak self] in
            for await line in stderrStream {
                self?.appendStderr(line)
            }
        }
        observeExitTask = Task { [weak self] in
            let code = await exitTask.value
            self?.turnDidExit(exitCode: code)
        }
    }

    func cancel() async {
        guard status == .running else { return }
        cancelled = true
        // Drop any queued steering so a cancel doesn't get overtaken by a
        // pending resume turn; cancel targets the in-flight turn.
        followUpQueue.removeAll()
        await currentHandle.cancel()
        // 不在这里把 status 直接改 cancelled —— 等 exitCode 收到，
        // finalize() 会按 cancelled 标志判断是 cancelled 还是 failed。
    }

    /// Queue a remote steering prompt (T4.5 send_prompt). Applied as a
    /// `--resume` follow-up turn when the current turn exits (see `turnDidExit`).
    /// Rejected once the session has finalized or been cancelled — you can only
    /// steer a live session.
    func enqueueFollowUp(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !finalized, !cancelled else {
            print("[crew-session] send_prompt ignored — session already ended")
            return
        }
        guard kind == .claudeCode else {
            print("[crew-session] send_prompt unsupported for \(kind) (resume is Claude-only)")
            return
        }
        followUpQueue.append(trimmed)
    }

    /// Set the ambient standing note (T4.5 set_steering). Persisted to the
    /// steering channel so every turn's `--settings` hook injects it; empty
    /// clears it. Takes effect from the next turn (a turn already in flight
    /// keeps its snapshot). No-op without a channel (BYOK/local/Codex).
    func setSteeringNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        steeringNote = trimmed
        steeringChannel?.setNote(trimmed)
        print("[crew-session] ambient steering note " + (trimmed.isEmpty ? "cleared" : "set (\(trimmed.count) chars)"))
    }

    deinit {
        observeStdoutTask?.cancel()
        observeStderrTask?.cancel()
        observeExitTask?.cancel()
        crewContextPollTask?.cancel()
        proxyConnectTask?.cancel()
        proxyInboundTask?.cancel()
        // Close the socket if the run is torn down before finish() ran (e.g.
        // window dismissed mid-run). close() is idempotent + best-effort.
        if let proxyClient {
            Task { await proxyClient.close() }
        }
        // Clean up the steering hook dir if finalize() never ran.
        steeringChannel?.teardown()
        interactionChannel?.teardown()
    }

    // MARK: - private mutators

    private func appendStdout(_ line: String) {
        if !stdoutText.isEmpty { stdoutText.append("\n") }
        stdoutText.append(line)
        // Parse the same line into transcript events. One JSONL line can
        // yield 0..n events; noise drops to none. Kept append-only so the
        // window's @Published subscription drives incremental rendering.
        let parsed = RunnerEventParser.parse(line: line, kind: kind)
        if !parsed.isEmpty {
            events.append(contentsOf: parsed)
            captureAgentSessionId(from: parsed)
            publishToServer(parsed)
            publishStateToProxy()
        }
    }

    /// Latch the agent's session id from the first `.started` event that
    /// carries one. Stable across resume turns (claude reuses the id), so we
    /// only take the first.
    private func captureAgentSessionId(from parsed: [RunnerEvent]) {
        guard agentSessionId == nil else { return }
        for case let .started(_, sid?) in parsed where !sid.isEmpty {
            agentSessionId = sid
            return
        }
    }

    /// Push the run's current state over the realtime proxy (logged mode only).
    /// Best-effort + fire-and-forget — the client only sends when subscribed
    /// and a failure never affects the local run. Each parsed line publishes
    /// the latest state; the client also re-publishes it on reconnect.
    private func publishStateToProxy() {
        guard let proxyClient else { return }
        let state = SessionState.from(status: Self.wireStatus(status), events: events)
        Task { await proxyClient.publish(state) }
    }

    /// Map the local lifecycle to the wire status SessionState carries. Mirrors
    /// CrewSessionServerLink.finish's mapping (running stays running).
    static func wireStatus(_ status: Status) -> String {
        switch status {
        case .running: return "running"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    /// Handle a runner-actionable frame from a cross-device viewer.
    ///
    /// - `cancel` → `cancel()`: stop a runaway session from any device.
    /// - `send_prompt` → `enqueueFollowUp`: inject a steering instruction that
    ///   runs as a `--resume` follow-up turn (payload `{ "text": "…" }`).
    /// - `permission.decision` is not yet routed to a paused action (manual-mode
    ///   pause/resume is a separate follow-up).
    private func handleRemoteInbound(_ frame: SessionProxyInbound) {
        switch frame {
        case let .command(commandId, kind, payload, queued):
            lastRemoteCommand = queued ? "\(kind)（离线补发）" : kind
            switch kind {
            case "cancel":
                print("[crew-session] remote command \(commandId): cancel — cancelling local run")
                Task { await cancel() }
            case "send_prompt":
                if case let .string(text)? = payload?["text"], !text.isEmpty {
                    print("[crew-session] remote send_prompt \(commandId): queueing resume turn")
                    enqueueFollowUp(text)
                } else {
                    print("[crew-session] send_prompt \(commandId) missing string payload.text — ignored")
                }
            case "set_steering":
                // Ambient standing note — injected into every turn via the hook.
                // Empty text clears it. Takes effect from the next turn onward.
                let text = { if case let .string(t)? = payload?["text"] { return t } else { return "" } }()
                setSteeringNote(text)
            default:
                print("[crew-session] remote command \(commandId) kind=\(kind) queued=\(queued) — not applied")
            }
        case let .permissionDecision(requestId, decision):
            print("[crew-session] remote permission decision \(requestId): \(decision) — not applied yet")
        case .subscribed, .error, .unknown:
            break // handled inside SessionProxyClient
        }
    }

    /// Mirror newly-parsed events to the server session log, in order. No-op
    /// without a serverLink (BYOK/local). Chained so events keep stream order;
    /// best-effort so a publish failure never affects the local run.
    private func publishToServer(_ events: [RunnerEvent]) {
        guard let link = serverLink else { return }
        let prev = publishChain
        publishChain = Task {
            await prev?.value
            for event in events { await link.publish(event) }
        }
    }

    private func appendStderr(_ line: String) {
        if !stderrText.isEmpty { stderrText.append("\n") }
        stderrText.append(line)
    }

    /// A turn's process exited. If a steering follow-up is queued (and the run
    /// is resumable + not cancelled), start the next `--resume` turn and stay
    /// `.running`. Otherwise the session is done — finalize.
    ///
    /// In the common no-steering case the queue is empty here, so this falls
    /// straight through to `finalize`, exactly matching the verified one-shot
    /// behaviour.
    private func turnDidExit(exitCode: Int32) {
        self.exitCode = exitCode
        if !cancelled, !followUpQueue.isEmpty {
            let prompt = followUpQueue.removeFirst()
            startResumeTurn(prompt: prompt)
            return
        }
        finalize(exitCode: exitCode)
    }

    /// Spawn a `--resume` follow-up turn carrying a steering prompt, re-point
    /// `currentHandle`, and observe its streams (which feed the same events /
    /// server log / proxy state). Status stays `.running`. A non-resumable run
    /// (no agent session id yet, or Codex) can't steer → finalize instead.
    private func startResumeTurn(prompt: String) {
        guard let agentSessionId,
              let resumeSpec = currentHandle.spec.makingResumeTurn(
                  agentSessionId: agentSessionId, prompt: prompt) else {
            print("[crew-session] cannot resume (no agent session id / unsupported runner) — finalizing")
            finalize(exitCode: exitCode ?? 0)
            return
        }
        print("[crew-session] starting resume turn for steering prompt")
        Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await self.service.runSession(runID: UUID(), spec: resumeSpec)
                self.adoptResumeTurn(handle)
            } catch {
                print("[crew-session] resume turn failed to launch: \(error)")
                self.finalize(exitCode: self.exitCode ?? 1)
            }
        }
    }

    /// Re-point to the resume turn's handle + wire its streams. Separate so the
    /// MainActor mutation happens in one hop after the async launch.
    private func adoptResumeTurn(_ handle: LocalCodingAgentRunHandle) {
        currentHandle = handle
        observe(handle)
        publishStateToProxy()
    }

    /// The session is truly over — set terminal status, close the server row,
    /// push terminal state + close the proxy socket. Idempotent.
    private func finalize(exitCode: Int32) {
        guard !finalized else { return }
        finalized = true
        crewContextPollTask?.cancel()
        // Remove the out-of-tree steering + interaction dirs now the session is over.
        steeringChannel?.teardown()
        interactionChannel?.teardown()
        if cancelled {
            status = .cancelled
        } else if exitCode == 0 {
            status = .completed
        } else {
            // 退出码非 0 视为 failed —— UI 上仍把 exitCode 数字展示出来。
            // 后续如果 CLI 对 SIGTERM 也 exit 130/143，cancel + 非零退出码
            // 都会落到 cancelled 分支，因为 cancelled 标志已置。
            status = .failed
        }
        // T4.5 — close out the server session row after the last queued event
        // publishes, so the finish doesn't race ahead of in-flight appends.
        if let link = serverLink {
            let finalStatus = status
            let summary = events.last.map(SessionState.summarize)
            let prev = publishChain
            publishChain = Task {
                await prev?.value
                await link.finish(localStatus: finalStatus, summary: summary)
            }
        }
        // T4.5 — push the terminal state to viewers, then close the socket.
        // Independent of the HTTP publishChain; the proxy is best-effort.
        if let proxyClient {
            let finalState = SessionState.from(status: Self.wireStatus(status), events: events)
            Task {
                await proxyClient.publish(finalState)
                await proxyClient.close()
            }
        }
    }
}
#endif
