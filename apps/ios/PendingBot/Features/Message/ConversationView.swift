import SwiftUI
import PhotosUI
import UIKit

/// One conversation. Loads history from Supabase, runs the user-direct
/// chat turn over Worker SSE (ChatStream), and listens for cross-device /
/// background-task messages via Supabase Realtime on the conv channel.
struct ConversationView: View {
    let conversation: Conversation
    let bot: Bot?
    var onChange: () -> Void = {}

    @Environment(\.api) private var api
    @Environment(\.account) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var cameraImage: UIImage?
    @State private var modelOverride: String = ""    // "" = use bot default
    @State private var error: String?
    @State private var pending = false              // server is generating (bot_typing active)
    /// Active SSE turn task; canceling it closes the stream which Worker
    /// reads as request.signal.aborted (= interrupt). Set by sendViaSSE,
    /// cleared on completion. Non-nil while a turn is in flight.
    @State private var chatTurnTask: Task<Void, Never>?
    /// Realtime subscription token for this conv's `messages` channel —
    /// dropped when the view disappears. Picks up cross-device messages
    /// and bot rows that land via background paths (cron, surf, review).
    @State private var realtimeToken: ConvSubscriptionToken?
    /// Lookback notes the bot wrote about prior turns (Realtime push from
    /// pendingbot.bot_lookbacks). Invisible to the user; passed in
    /// `activeLookbacks` on the next POST so the bot sees them as context.
    @State private var activeLookbacks: [LookbackNote] = []
    /// 30s grace timer started when a new lookback arrives. If user hasn't
    /// sent anything before it fires, we auto-trigger a continuation turn
    /// so the bot's fact-check actually surfaces.
    @State private var lookbackAutoFireTask: Task<Void, Never>?
    // Transient surf_status events from the in-flight 联网 search. Cleared
    // when the bot reply arrives. Displayed as an inline log above the
    // pending-typing row, mirroring the web's `.surf-log` panel.
    @State private var searchLog: [String] = []
    // When a bot reply lands, the in-flight searchLog is pinned to that
    // message's id and rendered as a collapsed chip above its bubble — so
    // the search trace doesn't disappear, it just folds away. Session-only;
    // not persisted across reloads (server doesn't store it yet).
    @State private var pinnedToolLogs: [String: [String]] = [:]
    // Skill summaries — counted in the settings sheet so the user sees
    // how many are active without leaving the conversation.
    @State private var skills: [SkillSummary] = []
    @State private var showingSkills = false
    @State private var showingSettings = false
    @State private var saveAsSkillBody: String?
    // Per-user tone preference, persisted globally across conversations.
    // 'wechat' = casual multi-bubble (default); 'normal' = single-message AI.
    @AppStorage("bb_chatTone") private var chatTone = "wechat"
    // Streaming preference. The settings sheet auto-flips this whenever
    // tone changes (normal=on, wechat=off) — see ConversationSettingsView.
    @AppStorage("bb_chatStreaming") private var streaming = false

    /// "<bot_name> · <effective-model-tag>". Effective model = the per-conv
    /// override if set, otherwise the bot's resolved model (which itself
    /// already accounts for the user's per-bot pin from 我 → 机器人管理).
    private var botName: String {
        let base = bot?.display_name ?? conversation.bot_name ?? conversation.bot_id
        let tag: String? = {
            let trimmed = modelOverride.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return shortSlug(trimmed) }
            return bot?.modelTag
        }()
        guard let tag else { return base }
        return "\(base) · \(tag)"
    }

    private func shortSlug(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    init(conversation: Conversation, bot: Bot?, onChange: @escaping () -> Void = {}) {
        self.conversation = conversation
        self.bot = bot
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: 8)

                        if messages.isEmpty && !pending {
                            emptyConversation
                        }

                        ForEach(messages) { msg in
                            BubbleView(message: msg,
                                       botName: botName,
                                       conversationID: conversation.id,
                                       serverURL: account?.workerURL,
                                       toolLog: pinnedToolLogs[msg.id])
                                .id(msg.id)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = msg.content
                                        Haptics.tap()
                                    } label: { Label("复制", systemImage: "doc.on.doc") }
                                    if !msg.isUser {
                                        ShareLink(item: msg.content) {
                                            Label("分享", systemImage: "square.and.arrow.up")
                                        }
                                        Button {
                                            saveAsSkillBody = msg.content
                                            Haptics.tap()
                                        } label: {
                                            Label("保存为技能", systemImage: "square.and.arrow.down.on.square")
                                        }
                                    }
                                    Button(role: .destructive) {
                                        Task { await deleteMessage(msg) }
                                    } label: { Label("删除", systemImage: "trash") }
                                }
                                .transition(.blurReplace)
                        }

                        if !searchLog.isEmpty {
                            searchLogPanel
                                .id("searchlog")
                                .padding(.horizontal, Theme.Metrics.gutter)
                                .padding(.top, 4)
                        }

                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.top, 4)
                    .readableColumnWidth()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: searchLog.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // Mount the composer as a bottom safe-area inset so the message
        // list above it gets a stable bottom edge — this is what fixes
        // the "input bar / messages jump in from above" glitch when the
        // "+" panel toggles. With safeAreaInset, SwiftUI accounts for
        // the inset change in one coordinated layout pass instead of the
        // ScrollView and composer animating against each other.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                ComposerView(
                    input: $input,
                    pending: $pendingAttachments,
                    photoItems: $photoPickerItems,
                    cameraImage: $cameraImage,
                    canSend: canSend,
                    onSend: { Task { await send() } },
                    isStreaming: chatTurnTask != nil,
                    onStop: { chatTurnTask?.cancel() }
                )
                .readableColumnWidth()
            }
        }
        .task {
            modelOverride = conversation.model_override ?? ""
            await loadHistory()
            await loadSkills()
            // Subscribe to the conv channel for cross-device sync and bot
            // rows that land via background paths (cron / surf / review).
            // The current device's own SSE-streamed bubbles also arrive here
            // — we dedupe by id below, so they merge in cleanly.
            let convId = conversation.id
            await loadActiveLookbacks()
            realtimeToken = await RealtimeManager.shared.startConvChannel(
                conversationId: convId,
                onMessage: { event in
                    Task { @MainActor in
                        applyRealtimeEvent(event)
                    }
                },
                onLookback: { event in
                    Task { @MainActor in
                        applyLookbackEvent(event)
                    }
                }
            )
        }
        .onDisappear {
            if let token = realtimeToken {
                Task { await RealtimeManager.shared.stopConvChannel(token) }
                realtimeToken = nil
            }
            lookbackAutoFireTask?.cancel()
            lookbackAutoFireTask = nil
        }
        .sheet(isPresented: $showingSkills) {
            NavigationStack {
                SkillsView()
            }
            .tint(Theme.Palette.accent)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .onDisappear { Task { await loadSkills() } }
        }
        .sheet(isPresented: $showingSettings) {
            ConversationSettingsView(
                chatTone: $chatTone,
                streaming: $streaming,
                modelOverride: $modelOverride,
                enabledSkillCount: skills.filter { $0.enabled }.count,
                totalSkillCount: skills.count,
                onOpenSkills: { showingSkills = true },
                onApplyModel: { slug, scope in
                    Task { await applyModelPick(slug: slug, scope: scope) }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { saveAsSkillBody.map { SkillDraft(body: $0) } },
            set: { saveAsSkillBody = $0?.body }
        )) { draft in
            SkillEditorSheet(mode: .createPrefilled(body: draft.body)) {
                Task { await loadSkills() }
            }
            .tint(Theme.Palette.accent)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: photoPickerItems) { _, items in
            Task { await ingestPhotos(items) }
        }
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            Task { await ingestCameraImage(image) }
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        // Defer one runloop so LazyVStack has measured any just-appended row;
        // scrolling synchronously inside the same state-change tick lands on a
        // stale offset and the list visibly jumps past the bottom.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                if let lastId = messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 14) {
            BotAvatar(seed: conversation.id, size: 64)
            Text(botName)
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.bottom, 24)
    }

    /// Custom in-body chat header — replaces the system nav bar so we have
    /// full control. From left to right:
    ///   < (back) · avatar (plain, NOT a button) · title / botName · 正在输入...
    /// The avatar sits as a static visual anchor; only the chevron is
    /// tappable. The whole row stays at one height, like the tab headers.
    private var chatHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            // In sidebar layout (iPad landscape / Mac), the detail pane has
            // no parent stack to pop back to — picking another conversation
            // is what swaps the detail. Drop the chevron there.
            if !sidebarLayout {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.trailing, 2)
                }
                .buttonStyle(.plain)
            }

            BotAvatar(seed: conversation.id, size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.displayTitle)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(botName)
                        .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                    if pending {
                        Text("·")
                            .font(Theme.Fonts.rounded(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Palette.inkMuted)
                        TypingDots()
                            .transition(.opacity)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("会话设置")
        }
        .animation(.easeInOut(duration: 0.2), value: pending)
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // Inline list of recent surf_status events while the server is doing a
    // web lookup. Disappears when the bot reply arrives (handle() clears
    // `searchLog`). Editorial timeline style — accent dots, per-line fade-in,
    // older lines softened so the latest status reads as the focal point.
    private var searchLogPanel: some View {
        let entries = Array(searchLog.enumerated())
        let latestIndex = entries.last?.offset ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PulsingGlobe()
                Text("联网检索")
                    .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries, id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(idx == latestIndex
                                  ? Theme.Palette.accent.opacity(0.8)
                                  : Theme.Palette.inkMuted.opacity(0.35))
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(line)
                            .font(Theme.Fonts.rounded(size: 13, weight: .regular))
                            .foregroundStyle(idx == latestIndex
                                             ? Theme.Palette.ink.opacity(0.85)
                                             : Theme.Palette.inkMuted.opacity(0.7))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Palette.surfaceMuted.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Palette.accent.opacity(0.12), lineWidth: 0.6)
        )
        .animation(.easeOut(duration: 0.28), value: searchLog.count)
    }

    // ── Send ────────────────────────────────────────────────────────────────

    private func send() async {
        guard let api, canSend else { return }
        let text = input.trimmingCharacters(in: .whitespaces)
        let attachIds = pendingAttachments.map(\.id)
        // Optimistic local echo — server will deliver canonical row via WS.
        messages.append(ChatMessage(
            id: "local-\(UUID().uuidString)",
            conversation_id: conversation.id,
            sender_type: "user", sender_id: "",
            content: text,
            created_at: Int(Date().timeIntervalSince1970),
            attachments: pendingAttachments.map {
                Attachment(id: $0.id, kind: "image", mime: $0.mime, size: $0.size,
                           width: nil, height: nil, url: "/uploads/\($0.id)")
            }
        ))
        input = ""
        pendingAttachments = []
        photoPickerItems = []
        Haptics.send()

        // Old WS path replaced — this turn flows through Worker SSE now.
        // sendViaSSE owns the Task lifetime so the stop button can cancel it.
        sendViaSSE(text: text, attachmentIds: attachIds)
        _ = api
    }

    /// Start the bot reply over SSE. Bubble emissions land in `messages`
    /// via incremental insert/update. Cancel the returned Task (via the
    /// stop button) to close the SSE — Worker observes request.signal.aborted
    /// and stops the LLM stream.
    private func sendViaSSE(text: String, attachmentIds: [String], autoLookback: Bool = false) {
        chatTurnTask?.cancel()
        // User taking action (or auto-fire firing) cancels the pending
        // 30s lookback grace timer either way.
        lookbackAutoFireTask?.cancel()
        lookbackAutoFireTask = nil
        pending = true

        let body: [String: Any] = {
            let clientMsgId = UUID().uuidString.lowercased()
            let recent = messages.suffix(20).map { m -> [String: Any] in
                [
                    "role": m.sender_type,
                    "content": m.content,
                    "created_at": ISO8601DateFormatter().string(
                        from: Date(timeIntervalSince1970: TimeInterval(m.created_at))
                    ),
                ]
            }
            let oldestId = messages.first { $0.id.range(of: "^[0-9a-f-]{36}$",
                                                        options: .regularExpression) != nil }?.id
            var b: [String: Any] = [
                "conversationId": conversation.id,
                "clientMessageId": clientMsgId,
                "recentContext": recent,
            ]
            if !text.isEmpty { b["newMessage"] = text }
            if autoLookback { b["autoLookback"] = true }
            if !activeLookbacks.isEmpty {
                b["activeLookbacks"] = activeLookbacks.map { ["id": $0.id, "body_md": $0.body_md] }
            }
            if !attachmentIds.isEmpty { b["attachmentIds"] = attachmentIds }
            if let oldestId { b["oldestContextMessageId"] = oldestId }
            return b
        }()

        chatTurnTask = Task { @MainActor in
            let splitter = BubbleSplitter()
            let stream = ChatStream().send(body: body)
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .typing:
                        break // pending state already true
                    case .token(let delta):
                        splitter.accept(token: delta)
                    case .bubble:
                        // Server-side canonical bubble id arrived; we
                        // already split client-side, no action needed —
                        // local id is the source of truth for UI; the
                        // server id is for cross-device sync via Realtime.
                        break
                    case .done(_, let total):
                        splitter.flushTail()
                        splitter.turnDone(totalContent: total)
                    case .interrupted(_, let total):
                        splitter.flushTail()
                        splitter.turnInterrupted(totalContent: total)
                    case .silent:
                        // Bot chose to say nothing — drop any buffered
                        // tokens (held back by the Worker until SILENT
                        // ambiguity broke), don't render any bubble.
                        // No bubble events have been emitted by the
                        // splitter yet, so just clear its buffer.
                        _ = splitter.drain()
                    case .error(let msg):
                        splitter.reportError(msg)
                    case .unknown:
                        break
                    }
                    applyBubbleEmissions(splitter.drain())
                }
                // Stream ended without an explicit done event (rare).
                splitter.flushTail()
                applyBubbleEmissions(splitter.drain())
            } catch {
                // Cancellation = user-initiated interrupt; not an error UI.
                if !(error is CancellationError) {
                    self.error = "发送失败: \(error.localizedDescription)"
                    Haptics.error()
                }
                splitter.flushTail()
                applyBubbleEmissions(splitter.drain())
            }
            pending = false
            chatTurnTask = nil
        }
    }

    // MARK: - Lookback notes (invisible context-edit notes from the bot)

    private struct LookbackNote: Identifiable, Equatable {
        let id: String
        let body_md: String
        let active: Bool
    }

    private func loadActiveLookbacks() async {
        struct Row: Decodable {
            let id: String
            let body_md: String
            let active: Bool
        }
        do {
            let rows: [Row] = try await SupabaseStack.shared.database
                .from("bot_lookbacks")
                .select("id, body_md, active")
                .eq("conversation_id", value: conversation.id)
                .eq("active", value: true)
                .order("created_at", ascending: true)
                .execute()
                .value
            self.activeLookbacks = rows.map { LookbackNote(id: $0.id, body_md: $0.body_md, active: true) }
        } catch {
            // Lookbacks are an enhancement — silent fail.
            print("[lookback] load failed:", error.localizedDescription)
        }
    }

    private func applyLookbackEvent(_ event: LookbackEvent) {
        let r = event.record
        guard let id = r["id"]?.stringValue else { return }
        let body = r["body_md"]?.stringValue ?? ""
        let active = (r["active"]?.boolValue) ?? true
        if active {
            // INSERT (new note) or UPDATE that brought it back. Replace by id.
            if let idx = activeLookbacks.firstIndex(where: { $0.id == id }) {
                activeLookbacks[idx] = LookbackNote(id: id, body_md: body, active: true)
            } else {
                activeLookbacks.append(LookbackNote(id: id, body_md: body, active: true))
                // New note arrived — schedule auto-fire after 30s of user silence
                // (skip if a turn is already in flight: the next user reply or
                // the in-flight reply will pick the lookback up via prompt).
                if chatTurnTask == nil {
                    scheduleLookbackAutoFire()
                }
            }
        } else {
            // active=false → bot retired this note (via [DROP_LOOKBACK]).
            activeLookbacks.removeAll { $0.id == id }
        }
    }

    private func scheduleLookbackAutoFire() {
        lookbackAutoFireTask?.cancel()
        lookbackAutoFireTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            if Task.isCancelled { return }
            // Re-check: still no in-flight turn, still some active lookbacks?
            guard chatTurnTask == nil, !activeLookbacks.isEmpty else { return }
            sendViaSSE(text: "", attachmentIds: [], autoLookback: true)
        }
    }

    /// Realtime postgres_changes payload → ChatMessage in the local list.
    /// Dedupe by canonical row id so this device's own SSE-emitted bubbles
    /// (which carry "live-<uuid>" ids until reconciled) get either skipped
    /// or replaced cleanly. role='log' rows are filtered out (rendered via
    /// a different surface).
    private func applyRealtimeEvent(_ event: MessageEvent) {
        let r = event.record
        guard let id = r["id"]?.stringValue,
              r["conversation_id"]?.stringValue == conversation.id else { return }
        let role = r["role"]?.stringValue ?? "user"
        if role == "log" { return }
        let content = r["content"]?.stringValue ?? ""
        let createdRaw = r["created_at"]?.stringValue ?? ""
        let secs = ISO8601DateFormatter().date(from: createdRaw)
            .map { Int($0.timeIntervalSince1970) } ?? Int(Date().timeIntervalSince1970)
        let senderType = role == "bot" ? "bot" : "user"
        let senderId = role == "bot"
            ? (r["sender_bot_id"]?.stringValue ?? "")
            : (r["user_id"]?.stringValue ?? "")
        let msg = ChatMessage(
            id: id,
            conversation_id: conversation.id,
            sender_type: senderType,
            sender_id: senderId,
            content: content,
            created_at: secs,
            attachments: nil
        )
        if let existing = messages.firstIndex(where: { $0.id == id }) {
            messages[existing] = msg
        } else {
            // Drop our own optimistic local row if we can match it by content +
            // role + recency (within 5s) — this avoids duplicate user bubbles
            // when the canonical row arrives after our local-<uuid> echo.
            let now = Int(Date().timeIntervalSince1970)
            if let stale = messages.firstIndex(where: { m in
                m.id.hasPrefix("local-") || m.id.hasPrefix("live-")
                    && m.sender_type == senderType
                    && m.content == content
                    && abs(m.created_at - now) < 5
            }) {
                messages[stale] = msg
            } else {
                messages.append(msg)
            }
        }
        // Mirror to local cache.
        LocalDatabase.shared.upsertMessages([
            LocalDatabase.MessageRow(
                id: id,
                client_message_id: r["client_message_id"]?.stringValue,
                conversation_id: conversation.id,
                user_id: r["user_id"]?.stringValue,
                sender_bot_id: r["sender_bot_id"]?.stringValue,
                role: role,
                content: content,
                status: r["status"]?.stringValue,
                created_at: secs
            ),
        ])
    }

    /// Translate splitter emissions into mutations on the local `messages`
    /// array. Begin = append a new bot message; append = mutate the last
    /// one's content; end / turnDone / turnInterrupted are status signals
    /// (no-op for now since ChatMessage doesn't carry a streaming flag).
    private func applyBubbleEmissions(_ events: [BubbleEmission]) {
        for evt in events {
            switch evt {
            case .begin(let id, _, let content):
                messages.append(ChatMessage(
                    id: "live-\(id.uuidString)",
                    conversation_id: conversation.id,
                    sender_type: "bot",
                    sender_id: conversation.bot_id ?? "",
                    content: content,
                    created_at: Int(Date().timeIntervalSince1970),
                    attachments: nil
                ))
            case .append(let id, let delta):
                let key = "live-\(id.uuidString)"
                if let idx = messages.lastIndex(where: { $0.id == key }) {
                    let prev = messages[idx]
                    messages[idx] = ChatMessage(
                        id: prev.id, conversation_id: prev.conversation_id,
                        sender_type: prev.sender_type, sender_id: prev.sender_id,
                        content: prev.content + delta,
                        created_at: prev.created_at,
                        attachments: prev.attachments
                    )
                }
            case .end, .turnDone, .turnInterrupted:
                break
            case .error(let m):
                self.error = m
            }
        }
    }

    // ── REST: history + delete ─────────────────────────────────────────────

    private func loadSkills() async {
        // Skills load left disabled until /v1/skills lands. The chip stays
        // empty; chat is unaffected.
        self.skills = []
    }

    private func loadHistory() async {
        // Hydrate from local cache instantly so the conv opens with last-known
        // content even if the user is offline / on a flaky network.
        let cached = LocalDatabase.shared.loadMessages(conversationId: conversation.id)
        if !cached.isEmpty {
            self.messages = cached.map { r in
                ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: r.role == "bot" ? "bot" : "user",
                    sender_id: r.role == "bot" ? (r.sender_bot_id ?? "") : (r.user_id ?? ""),
                    content: r.content ?? "",
                    created_at: r.created_at,
                    attachments: nil
                )
            }
        }

        do {
            // Direct Supabase read — RLS gates participation. Excludes role='log'
            // (review/surf step entries) which are rendered separately.
            struct Row: Decodable {
                let id: String
                let client_message_id: String?
                let conversation_id: String
                let user_id: String?
                let sender_bot_id: String?
                let role: String
                let content: String?
                let status: String?
                let created_at: String
            }
            let rows: [Row] = try await SupabaseStack.shared.database
                .from("messages")
                .select("id, client_message_id, conversation_id, user_id, sender_bot_id, role, content, status, created_at")
                .eq("conversation_id", value: conversation.id)
                .neq("role", value: "log")
                .order("created_at", ascending: true)
                .limit(200)
                .execute()
                .value
            let fmt = ISO8601DateFormatter()
            // Translate to view model + cache rows in one pass.
            var viewMessages: [ChatMessage] = []
            var cacheRows: [LocalDatabase.MessageRow] = []
            viewMessages.reserveCapacity(rows.count)
            cacheRows.reserveCapacity(rows.count)
            for r in rows {
                let senderType: String = r.role == "bot" ? "bot"
                    : r.role == "log" ? "system" : "user"
                let senderId = r.role == "bot" ? (r.sender_bot_id ?? "") : (r.user_id ?? "")
                let secs = fmt.date(from: r.created_at).map { Int($0.timeIntervalSince1970) } ?? 0
                viewMessages.append(ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: senderType,
                    sender_id: senderId,
                    content: r.content ?? "",
                    created_at: secs,
                    attachments: nil
                ))
                cacheRows.append(LocalDatabase.MessageRow(
                    id: r.id,
                    client_message_id: r.client_message_id,
                    conversation_id: r.conversation_id,
                    user_id: r.user_id,
                    sender_bot_id: r.sender_bot_id,
                    role: r.role,
                    content: r.content,
                    status: r.status,
                    created_at: secs
                ))
            }
            self.messages = viewMessages
            LocalDatabase.shared.upsertMessages(cacheRows)
        } catch {
            // Network down + we have a cache: stay quiet (cached msgs still
            // visible). Show the error only if we have nothing to display.
            if messages.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    /// Apply a model pick from the settings sheet. The user chose a scope:
    ///   - `.conversation` — only this conversation; sets/clears the
    ///     per-conversation override on the server.
    ///   - `.bot` — this bot for this user across all conversations; sets
    ///     the per-user-per-bot override AND clears the per-conv override
    ///     so this conversation actually picks up the new default.
    private func applyModelPick(slug: String?, scope: ModelPickScope) async {
        let normalized = slug.flatMap { $0.isEmpty ? nil : $0 }
        switch scope {
        case .conversation:
            modelOverride = normalized ?? ""
            await patchConversationModel(slug: normalized)
        case .bot:
            // Clear the per-conv pin so the new bot default wins here too.
            modelOverride = ""
            await patchConversationModel(slug: nil)
            await patchBotUserModel(slug: normalized)
        }
    }

    private func patchConversationModel(slug: String?) async {
        guard let api else { return }
        struct Body: Encodable { let modelOverride: String? }
        do {
            _ = try await api.patch(
                "api/mobile/conversations/\(conversation.id)",
                body: Body(modelOverride: slug)
            ) as EmptyResponse
            Haptics.success()
            onChange()
        } catch {
            self.error = "更换模型失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func patchBotUserModel(slug: String?) async {
        guard let api else { return }
        let botId = bot?.id ?? conversation.bot_id
        struct Body: Encodable { let model: String? }
        struct Reply: Decodable { let ok: Bool; let user_model: String? }
        do {
            _ = try await api.patch(
                "api/mobile/bots/\(botId)",
                body: Body(model: slug)
            ) as Reply
            Haptics.success()
            // Bot.model is a let on a struct passed in from the parent — we
            // can't mutate it locally. The parent list refreshes via
            // onChange() (covers both list refresh and reopened-conversation
            // flows); next reopen will reflect the new resolved model.
            onChange()
        } catch {
            self.error = "更换机器人模型失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func deleteMessage(_ msg: ChatMessage) async {
        guard let api else { return }
        do {
            try await api.deleteVoid("api/mobile/messages/\(msg.id)")
            messages.removeAll { $0.id == msg.id }
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // ── Image upload ────────────────────────────────────────────────────────

    private func ingestPhotos(_ items: [PhotosPickerItem]) async {
        guard let api else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
            do {
                let response: UploadResponse = try await api.upload(
                    "api/upload/",
                    fileData: data,
                    fileName: "image-\(UUID().uuidString.prefix(8)).\(ext)",
                    mime: mime,
                    extraFields: ["conversationId": conversation.id]
                )
                pendingAttachments.append(PendingAttachment(
                    id: response.id, mime: response.mime, size: response.size
                ))
                Haptics.tap()
            } catch {
                self.error = "上传失败: \(error.localizedDescription)"
                Haptics.error()
            }
        }
        photoPickerItems = []
    }

    /// Same upload flow as `ingestPhotos`, but for one-shot camera captures.
    /// JPEG-encode at 0.85 (same balance the rest of the app uses) so the
    /// upload size matches what users get from the library picker.
    private func ingestCameraImage(_ image: UIImage) async {
        defer { cameraImage = nil }
        guard let api, let data = image.jpegData(compressionQuality: 0.85) else { return }
        do {
            let response: UploadResponse = try await api.upload(
                "api/upload/",
                fileData: data,
                fileName: "camera-\(UUID().uuidString.prefix(8)).jpg",
                mime: "image/jpeg",
                extraFields: ["conversationId": conversation.id]
            )
            pendingAttachments.append(PendingAttachment(
                id: response.id, mime: response.mime, size: response.size
            ))
            Haptics.tap()
        } catch {
            self.error = "上传失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}

/// Soft pulsing globe — telegraphs that a web lookup is in flight without
/// the harshness of a spinner. Two stacked breathing strokes around a
/// muted-accent globe glyph.
private struct PulsingGlobe: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.accent.opacity(pulse ? 0.0 : 0.35), lineWidth: 1)
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.4 : 0.9)
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent.opacity(0.9))
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

struct PendingAttachment: Identifiable, Hashable {
    let id: String
    let mime: String
    let size: Int
}

/// Identifiable wrapper so a `String` body can drive a `.sheet(item:)` —
/// SwiftUI wants an `Identifiable` payload to disambiguate presentations.
private struct SkillDraft: Identifiable {
    let body: String
    var id: String { String(body.hashValue) }
}

