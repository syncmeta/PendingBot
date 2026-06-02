#if os(iOS)
import SwiftUI

/// T4.5 viewer side — watch a crew's server sessions (including ones running on
/// **another** machine) by reading the durable HTTP log. This is the read-only
/// "follow a session" half of cross-device control; sending commands (the live
/// SessionProxyDO WebSocket + `session.command`) is a follow-up.
///
/// Mirrors the Mac `RemoteSessionsView` (a NavigationSplitView there); the iOS
/// form factor is a NavigationStack: a session list, tap to push the transcript.
/// Polls `getCrewSessions` every 3s while visible; the runner publishes those
/// rows via the verified register→create→claim→events→finish lifecycle, so this
/// renders sessions even from a different device. Presented as a sheet from
/// `CrewDetailV2View`.
struct RemoteSessionsView: View {
    let crewId: String
    let crewTitle: String

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [CrewSessionRow] = []
    @State private var loadError: String?
    @State private var didInitialLoad = false

    /// 3s — same cadence as the Mac viewer; cheap read, no realtime in this slice.
    private let pollInterval: UInt64 = 3_000_000_000

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("服务端 session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text("服务端 session").font(.headline)
                            Text(crewTitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .task { await pollLoop() }
    }

    @ViewBuilder
    private var content: some View {
        if sessions.isEmpty && didInitialLoad && loadError == nil {
            ContentUnavailableView(
                "还没有服务端 session",
                systemImage: "terminal",
                description: Text("这个机组在任意设备上启动 session 后会出现在这里")
            )
        } else if !didInitialLoad {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                ForEach(sessions) { session in
                    NavigationLink {
                        RemoteSessionTranscriptView(
                            sessionId: session.id,
                            brief: sessionTitle(session),
                            initialStatus: session.status
                        )
                    } label: {
                        sessionRow(session)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func sessionRow(_ s: CrewSessionRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(SessionStatusStyle.tint(s.status))
                    .frame(width: 8, height: 8)
                Text(sessionTitle(s))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(SessionStatusStyle.runnerLabel(s.runner_kind))
                Text("·")
                Text(SessionStatusStyle.statusLabel(s.status))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let progress = s.progress_summary, !progress.isEmpty {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func sessionTitle(_ s: CrewSessionRow) -> String {
        let brief = s.task_brief ?? ""
        return brief.isEmpty ? "未命名会话" : brief
    }

    // MARK: - polling

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            didInitialLoad = true
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func refresh() async {
        guard let api else {
            loadError = "未登录"
            return
        }
        do {
            sessions = try await api.getCrewSessions(crewId)
            loadError = nil
        } catch is CancellationError {
            // view went away mid-fetch; loop will exit on its own
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// The transcript pane for one server session — the durable event log rendered
/// oldest→newest, auto-scrolling to the tail. Polls `getCrewSessionEvents` every
/// 3s while visible. Pushed from `RemoteSessionsView`.
struct RemoteSessionTranscriptView: View {
    let sessionId: String
    let brief: String
    /// Status from the list row — the starting point for the "can stop?" gate
    /// until the live `session.state` (or the next poll) supplies a fresher one.
    let initialStatus: String

    @Environment(\.api) private var api

    @State private var events: [CrewSessionLogEvent] = []
    @State private var loadError: String?
    @State private var didInitialLoad = false

    // Live layer — one viewer proxy socket for this session. Best-effort
    // decoration over the durable poll: if the WS can't connect, the poll still
    // drives the transcript.
    @State private var liveClient: SessionProxyClient?
    @State private var liveSnapshot: SessionStateSnapshot?
    @State private var sentCancel = false

    private let pollInterval: UInt64 = 3_000_000_000

    /// The freshest status we know — live state wins over the list-row snapshot.
    private var currentStatus: String { liveSnapshot?.status ?? initialStatus }

    var body: some View {
        VStack(spacing: 0) {
            if let liveSnapshot {
                liveBanner(liveSnapshot)
                Divider()
            }
            transcriptBody
        }
        .navigationTitle(brief)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if SessionStatusStyle.isStoppable(currentStatus) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        guard let client = liveClient else { return }
                        sentCancel = true
                        Task { await client.sendCommand(kind: "cancel") }
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .accessibilityLabel("停止会话")
                    .disabled(liveClient == nil || sentCancel)
                }
            }
        }
        .task { await pollLoop() }
        .task { await subscribeLive() }
        .onDisappear { teardownLive() }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let loadError, events.isEmpty {
            ContentUnavailableView {
                Label("拉取事件失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else if events.isEmpty && !didInitialLoad {
            ProgressView("拉取事件…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if events.isEmpty {
            ContentUnavailableView("还没有事件", systemImage: "text.append")
        } else {
            transcript
        }
    }

    /// The real-time banner driven by the runner's `session.state` fan-out over
    /// the proxy socket — distinct from the polled durable log below.
    private func liveBanner(_ snap: SessionStateSnapshot) -> some View {
        HStack(spacing: 6) {
            Circle().fill(SessionStatusStyle.tint(snap.status)).frame(width: 7, height: 7)
            Text("实时").font(.caption.weight(.semibold)).foregroundStyle(SessionStatusStyle.tint(snap.status))
            Text(SessionStatusStyle.statusLabel(snap.status)).font(.caption2).foregroundStyle(.secondary)
            if let last = snap.lastEvent, !last.isEmpty {
                Text("·").foregroundStyle(.secondary)
                Text(last).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text("\(snap.eventCount) 事件").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(events) { ev in
                        eventRow(ev).id(ev.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(16)
            }
            .onChange(of: events.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    private func eventRow(_ ev: CrewSessionLogEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: SessionStatusStyle.eventIcon(ev.event_type))
                .foregroundStyle(SessionStatusStyle.eventTint(ev.event_type))
                .font(.callout)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionStatusStyle.eventLabel(ev.event_type))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let summary = ev.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - polling

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            didInitialLoad = true
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func refresh() async {
        guard let api else {
            loadError = "未登录"
            return
        }
        do {
            events = try await api.getCrewSessionEvents(sessionId: sessionId)
            loadError = nil
        } catch is CancellationError {
            // view went away mid-fetch
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - live (viewer proxy socket)

    /// Open the viewer proxy socket and drain its live `session.state` fan-out
    /// into `liveSnapshot`. The JWT is fetched fresh on every (re)connect via the
    /// token closure so a long-lived view that crosses a token refresh keeps a
    /// valid bearer. Best-effort — not logged in or a failed upgrade just leaves
    /// the polled transcript as the sole source.
    private func subscribeLive() async {
        guard let api else { return }
        let client = SessionProxyClient(
            baseURL: api.workerURL,
            sessionId: sessionId,
            role: .viewer,
            token: { try? await SupabaseStack.shared.auth.session.accessToken }
        )
        liveClient = client
        await client.connect()
        for await snap in client.states {
            liveSnapshot = snap
        }
    }

    private func teardownLive() {
        let client = liveClient
        liveClient = nil
        Task { await client?.close() }
    }
}

/// Shared presentation mapping for session status + event types. Mirrors the Mac
/// `RemoteSessionsView` helpers so both clients label the same wire vocab the
/// same way. Kept as an enum-of-statics so both views above can share it.
enum SessionStatusStyle {
    static func runnerLabel(_ kind: String?) -> String {
        switch kind {
        case "local_claude_code": return "Claude Code"
        case "local_codex": return "Codex"
        case "local_opencode": return "OpenCode"
        case "local_kilo": return "Kilo"
        case "cloud_sandbox": return "云沙箱"
        case .none: return "runner 未定"
        case .some(let k): return k
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "queued": return "排队中"
        case "waiting_runner": return "等待 runner"
        case "running": return "运行中"
        case "waiting_permission": return "等待授权"
        case "idle": return "空闲"
        case "paused": return "已暂停"
        case "completed", "finished": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return status
        }
    }

    static func tint(_ status: String) -> Color {
        switch status {
        case "running", "waiting_runner", "waiting_permission": return .blue
        case "completed", "finished": return .green
        case "failed": return .red
        case "cancelled": return .secondary
        default: return .orange
        }
    }

    /// A session a viewer can still stop — pre-terminal states only.
    static func isStoppable(_ status: String) -> Bool {
        switch status {
        case "completed", "finished", "failed", "cancelled": return false
        default: return true
        }
    }

    static func eventLabel(_ eventType: String) -> String {
        switch eventType {
        case "queued": return "已排队"
        case "started": return "已启动"
        case "context_injected": return "注入上下文"
        case "status": return "状态更新"
        case "tool_call": return "工具调用"
        case "tool_result": return "工具结果"
        case "permission_requested": return "请求授权"
        case "permission_resolved": return "授权结果"
        case "artifact_created": return "产出文件"
        case "posted_to_crew": return "发到机组"
        case "blocked": return "被阻塞"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return eventType
        }
    }

    static func eventIcon(_ eventType: String) -> String {
        switch eventType {
        case "started", "queued": return "play.circle"
        case "context_injected": return "tray.and.arrow.down"
        case "tool_call": return "wrench.and.screwdriver"
        case "tool_result": return "arrow.turn.down.right"
        case "permission_requested", "permission_resolved": return "lock.shield"
        case "artifact_created": return "doc.badge.plus"
        case "posted_to_crew": return "bubble.left.and.bubble.right"
        case "blocked", "failed": return "exclamationmark.triangle"
        case "completed": return "checkmark.seal"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }

    static func eventTint(_ eventType: String) -> Color {
        switch eventType {
        case "tool_call", "tool_result": return .orange
        case "permission_requested", "permission_resolved": return .purple
        case "artifact_created", "posted_to_crew": return .teal
        case "blocked", "failed": return .red
        case "completed": return .green
        case "cancelled": return .secondary
        default: return .blue
        }
    }
}
#endif
