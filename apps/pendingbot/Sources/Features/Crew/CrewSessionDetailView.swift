import SwiftUI

/// The remote-control detail page for one crew session: a live status banner,
/// the transcript (session_events rendered as a de-noised process stream),
/// inline permission cards, and a composer to steer / cancel / switch
/// permission mode. Reads its own data by session id (works in both the
/// compact push and the wide detail column).
struct CrewSessionDetailView: View {
    @Environment(\.api) private var api
    @StateObject private var store: CrewSessionDetailStore

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(sessionId: String) {
        _store = StateObject(wrappedValue: CrewSessionDetailStore(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .background(Theme.Palette.canvas)
        .navigationTitle("任务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task {
            store.configure(api: api)
            await store.loadAll()
            store.start()
        }
        .onDisappear { store.stop() }
    }

    // MARK: - Transcript + banner + permission cards

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                banner
                ForEach(store.pendingPermissionRequests) { request in
                    PermissionRequestCardView(
                        sessionLabel: bannerTitle,
                        payload: request.asPayload,
                        busy: store.deciding.contains(request.id),
                        onApprove: { store.decide(request, approve: true) },
                        onDeny: { store.decide(request, approve: false) }
                    )
                }
                ForEach(store.events) { event in
                    CrewTranscriptRow(event: event)
                        .padding(.horizontal, Theme.Metrics.gutter)
                }
                if store.events.isEmpty {
                    Text("暂无过程记录。\n(claude PTY 会话以终端为准,过程流可能很稀疏。)")
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .padding(.horizontal, Theme.Metrics.gutter)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CrewStatusBadge(status: store.status)
                Spacer()
                if let session = store.session {
                    Text(CrewRunnerKind.shortLabel(session.runner_kind))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            Text(bannerTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.ink)
            if let progress = store.session?.progress_summary,
               !progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(progress)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            if let last = store.liveState?.lastEvent, !last.isEmpty {
                Label(last, systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.accent)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .padding(.horizontal, Theme.Metrics.gutter)
    }

    private var bannerTitle: String {
        let brief = store.session?.task_brief.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return brief.isEmpty ? "任务" : brief
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.Palette.hairline)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("插话引导 / 补充指令…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.Palette.surfaceMuted)
                    )
                Button {
                    store.sendPrompt(draft)
                    draft = ""
                    composerFocused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Theme.Palette.inkMuted
                                : Theme.Palette.accent
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.status.isActive)
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, 8)
        }
        .background(Theme.Palette.canvas)
    }

    // MARK: - Toolbar (cancel + permission mode)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("权限模式") {
                    Button("自动放行") { store.setPermissionMode("auto") }
                    Button("逐项审批") { store.setPermissionMode("manual") }
                    Button("继承机组默认") { store.setPermissionMode(nil) }
                }
                if store.status.isActive {
                    Divider()
                    Button(role: .destructive) {
                        store.cancel()
                    } label: {
                        Label("取消任务", systemImage: "stop.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Transcript row

/// One transcript line. Process signals (tool_call / status / …) render as a
/// dim single-line bullet; agent prose (posted_to_crew / completed summaries)
/// renders at full brightness as markdown. Permission events are anchors only
/// (the cards render separately).
struct CrewTranscriptRow: View {
    let event: SessionEventRow

    /// Event types whose `summary` is agent prose worth full-brightness
    /// markdown. Everything else is a dim process bullet.
    private static let proseTypes: Set<String> = [
        "posted_to_crew", "completed", "failed", "result", "agent_message",
    ]
    private static let hiddenTypes: Set<String> = [
        "permission_requested", "permission_resolved",
    ]

    private var isProse: Bool { Self.proseTypes.contains(event.event_type) }

    var body: some View {
        if Self.hiddenTypes.contains(event.event_type) {
            EmptyView()
        } else if isProse {
            MarkdownText(text: event.summary ?? "", variant: .chat)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Theme.Palette.inkMuted.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                Text(processLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var processLabel: String {
        let verb = Self.verb(for: event.event_type)
        if let summary = event.summary, !summary.isEmpty {
            return "\(verb) \(summary)"
        }
        return verb
    }

    private static func verb(for type: String) -> String {
        switch type {
        case "tool_call":         return "调用"
        case "tool_result":       return "结果"
        case "status":            return "状态"
        case "started":           return "启动"
        case "runner_selected":   return "选定 runner"
        case "context_injected":  return "注入上下文"
        case "artifact_created":  return "产物"
        default:                  return type
        }
    }
}
