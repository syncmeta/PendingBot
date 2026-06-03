#if os(macOS)
import SwiftUI

/// T4.5 cross-device session viewer — **macOS PendingBot**.
///
/// The phone (`Sources/Features/Crew/RemoteSessionsView.swift`) is the
/// reference; this is the Mac three-column adaptation:
///   * `MacCrewListColumn` fills the middle column — the crews the caller can
///     see (`listCrewsV2`); selecting one drives the detail column.
///   * `MacRemoteSessionsView` is the detail column — an `HSplitView` of the
///     crew's server sessions (left) and the selected session's transcript
///     (right), with the live `session.state` banner + 停止 (cancel) control.
///
/// Two layers, same as iOS: a 3s durable poll (`getCrewSessions` /
/// `getCrewSessionEvents`) that always works, and a best-effort viewer proxy
/// socket (`SessionProxyClient`) for low-latency state + remote cancel. The API
/// client + WS transport + presentation mapping are the cross-platform pieces
/// shared with iOS (`CrewSessionAPI` / `SessionProxyClient` / `SessionStatusStyle`).

// MARK: - Middle column: crew list

struct MacCrewListColumn: View {
    @Binding var selectedCrewId: String?

    @State private var crews: [CrewSummaryV2] = []
    @State private var loadError: String?
    @State private var didLoad = false

    private let api = APIClient()

    var body: some View {
        List(selection: $selectedCrewId) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if crews.isEmpty && didLoad && loadError == nil {
                Text("还没有可见的机组").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(crews) { crew in
                HStack(spacing: 10) {
                    BrandAvatar(seed: crew.id, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(crew.title.isEmpty ? "未命名机组" : crew.title)
                            .font(.body).lineLimit(1)
                        HStack(spacing: 5) {
                            if let kind = crew.runtimeLocationKind {
                                Label(kind.shortLabel, systemImage: kind.sfSymbol)
                            } else {
                                Text(crew.runtimeLocation)
                            }
                            if let tag = crew.tag, !tag.isEmpty {
                                Text("· \(tag)")
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(crew.id)
            }
        }
        .navigationTitle("Crew")
        .task { await load() }
    }

    private func load() async {
        do {
            crews = try await api.listCrewsV2()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        didLoad = true
    }
}

// MARK: - Detail column: one crew's server sessions + live transcript

struct MacRemoteSessionsView: View {
    let crewId: String

    @State private var sessions: [CrewSessionRow] = []
    @State private var selectedSessionId: String?
    @State private var events: [CrewSessionLogEvent] = []
    @State private var loadError: String?
    @State private var didInitialLoad = false

    // Live layer — one viewer proxy socket for the selected session.
    @State private var liveClient: SessionProxyClient?
    @State private var liveSnapshot: SessionStateSnapshot?
    @State private var sentCancel = false

    private let api = APIClient()
    private let pollInterval: UInt64 = 3_000_000_000 // 3s

    /// The selected session row, if any.
    private var selectedSession: CrewSessionRow? {
        guard let selectedSessionId else { return nil }
        return sessions.first { $0.id == selectedSessionId }
    }

    /// Freshest status — live state wins over the polled row.
    private var currentStatus: String {
        liveSnapshot?.status ?? selectedSession?.status ?? ""
    }

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            transcriptPane
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .navigationTitle("服务端 session")
        .task(id: crewId) { await pollLoop() }
        .onChange(of: selectedSessionId) { _, newValue in subscribeLive(to: newValue) }
        .onDisappear { teardownLive() }
    }

    // MARK: panes

    private var sessionList: some View {
        List(selection: $selectedSessionId) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if sessions.isEmpty && didInitialLoad && loadError == nil {
                Text("这个机组还没有服务端 session").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(SessionStatusStyle.tint(s.status)).frame(width: 7, height: 7)
                        Text((s.task_brief?.isEmpty == false) ? s.task_brief! : "未命名会话")
                            .lineLimit(1)
                    }
                    Text("\(SessionStatusStyle.runnerLabel(s.runner_kind)) · \(SessionStatusStyle.statusLabel(s.status))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(s.id)
            }
        }
    }

    @ViewBuilder
    private var transcriptPane: some View {
        if selectedSessionId == nil {
            Text("选一个 session 看转写").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                liveHeader
                Divider()
                if events.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("拉取事件…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcript
                }
            }
        }
    }

    /// Live state banner + 停止 control. Falls back to the polled row's status
    /// before the socket delivers its first `session.state`.
    private var liveHeader: some View {
        HStack(spacing: 6) {
            Circle().fill(SessionStatusStyle.tint(currentStatus)).frame(width: 7, height: 7)
            if liveSnapshot != nil {
                Text("实时").font(.caption.weight(.semibold)).foregroundStyle(SessionStatusStyle.tint(currentStatus))
            }
            Text(SessionStatusStyle.statusLabel(currentStatus)).font(.caption).foregroundStyle(.secondary)
            if let last = liveSnapshot?.lastEvent, !last.isEmpty {
                Text("·").foregroundStyle(.secondary)
                Text(last).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let snap = liveSnapshot {
                Text("\(snap.eventCount) 事件").font(.caption2).foregroundStyle(.secondary)
            }
            if SessionStatusStyle.isStoppable(currentStatus) {
                Button(role: .destructive) {
                    sentCancel = true
                    Task { await liveClient?.sendCommand(kind: "cancel") }
                } label: {
                    Label("停止", systemImage: "stop.circle")
                }
                .controlSize(.small)
                .disabled(liveClient == nil || sentCancel)
                .help("向运行该 session 的机器发送停止命令")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(events) { ev in
                        eventRow(ev).id(ev.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(14)
            }
            .onChange(of: events.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    private func eventRow(_ ev: CrewSessionLogEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: SessionStatusStyle.eventIcon(ev.event_type))
                .foregroundStyle(SessionStatusStyle.eventTint(ev.event_type))
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionStatusStyle.eventLabel(ev.event_type)).font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let s = ev.summary, !s.isEmpty {
                    Text(s).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: polling

    private func pollLoop() async {
        // crewId changed (or first appearance): reset selection + reload.
        selectedSessionId = nil
        events = []
        didInitialLoad = false
        while !Task.isCancelled {
            await refresh()
            didInitialLoad = true
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func refresh() async {
        do {
            let list = try await api.getCrewSessions(crewId)
            sessions = list
            loadError = nil
            if selectedSessionId == nil { selectedSessionId = list.first?.id }
            if let sid = selectedSessionId {
                events = try await api.getCrewSessionEvents(sessionId: sid)
            }
        } catch is CancellationError {
            // view went away mid-fetch
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: live (viewer proxy socket)

    private func subscribeLive(to sessionId: String?) {
        teardownLive()
        events = []
        guard let sessionId else { return }
        let client = SessionProxyClient(
            baseURL: api.workerURL,
            sessionId: sessionId,
            role: .viewer,
            token: { try? await SupabaseStack.shared.auth.session.accessToken }
        )
        liveClient = client
        Task {
            await client.connect()
            for await snap in client.states {
                liveSnapshot = snap
            }
        }
    }

    private func teardownLive() {
        sentCancel = false
        liveSnapshot = nil
        let client = liveClient
        liveClient = nil
        Task { await client?.close() }
    }
}
#endif
