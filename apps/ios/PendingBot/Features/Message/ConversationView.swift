import SwiftUI
import PhotosUI
import UIKit
import OSLog
import Supabase

private let log = Logger.category("conversation")

/// One conversation. Loads history from Supabase, runs the user-direct
/// chat turn over Worker SSE (ChatStream), and listens for cross-device /
/// background-task messages via Supabase Realtime on the conv channel.
/// Identifies the peer for a conversation that hasn't been materialised in
/// the DB yet — set when the user taps a friend (bot or human) in the
/// friends tab. We defer creating the `conversations` row until they
/// actually send a first message, so empty/abandoned chats don't pile up
/// in the message list.
struct PendingPeer: Hashable {
    let kind: String       // "bot" | "user"
    let peerId: String
    let displayName: String
}

struct ConversationView: View {
    @State var conversation: Conversation
    let bot: Bot?
    /// Mutable so the "+ new conv" header button can flip a materialized
    /// chat back to pending without reconstructing the view.
    @State var pendingPeer: PendingPeer?
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
    /// Per-conv LLM provider pin. nil = follow alias-weight routing
    /// (默认). Set via the conversation settings sheet; sent on each
    /// chat POST as `providerOverride` so the server persists it onto
    /// conversations.provider_override.
    @State private var providerOverride: String?
    /// True iff the user has touched the provider picker in THIS view
    /// instance. Distinguishes "no opinion, leave the row alone" from
    /// "user explicitly picked 自动 → server should clear the row" — both
    /// would otherwise look like providerOverride == nil. We don't ride on
    /// (providerOverride != conversation.provider_override) because the
    /// row's value may itself be nil and we still need to clear it idempotently.
    @State private var providerOverrideTouched: Bool = false
    @State private var error: String?
    @State private var pending = false              // server is generating (bot_typing active)
    /// Active SSE turn task; canceling it closes the stream which Worker
    /// reads as request.signal.aborted (= interrupt). Set by sendViaSSE,
    /// cleared on completion. Non-nil while a turn is in flight.
    @State private var chatTurnTask: Task<Void, Never>?
    /// Realtime subscription token for this conv's `messages` channel —
    /// dropped when the view disappears. Picks up cross-device messages
    /// and bot rows that land via background paths (cron, review).
    @State private var realtimeToken: ConvSubscriptionToken?
    /// Lookback notes the bot wrote about prior turns (Realtime push from
    /// pendingbot.bot_lookbacks). Invisible to the user; passed in
    /// `activeLookbacks` on the next POST so the bot sees them as context.
    @State private var activeLookbacks: [LookbackNote] = []
    /// 30s grace timer started when a new lookback arrives. If user hasn't
    /// sent anything before it fires, we auto-trigger a continuation turn
    /// so the bot's fact-check actually surfaces.
    @State private var lookbackAutoFireTask: Task<Void, Never>?
    /// Tool-call trace per user message. Rendered inline (non-bubble, auto-
    /// collapsed) right after the user message that triggered it. Worker emits
    /// `tool_call` / `tool_result` SSE events during a turn — we accumulate
    /// them into the bucket for the in-flight `liveTraceUserMsgId`.
    @State private var tracesByUserMsgId: [String: [ToolTraceEvent]] = [:]
    /// Local id of the user message currently driving an SSE turn — set in
    /// sendViaSSE before the stream starts, cleared when the turn ends.
    /// Multiple traces can land for the same user msg if the agent loops.
    @State private var liveTraceUserMsgId: String?
    /// Web-search citations attached to a bot bubble, keyed by message id.
    /// Sources: history `select citations`, Realtime UPDATE on the row, and
    /// the per-turn `citations` SSE event copied to each in-flight bubble.
    /// `MarkdownText` reads the entry to resolve inline `[N]` markers.
    @State private var citationsByMsgId: [String: [MessageCitation]] = [:]
    /// Cumulative citations for the in-flight turn — last value pushed by the
    /// `citations` SSE event. Snapshotted onto each bubble created during
    /// the turn so the live preview can resolve `[N]` taps before the
    /// canonical row arrives via Realtime.
    @State private var liveCitations: [MessageCitation] = []
    /// Per-trace citations bucket so the inline `搜索` trace can list the
    /// hits it surfaced even after the turn ends + `liveCitations` resets.
    /// Keyed by user-message id like `tracesByUserMsgId`; rekeyed on the
    /// optimistic-id → canonical-id swap so re-expanding an old trace still
    /// shows its results.
    @State private var traceCitationsByUserMsgId: [String: [MessageCitation]] = [:]
    // Skill summaries — counted in the settings sheet so the user sees
    // how many are active without leaving the conversation.
    @State private var skills: [SkillSummary] = []
    @State private var showingSkills = false
    @State private var showingSettings = false
    @State private var saveAsSkillBody: String?

    // Streaming reveal smoother — see applyBubbleEmissions. Bubbles that the
    // splitter promotes to .streaming (≥ BUBBLE_OVERFLOW_CHARS without a
    // delimiter) appear empty and have their head buffer + subsequent live
    // tokens trickled in by `revealTask` at a fixed rate, giving a fast
    // typewriter catch-up effect instead of the old "pop in 15 chars then
    // stutter".
    @State private var revealTargetId: String?
    @State private var revealBuffer: String = ""
    @State private var revealEnded: Bool = false
    @State private var pendingEmissions: [BubbleEmission] = []
    @State private var revealTask: Task<Void, Never>?

    /// Canonical bot-row ids announced by the SSE `bubble` event but not yet
    /// reconciled with a Realtime INSERT. When the INSERT lands with one of
    /// these ids, we know it's *our own* turn echoing back and should
    /// replace the matching `live-*` optimistic bubble — regardless of how
    /// long the round-trip took. Without this, slow streams (>5s) used to
    /// blow past the recency-window dedup and the canonical row would
    /// append as a duplicate bubble.
    @State private var pendingCanonicalBotIds: Set<String> = []

    /// Other-side profile for a user_user conv, fetched once on appear
    /// when we don't already have a `pendingPeer`. Drives the chat
    /// header (title + avatar) and the left-side avatar on incoming
    /// bubbles.
    struct ResolvedPeer { let userId: String; let displayName: String; let avatarPath: String? }
    @State private var resolvedPeer: ResolvedPeer?

    /// Group conv only — sender lookup keyed by "user:<id>" / "bot:<id>"
    /// so each bubble can render its own avatar + nickname above the
    /// content. Loaded on appear via loadGroupSenders(); 1v1 stays nil
    /// and the existing peerProfile path serves it.
    @State private var groupSenders: [String: GroupBubbleSender] = [:]

    /// Group conv only — when the GroupRouterDO held back a bot turn
    /// because the last 30s of messages was bot-only, it filed a
    /// pending continue request. The banner above the composer renders
    /// allow / deny buttons; either decision posts a normal user
    /// message *and* unblocks (or kills) the held bots.
    struct PendingContinue: Equatable {
        let id: String
        let pendingBotIds: [String]
    }
    @State private var pendingContinue: PendingContinue?
    @State private var continueDeciding: Bool = false

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

    /// Seed for the avatar's emoji glyph. Always tied to bot identity so
    /// the same bot keeps its face across every conv you have with it.
    /// Falls back to the conv id (used for user_user / group chats where
    /// there is no single bot).
    private var avatarEmojiSeed: String {
        conversation.bot_id.isEmpty ? conversation.id : conversation.bot_id
    }

    /// Avatar shown in the chat header / empty-state. For self-chat the
    /// "other side" IS the user — render their UserAvatar (uploaded
    /// photo when present) instead of the bot's BotAvatar glyph.
    @ViewBuilder
    private func headerAvatar(size: CGFloat) -> some View {
        if let s = bubbleSelfAvatar {
            UserAvatar(seed: s.seed, attachmentId: s.attachmentId, size: size)
        } else if let peer = peerProfileForBubble {
            // user_user — the other person's avatar is what reads as
            // "this conversation". Match the bubble side's avatar so the
            // header and the incoming bubbles look like one identity.
            UserAvatar(seed: peer.userId, attachmentId: peer.avatarPath, size: size)
        } else {
            BotAvatar(
                emojiSeed: avatarEmojiSeed,
                colorSeed: conversation.id,
                size: size
            )
        }
    }

    /// Self-chat → the user's avatar replaces the bot avatar. Returns
    /// nil for any other conv type so callers fall back to BotAvatar.
    private var bubbleSelfAvatar: (seed: String, attachmentId: String?)? {
        guard conversation.conversation_type == "self" else { return nil }
        let store = AccountStore.shared
        let seed = store.avatarSeed
            ?? store.current?.id ?? avatarEmojiSeed
        return (seed: seed, attachmentId: store.avatarAttachmentId)
    }

    /// Peer profile for the *other* person in a user_user conv. Drives
    /// the left-side avatar that BubbleView renders on incoming bubbles.
    /// Sourced from `pendingPeer` when we navigated in from a friends-tab
    /// tap; once a backend lookup endpoint is wired the receiver side
    /// will fill `resolvedPeer` instead. Avatar attachment-id is nil for
    /// now — the friends list itself uses a generic person glyph and we
    /// don't yet expose other users' uploaded avatars.
    private var peerProfileForBubble: (userId: String, displayName: String, avatarPath: String?)? {
        guard conversation.conversation_type == "user_user" else { return nil }
        if let p = resolvedPeer {
            return (userId: p.userId, displayName: p.displayName, avatarPath: p.avatarPath)
        }
        if let p = pendingPeer, p.kind == "user" {
            return (userId: p.peerId, displayName: p.displayName, avatarPath: nil)
        }
        return nil
    }

    /// Header title — for user_user, prefer the peer's display name (or
    /// caller's local alias) so the header doesn't read "未命名" on convs
    /// whose `title` column is null. Falls back to the conversation's
    /// stored title for every other conv type.
    private var headerTitle: String {
        if conversation.conversation_type == "user_user",
           let peer = peerProfileForBubble,
           !peer.displayName.isEmpty {
            return peer.displayName
        }
        return conversation.displayTitle
    }

    private func shortSlug(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    init(conversation: Conversation, bot: Bot?, pendingPeer: PendingPeer? = nil,
         onChange: @escaping () -> Void = {}) {
        self._conversation = State(initialValue: conversation)
        self.bot = bot
        self._pendingPeer = State(initialValue: pendingPeer)
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
                                       botID: avatarEmojiSeed,
                                       selfAvatar: bubbleSelfAvatar,
                                       currentUserId: AccountStore.shared.current?.id,
                                       peerProfile: peerProfileForBubble,
                                       groupSender: groupSenderFor(msg),
                                       serverURL: account?.workerURL,
                                       citations: citationsByMsgId[msg.id] ?? [])
                                .id(msg.id)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = msg.content
                                        Haptics.tap()
                                    } label: { Label("复制", systemImage: "doc.on.doc") }
                                    if !msg.isMine(currentUserId: AccountStore.shared.current?.id) {
                                        ShareLink(item: msg.content) {
                                            Label("分享", systemImage: "square.and.arrow.up")
                                        }
                                        if msg.sender_type == "bot" {
                                            // 保存为技能 only makes sense for bot output;
                                            // for human peers the menu just gets 复制 / 分享 / 删除.
                                            Button {
                                                saveAsSkillBody = msg.content
                                                Haptics.tap()
                                            } label: {
                                                Label("保存为技能", systemImage: "square.and.arrow.down.on.square")
                                            }
                                        }
                                    }
                                    Button(role: .destructive) {
                                        Task { await deleteMessage(msg) }
                                    } label: { Label("删除", systemImage: "trash") }
                                }
                                .transition(.blurReplace)
                            // Tool-call trace sits between the user msg that
                            // triggered the turn and the bot's reply. Hidden
                            // when the bucket is empty so plain (non-search)
                            // turns look identical to before. Only ever
                            // attached to user_bot turns, so the simple
                            // sender_type check is enough — no need to
                            // disambiguate by sender_id here.
                            if msg.sender_type == "user", let trace = tracesByUserMsgId[msg.id], !trace.isEmpty {
                                ToolTraceView(
                                    events: trace,
                                    isLive: liveTraceUserMsgId == msg.id,
                                    citations: traceCitationsByUserMsgId[msg.id] ?? []
                                )
                                .id("trace:\(msg.id)")
                                .transition(.opacity)
                            }
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
                if let pc = pendingContinue {
                    continueRequestBanner(pc)
                        .readableColumnWidth()
                }
                if conversation.conversation_type == "group",
                   let prefix = mentionPrefix {
                    mentionPickerOverlay(prefix: prefix)
                        .readableColumnWidth()
                }
                Divider().opacity(0.5)
                ComposerView(
                    input: $input,
                    pending: $pendingAttachments,
                    photoItems: $photoPickerItems,
                    cameraImage: $cameraImage,
                    canSend: canSend,
                    onSend: { Task { await send() } },
                    isStreaming: chatTurnTask != nil,
                    onStop: {
                        chatTurnTask?.cancel()
                        flushRevealImmediately()
                    }
                )
                .readableColumnWidth()
            }
        }
        .task {
            modelOverride = conversation.model_override ?? ""
            providerOverride = conversation.provider_override
            // Pending convs (lazy-created on first send) have no row yet —
            // skip history / skills / realtime until they materialise.
            guard !conversation.id.isEmpty else { return }
            await loadHistory()
            await loadSkills()
            await loadActiveLookbacks()
            await subscribeRealtime()
            await loadPeerProfileIfNeeded()
            await loadGroupSendersIfNeeded()
            await loadPendingContinueIfNeeded()
        }
        .onDisappear {
            if let token = realtimeToken {
                Task { await RealtimeManager.shared.stopConvChannel(token) }
                realtimeToken = nil
            }
            lookbackAutoFireTask?.cancel()
            lookbackAutoFireTask = nil
            revealTask?.cancel()
            revealTask = nil
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
        .navigationDestination(isPresented: $showingSettings) {
            // Group convs route to GroupSettingsView (members, nickname,
            // mute, leave). Owner/admin-only knobs (billing, handle,
            // policy, approval inbox) live as sub-screens of that view.
            // Other conv types (user_bot / user_user / self) keep the
            // existing ConversationSettingsView with model + provider
            // overrides.
            if conversation.conversation_type == "group" {
                GroupSettingsView(conversationId: conversation.id)
            } else {
                ConversationSettingsView(
                    modelOverride: $modelOverride,
                    providerOverride: $providerOverride,
                    conversationId: conversation.id,
                    enabledSkillCount: skills.filter { $0.enabled }.count,
                    totalSkillCount: skills.count,
                    onOpenSkills: { showingSkills = true },
                    onApplyModel: { slug, scope in
                        Task { await applyModelPick(slug: slug, scope: scope) }
                    },
                    onApplyProvider: { slug in
                        // Local-only update; the value rides with the next chat
                        // POST. We deliberately don't fire a separate PATCH —
                        // /v1/messages persists provider_override server-side
                        // when the body field differs from the row.
                        providerOverride = slug
                        providerOverrideTouched = true
                        Haptics.tap()
                    }
                )
            }
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
            headerAvatar(size: 64)
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

            headerAvatar(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
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
            if canStartNewBotConv {
                Button {
                    Haptics.tap()
                    Task { await startNewBotConv() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建对话")
            }
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

    // ── Send ────────────────────────────────────────────────────────────────

    private func subscribeRealtime() async {
        let convId = conversation.id
        guard !convId.isEmpty else { return }
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

    /// Show the "+ new conv" header button only for materialized chats with
    /// an identifiable bot — pending convs and user_user/self chats can't
    /// fork-new-with-same-bot.
    private var canStartNewBotConv: Bool {
        guard !conversation.id.isEmpty else { return false }
        if conversation.conversation_type != "user_bot" { return false }
        if let bid = bot?.id, !bid.isEmpty { return true }
        return !conversation.bot_id.isEmpty
    }

    /// Flip this view onto a fresh pending user_bot conv with the same bot.
    /// No DB row is created here — the conv materialises on first send via
    /// `materializeIfPending`, so backing out without sending leaves no
    /// trace. Mirrors the friends-tab tap path.
    private func startNewBotConv() async {
        let botId: String = {
            if let bid = bot?.id, !bid.isEmpty { return bid }
            return conversation.bot_id
        }()
        guard !botId.isEmpty,
              let userId = AccountStore.shared.current?.id else {
            self.error = "无法新建对话"
            return
        }
        chatTurnTask?.cancel()
        chatTurnTask = nil
        flushRevealImmediately()
        lookbackAutoFireTask?.cancel()
        lookbackAutoFireTask = nil
        if let token = realtimeToken {
            await RealtimeManager.shared.stopConvChannel(token)
            realtimeToken = nil
        }
        let displayName = bot?.display_name ?? conversation.bot_name ?? botId
        conversation = Conversation(
            id: "", bot_id: botId, user_id: userId,
            title: displayName, feature_type: "message",
            conversation_type: "user_bot",
            last_activity_at: Int(Date().timeIntervalSince1970),
            round_count: 0, bot_name: displayName,
            last_message_content: nil, last_message_sender_type: nil,
            model_override: nil,
            provider_override: nil
        )
        pendingPeer = PendingPeer(kind: "bot", peerId: botId, displayName: displayName)
        messages = []
        input = ""
        pendingAttachments = []
        photoPickerItems = []
        activeLookbacks = []
        modelOverride = ""
    }

    /// Create the conv row (and participant rows) for a pending conv whose
    /// peer was set in friends-tab tap. Returns true if the conv is now
    /// real (either we created it or it was already real).
    private func materializeIfPending() async -> Bool {
        if !conversation.id.isEmpty { return true }
        guard let peer = pendingPeer,
              let userId = AccountStore.shared.current?.id else {
            self.error = "无法创建会话"
            return false
        }
        do {
            let convId: String
            switch peer.kind {
            case "bot":
                // Atomic conv + participants insert via security-definer RPC
                // (migration 0011). Avoids the iOS-side RLS class entirely.
                struct RpcArgs: Encodable { let p_bot_id: String }
                let newId: UUID = try await SupabaseStack.shared
                    .rpc("open_user_bot_conv",
                         params: RpcArgs(p_bot_id: peer.peerId))
                    .execute()
                    .value
                convId = newId.uuidString.lowercased()
                conversation = Conversation(
                    id: convId, bot_id: peer.peerId, user_id: userId,
                    title: peer.displayName, feature_type: "message",
                    conversation_type: "user_bot",
                    last_activity_at: Int(Date().timeIntervalSince1970),
                    round_count: 0, bot_name: peer.displayName,
                    last_message_content: nil, last_message_sender_type: nil,
                    model_override: nil,
                    provider_override: nil
                )
            case "user":
                // Hand off to Worker — its open-chat endpoint inserts both
                // sides of the participant rows in a single trip. Worker
                // also gates the call on a mutual-contact relationship,
                // so a stale friends-list row whose contact has since been
                // removed lands here as a clean 403 we can surface.
                var req = URLRequest(url: HostedConfig.environment.workerURL
                    .appendingPathComponent("v1/contacts/open-chat"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let token = try await SupabaseStack.shared.auth.session.accessToken
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONSerialization.data(
                    withJSONObject: ["contactUserId": peer.peerId])
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let msg = (body?["error"] as? String) ?? "无法开启聊天 (HTTP \(http.statusCode))"
                    self.error = msg
                    return false
                }
                struct OpenChat: Decodable { let conversationId: String }
                let payload = try JSONDecoder().decode(OpenChat.self, from: data)
                convId = payload.conversationId
                conversation = Conversation(
                    id: convId, bot_id: "", user_id: userId,
                    title: peer.displayName, feature_type: "message",
                    conversation_type: "user_user",
                    last_activity_at: Int(Date().timeIntervalSince1970),
                    round_count: nil, bot_name: nil,
                    last_message_content: nil, last_message_sender_type: nil,
                    model_override: nil,
                    provider_override: nil
                )
            case "self":
                // Singleton self-chat conv. RPC is find-or-create so
                // re-tapping the friends-tab self row reuses the same
                // conv (and its history) instead of stacking.
                let newId: UUID = try await SupabaseStack.shared
                    .rpc("open_self_conv")
                    .execute()
                    .value
                convId = newId.uuidString.lowercased()
                conversation = Conversation(
                    id: convId, bot_id: "", user_id: userId,
                    title: peer.displayName, feature_type: "message",
                    conversation_type: "self",
                    last_activity_at: Int(Date().timeIntervalSince1970),
                    round_count: 0, bot_name: peer.displayName,
                    last_message_content: nil, last_message_sender_type: nil,
                    model_override: nil,
                    provider_override: nil
                )
            default:
                self.error = "未知会话类型"
                return false
            }
            await subscribeRealtime()
            onChange()
            return true
        } catch {
            self.error = "创建会话失败: \(error.localizedDescription)"
            Haptics.error()
            return false
        }
    }

    private func send() async {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespaces)
        let attachIds = pendingAttachments.map(\.id)
        let attachmentSnapshot = pendingAttachments
        input = ""
        pendingAttachments = []
        photoPickerItems = []
        Haptics.send()

        // user_bot: optimistic — drop the bubble in immediately, light the
        // typing indicator, then materialise the conv (if pending) and kick
        // off SSE in the background. From the user's POV the new conv is
        // already "live" the moment they hit send; if the materialise round-
        // trip or the SSE turn fails before the canonical row lands, the
        // row gets flipped to .failed (red) and we surface the error alert.
        let isUserBot = conversation.conversation_type != "user_user"
                     && conversation.conversation_type != "group"
        if isUserBot {
            let localId = "local-\(UUID().uuidString)"
            // Stamp sender_id with the current user — without it the
            // ChatMessage.isMine(currentUserId:) check that drives bubble
            // side can't tell our own optimistic row from a peer's, and
            // the bubble would render on the wrong side until the
            // canonical Realtime row arrives.
            let myId = AccountStore.shared.current?.id ?? ""
            messages.append(ChatMessage(
                id: localId,
                conversation_id: conversation.id,
                sender_type: "user", sender_id: myId,
                content: text,
                created_at: Int(Date().timeIntervalSince1970),
                attachments: attachmentSnapshot.map {
                    Attachment(id: $0.id, kind: "image", mime: $0.mime, size: $0.size,
                               width: nil, height: nil, url: "/uploads/\($0.id)")
                },
                status: "sending"
            ))
            // Light the typing indicator now so the gap between bubble +
            // first bot token reads as "working" instead of "stuck".
            pending = true

            if conversation.id.isEmpty {
                let ok = await materializeIfPending()
                guard ok else {
                    markUserMessageFailed(localId)
                    pending = false
                    return
                }
                // Bubble was inserted with conversation_id="" — refresh it
                // in place so realtime dedupe (which keys on conv id +
                // content) works when the canonical row arrives.
                if let idx = messages.firstIndex(where: { $0.id == localId }) {
                    let prev = messages[idx]
                    messages[idx] = ChatMessage(
                        id: prev.id,
                        conversation_id: conversation.id,
                        sender_type: prev.sender_type, sender_id: prev.sender_id,
                        content: prev.content,
                        created_at: prev.created_at,
                        attachments: prev.attachments,
                        status: "sending"
                    )
                }
            }

            // Conv exists now — clear the optimistic-sending tint and
            // hand off to the SSE turn. SSE failures repaint the bubble
            // red from inside sendViaSSE's catch.
            clearUserMessageStatus(localId)
            sendViaSSE(text: text, attachmentIds: attachIds, userMsgId: localId)
            return
        }

        // user_user / group: still need a real conv id before INSERT, since
        // those go straight to Postgres without an SSE handshake. The
        // existing flow (await materialise, then insert) is correct here —
        // the round-trip is cheap relative to bot turns and there's no
        // typing indicator to play hide-and-seek with.
        if conversation.id.isEmpty {
            let ok = await materializeIfPending()
            guard ok else {
                input = text
                return
            }
        }
        await sendPlainUserMessage(text)
    }

    /// Flip an in-flight optimistic user row to .failed (red bubble + alert).
    /// No-op if the row has already been replaced by its canonical Realtime
    /// version — that means the message did persist and we shouldn't pretend
    /// otherwise.
    private func markUserMessageFailed(_ localId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == localId }) else { return }
        let prev = messages[idx]
        messages[idx] = ChatMessage(
            id: prev.id, conversation_id: prev.conversation_id,
            sender_type: prev.sender_type, sender_id: prev.sender_id,
            content: prev.content, created_at: prev.created_at,
            attachments: prev.attachments, status: "failed"
        )
        Haptics.error()
    }

    /// Drop the .sending tint once the conv exists / SSE has begun. The
    /// canonical row that arrives via Realtime will replace this row
    /// outright (with status=nil), so this is just a brief pre-replace
    /// state where the bubble looks "sent" without yet being persisted.
    private func clearUserMessageStatus(_ localId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == localId }),
              messages[idx].status != nil else { return }
        let prev = messages[idx]
        messages[idx] = ChatMessage(
            id: prev.id, conversation_id: prev.conversation_id,
            sender_type: prev.sender_type, sender_id: prev.sender_id,
            content: prev.content, created_at: prev.created_at,
            attachments: prev.attachments, status: nil
        )
    }

    private func sendPlainUserMessage(_ text: String) async {
        // group convs MUST go through POST /v1/messages so the worker can
        // (a) parse @-mentions, (b) signal GroupRouterDO to wake bots, and
        // (c) book the cost split. A direct INSERT into `messages` would
        // skip all three. user_user stays direct — no bots, no router.
        if conversation.conversation_type == "group" {
            await sendGroupUserMessage(text)
        } else {
            await sendUserUserMessage(text)
        }
    }

    private func sendUserUserMessage(_ text: String) async {
        guard let userId = AccountStore.shared.current?.id else { return }
        struct Insert: Encodable {
            let client_message_id: String
            let conversation_id: String
            let user_id: String
            let role = "user"
            let status = "done"
            let content: String
        }
        do {
            try await SupabaseStack.shared
                .from("messages")
                .insert(Insert(
                    client_message_id: UUID().uuidString.lowercased(),
                    conversation_id: conversation.id,
                    user_id: userId,
                    content: text
                ))
                .execute()
        } catch {
            self.error = "发送失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func sendGroupUserMessage(_ text: String) async {
        struct Body: Encodable {
            let conversationId: String
            let clientMessageId: String
            let newMessage: String
        }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/messages")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(
                conversationId: conversation.id,
                clientMessageId: UUID().uuidString.lowercased(),
                newMessage: text,
            ))
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "GroupSend",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            // Realtime delivers the canonical message row + any bot
            // replies that the GroupRouterDO wakes — we just return.
        } catch {
            self.error = "发送失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    /// Start the bot reply over SSE. Bubble emissions land in `messages`
    /// via incremental insert/update. Cancel the returned Task (via the
    /// stop button) to close the SSE — Worker observes request.signal.aborted
    /// and stops the LLM stream.
    private func sendViaSSE(text: String, attachmentIds: [String], autoLookback: Bool = false, userMsgId: String? = nil) {
        chatTurnTask?.cancel()
        flushRevealImmediately()
        // User taking action (or auto-fire firing) cancels the pending
        // 30s lookback grace timer either way.
        lookbackAutoFireTask?.cancel()
        lookbackAutoFireTask = nil
        pending = true
        // Bind the upcoming tool-trace bucket to the user message that
        // triggered this turn. Auto-fire turns (no user msg) skip this —
        // their tool calls have nowhere natural to attach in the list.
        liveTraceUserMsgId = userMsgId
        if let key = userMsgId {
            tracesByUserMsgId[key] = []
        }
        // Fresh citation slate for the new turn — last turn's snapshot
        // shouldn't leak into [N] resolutions for this turn's first bubble.
        liveCitations = []

        let body: [String: Any] = {
            let clientMsgId = UUID().uuidString.lowercased()
            // Exclude the just-appended optimistic user row — it gets sent
            // as `newMessage` and would otherwise show up to the LLM twice.
            let recent = messages.suffix(20)
                .filter { $0.id != userMsgId }
                .map { m -> [String: Any] in
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
                // IANA tz so the server can format the per-turn time hint in
                // the user's local clock (server only knows UTC otherwise).
                "clientTz": TimeZone.current.identifier,
            ]
            if !text.isEmpty { b["newMessage"] = text }
            if autoLookback { b["autoLookback"] = true }
            if !activeLookbacks.isEmpty {
                b["activeLookbacks"] = activeLookbacks.map { ["id": $0.id, "body_md": $0.body_md] }
            }
            if !attachmentIds.isEmpty { b["attachmentIds"] = attachmentIds }
            if let oldestId { b["oldestContextMessageId"] = oldestId }
            // Tri-state on the wire: only attach the field when the user
            // has expressed an opinion via the settings sheet. Server
            // treats absence as "leave the persisted row alone" — so a
            // device that never opened the picker can't accidentally
            // clobber another device's pin. NSNull = "user picked 自动,
            // please clear".
            if providerOverrideTouched {
                b["providerOverride"] = providerOverride ?? NSNull()
            }
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
                    case .bubble(let id, _, _, _):
                        // Server has persisted a bubble row with this id.
                        // Record it so when the corresponding Realtime
                        // INSERT lands we can FIFO-replace the matching
                        // `live-*` optimistic bubble cleanly — instead of
                        // relying on a recency window that fails for slow
                        // streams. The local `live-*` id remains the
                        // source of truth for the UI until then.
                        if !id.isEmpty { pendingCanonicalBotIds.insert(id) }
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
                    case .toolCall(let name, let input):
                        appendToolCall(name: name, input: input)
                    case .toolResult(let name, let summary, let error):
                        completeToolCall(name: name, summary: summary, error: error)
                    case .citations(let items):
                        // Update the per-turn snapshot AND backfill every
                        // bubble already created in this turn so an early
                        // bubble whose `[N]` resolves to a result returned
                        // by a later search becomes tappable retroactively.
                        liveCitations = items
                        for msg in messages where msg.id.hasPrefix("live-") {
                            citationsByMsgId[msg.id] = items
                        }
                        // Also stash a copy under the trace's user-msg key
                        // so the inline search trace keeps its results
                        // visible after the turn ends (`liveCitations` is
                        // reset at the next send, but the trace persists).
                        if let key = liveTraceUserMsgId {
                            traceCitationsByUserMsgId[key] = items
                        }
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
                    // Mid-turn failure: paint the user's message red so the
                    // failure attaches to a concrete bubble, not just a
                    // free-floating alert. No-op if the canonical row has
                    // already replaced the local- id (= server *did* save
                    // the message; the failure was downstream of the
                    // persisted user row, so don't lie about it).
                    if let userMsgId { markUserMessageFailed(userMsgId) }
                }
                splitter.flushTail()
                applyBubbleEmissions(splitter.drain())
            }
            pending = false
            chatTurnTask = nil
            // Trace bucket stays in tracesByUserMsgId so the user can keep
            // expanding it after the turn completes; only the live binding
            // is cleared here.
            liveTraceUserMsgId = nil
        }
    }

    // MARK: - Tool-call trace

    private func appendToolCall(name: String, input: String?) {
        guard let key = liveTraceUserMsgId else { return }
        var bucket = tracesByUserMsgId[key] ?? []
        bucket.append(ToolTraceEvent(name: name, input: input))
        tracesByUserMsgId[key] = bucket
    }

    private func completeToolCall(name: String, summary: String?, error: String?) {
        guard let key = liveTraceUserMsgId else { return }
        var bucket = tracesByUserMsgId[key] ?? []
        // Match the most recent unfinished event with the same tool name.
        // Bot can issue parallel tool calls; FIFO completion is wrong in
        // theory but right in practice for our current 2-tool surface.
        if let idx = bucket.lastIndex(where: { $0.name == name && !$0.done }) {
            bucket[idx].resultSummary = summary
            bucket[idx].resultError = error
            bucket[idx].done = true
        } else {
            // Result without a matching call (shouldn't happen but stay
            // defensive — the worker's emitter could miss a tool_call).
            var ev = ToolTraceEvent(name: name, input: nil)
            ev.resultSummary = summary
            ev.resultError = error
            ev.done = true
            bucket.append(ev)
        }
        tracesByUserMsgId[key] = bucket
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
            let rows: [Row] = try await SupabaseStack.shared
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
            log.warning("lookback load failed: \(error.localizedDescription, privacy: .public)")
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

    /// Decode a Realtime row's `citations` value into the typed model. Returns
    /// nil when absent / null / malformed — callers fall back to whatever was
    /// already in `citationsByMsgId` for the row (e.g. the live-bubble snapshot).
    private func parseCitations(from any: AnyJSON?) -> [MessageCitation]? {
        guard let any else { return nil }
        do {
            let data = try JSONEncoder().encode(any)
            // AnyJSON.null encodes as the literal "null" — short-circuit
            // before the array decoder throws on the wrong shape.
            if data.count == 4, String(data: data, encoding: .utf8) == "null" {
                return nil
            }
            return try JSONDecoder().decode([MessageCitation].self, from: data)
        } catch {
            return nil
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
        // Logs are server-only (review step entries) — never rendered here.
        if role == "log" { return }
        let content = r["content"]?.stringValue ?? ""
        let createdRaw = r["created_at"]?.stringValue ?? ""
        // Default to "now" so live messages don't collapse to 1970 if the
        // timestamp format ever drifts.
        let secs = ServerTimestamp.epochSeconds(createdRaw, default: Int(Date().timeIntervalSince1970))
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
        let citations = parseCitations(from: r["citations"])
        if let existing = messages.firstIndex(where: { $0.id == id }) {
            messages[existing] = msg
            if let citations { citationsByMsgId[id] = citations }
        } else {
            // Drop our own optimistic local/live row if we can match it.
            //
            // For bot rows, the SSE `bubble` event told us this canonical
            // id ahead of time → match by membership in
            // `pendingCanonicalBotIds`, then FIFO-replace the first
            // `live-*` bot bubble. This is timing-independent and handles
            // slow streams where the optimistic bubble is older than any
            // sensible recency window.
            //
            // For user rows we don't have a server-announced id (the user
            // message is materialized server-side without acking back),
            // so fall back to (prefix + role + recency) — same heuristic
            // as before, just bounded to user rows where it's accurate.
            //
            // We deliberately don't compare content for live-* bot bubbles:
            // they're still being revealed by the typewriter when the
            // canonical INSERT lands, so their displayed content is partial.
            let isOurBotEcho = role == "bot" && pendingCanonicalBotIds.contains(id)
            let now = Int(Date().timeIntervalSince1970)
            let staleIndex: Int? = {
                if isOurBotEcho {
                    return messages.firstIndex { m in
                        m.id.hasPrefix("live-") && m.sender_type == "bot"
                    }
                }
                if role != "bot" {
                    return messages.firstIndex { m in
                        m.id.hasPrefix("local-")
                            && m.sender_type == senderType
                            && abs(m.created_at - now) < 5
                    }
                }
                return nil
            }()
            if isOurBotEcho { pendingCanonicalBotIds.remove(id) }
            if let stale = staleIndex {
                let oldId = messages[stale].id
                messages[stale] = msg
                // Re-key any tool trace bound to the optimistic local id so
                // it stays attached after the canonical row replaces it.
                if let trace = tracesByUserMsgId.removeValue(forKey: oldId) {
                    tracesByUserMsgId[id] = trace
                    if liveTraceUserMsgId == oldId {
                        liveTraceUserMsgId = id
                    }
                }
                if let traceCites = traceCitationsByUserMsgId.removeValue(forKey: oldId) {
                    traceCitationsByUserMsgId[id] = traceCites
                }
                // Same rekey for citations — the live-id snapshot was set
                // from the SSE event; the canonical row may carry the same
                // (or fresher) list, so prefer the canonical when present.
                let priorCitations = citationsByMsgId.removeValue(forKey: oldId)
                citationsByMsgId[id] = citations ?? priorCitations
            } else {
                messages.append(msg)
                if let citations { citationsByMsgId[id] = citations }
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
    /// one's content; end / turnDone / turnInterrupted are status signals.
    ///
    /// Streaming bubbles get routed through the reveal smoother: `.begin`
    /// appends an empty bubble and stashes the head buffer for paced
    /// reveal; subsequent `.append` events feed that buffer; events that
    /// belong to *other* bubbles get queued behind so the next bubble
    /// doesn't appear before the typewriter is done.
    private func applyBubbleEmissions(_ events: [BubbleEmission]) {
        for evt in events {
            if let target = revealTargetId {
                switch evt {
                case .append(let id, let delta) where "live-\(id.uuidString)" == target:
                    revealBuffer += delta
                    continue
                case .end(let id) where "live-\(id.uuidString)" == target:
                    revealEnded = true
                    continue
                default:
                    pendingEmissions.append(evt)
                    continue
                }
            }
            applyDirect(evt)
        }
    }

    private func applyDirect(_ evt: BubbleEmission) {
        switch evt {
        case .begin(let id, let mode, let content):
            let key = "live-\(id.uuidString)"
            let initial = mode == .streaming ? "" : content
            messages.append(ChatMessage(
                id: key,
                conversation_id: conversation.id,
                sender_type: "bot",
                sender_id: conversation.bot_id,
                content: initial,
                created_at: Int(Date().timeIntervalSince1970),
                attachments: nil
            ))
            // Inherit the turn's accumulated citations so any [N] in the
            // bubble's content lands tappable from the first frame. The
            // canonical row's Realtime UPDATE later refreshes the same key
            // (after rekeying live-id → canonical id below).
            if !liveCitations.isEmpty {
                citationsByMsgId[key] = liveCitations
            }
            if mode == .streaming {
                revealTargetId = key
                revealBuffer = content
                revealEnded = false
                startRevealTaskIfNeeded()
            }
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
            // Worker sometimes emits an error event with an empty
            // `message` field (e.g. when the underlying error stringifies
            // to ""). Surface a placeholder so the user sees something
            // and we can grep the console log for the SSE event.
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            self.error = trimmed.isEmpty
                ? "服务端错误（空）— 请重试或检查网络"
                : trimmed
            log.error("worker error event: \(m, privacy: .public)")
            if let key = liveTraceUserMsgId { markUserMessageFailed(key) }
        }
    }

    // MARK: - Streaming reveal smoother

    /// Base reveal rate (chars/sec) — calibrated to ~60 tokens/sec, the
    /// rate mainstream LLMs stream at (1 token ≈ 3 chars across mixed
    /// Chinese/English content). Anything slower than the live stream
    /// just means the typewriter falls behind and the visible reveal
    /// jumps to the canonical row when Realtime lands. The adaptive drain
    /// in startRevealTaskIfNeeded still catches up if a provider bursts
    /// faster than this, so this is a "no slower than" floor.
    private static let revealCharsPerSec: Double = 180
    /// Cap on how far the visible reveal is allowed to lag behind the live
    /// stream. Anything queued beyond this many seconds of base-rate output
    /// gets drained on the current frame.
    private static let revealMaxBehindSec: Double = 0.1

    private func startRevealTaskIfNeeded() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            let frameNs: UInt64 = 16_000_000   // ~60 fps
            let perFrame = Self.revealCharsPerSec * Double(frameNs) / 1_000_000_000
            let maxBehindChars = Int(Self.revealCharsPerSec * Self.revealMaxBehindSec)
            var carry: Double = 0
            while !Task.isCancelled, revealTargetId != nil {
                try? await Task.sleep(nanoseconds: frameNs)
                carry += perFrame
                // Catch-up: if buffer holds more than maxBehindChars, drain
                // the overflow this frame so we don't lag behind a fast LLM.
                let baseAdvance = Int(carry)
                let overflow = max(0, revealBuffer.count - maxBehindChars)
                let advance = baseAdvance + overflow
                if advance > 0, !revealBuffer.isEmpty, let target = revealTargetId {
                    carry -= Double(baseAdvance)
                    let take = min(advance, revealBuffer.count)
                    let chunk = String(revealBuffer.prefix(take))
                    revealBuffer.removeFirst(take)
                    if let idx = messages.lastIndex(where: { $0.id == target }) {
                        let prev = messages[idx]
                        messages[idx] = ChatMessage(
                            id: prev.id, conversation_id: prev.conversation_id,
                            sender_type: prev.sender_type, sender_id: prev.sender_id,
                            content: prev.content + chunk,
                            created_at: prev.created_at,
                            attachments: prev.attachments
                        )
                    }
                }
                if revealEnded && revealBuffer.isEmpty {
                    let queued = pendingEmissions
                    pendingEmissions.removeAll()
                    revealTargetId = nil
                    revealEnded = false
                    revealTask = nil
                    if !queued.isEmpty {
                        applyBubbleEmissions(queued)
                    }
                    return
                }
            }
            revealTask = nil
        }
    }

    /// Skip the typewriter and apply everything pending immediately.
    /// Called when the user interrupts (Stop button), navigates away,
    /// or fires another send — they want the full content now, not the
    /// rest of the animation.
    private func flushRevealImmediately() {
        revealTask?.cancel()
        revealTask = nil
        if let target = revealTargetId, !revealBuffer.isEmpty,
           let idx = messages.lastIndex(where: { $0.id == target }) {
            let prev = messages[idx]
            messages[idx] = ChatMessage(
                id: prev.id, conversation_id: prev.conversation_id,
                sender_type: prev.sender_type, sender_id: prev.sender_id,
                content: prev.content + revealBuffer,
                created_at: prev.created_at,
                attachments: prev.attachments
            )
        }
        revealBuffer = ""
        revealTargetId = nil
        revealEnded = false
        let queued = pendingEmissions
        pendingEmissions.removeAll()
        // User wants everything visible now — force-flatten any queued
        // .begin(streaming) into complete bubbles so we don't kick off
        // another typewriter for the next bubble in the chain.
        for evt in queued {
            switch evt {
            case .begin(let id, _, let content):
                applyDirect(.begin(id: id, mode: .complete, content: content))
            default:
                applyDirect(evt)
            }
        }
    }

    // ── REST: history + delete ─────────────────────────────────────────────

    private func loadSkills() async {
        // Skills load left disabled until /v1/skills lands. The chip stays
        // empty; chat is unaffected.
        self.skills = []
    }

    /// Resolve the user_user peer's display name + avatar path so the
    /// header and incoming bubbles read as that person, not "未命名" + a
    /// generic glyph. Skips when we already have a `pendingPeer` (the
    /// friends-tab tap path supplies it eagerly) or when the conv is not
    /// user_user. RLS on `pendingbot.users` is self-only, so we go through
    /// the worker which uses service-role to read the peer row.
    private func loadPeerProfileIfNeeded() async {
        guard conversation.conversation_type == "user_user" else { return }
        guard !conversation.id.isEmpty else { return }
        if pendingPeer?.kind == "user" { return }
        if resolvedPeer != nil { return }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/conv-peer/\(conversation.id)")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return }
            struct Payload: Decodable {
                let userId: String
                let displayName: String
                let avatarPath: String?
                let alias: String?
            }
            let p = try JSONDecoder().decode(Payload.self, from: data)
            // Prefer the caller's local alias when set, otherwise the
            // peer's own display name. The avatar always uses the peer's
            // user id as the deterministic seed so it matches whatever
            // the friends list is rendering for the same person.
            let name = (p.alias?.isEmpty == false ? p.alias! : p.displayName)
            self.resolvedPeer = ResolvedPeer(
                userId: p.userId,
                displayName: name.isEmpty ? String(p.userId.prefix(8)) : name,
                avatarPath: p.avatarPath
            )
        } catch {
            // Non-fatal: header just keeps showing the existing fallback
            // until next reopen. Log via the conversation logger so it's
            // not silent in dev.
            log.warning("conv-peer load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Group-only — build the per-message sender lookup so each bubble
    /// can show its own avatar + nickname above the content. Pulls
    /// participants once on conv open; new senders that join mid-stream
    /// fall back to the avatar-only render until next conv reopen
    /// (Realtime delta sync for membership is M9 polish).
    private func loadGroupSendersIfNeeded() async {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty else { return }
        do {
            struct PartRow: Decodable {
                let participant_type: String
                let participant_id: String
                let nickname: String?
            }
            let parts: [PartRow] = try await SupabaseStack.shared
                .from("conversation_participants")
                .select("participant_type, participant_id, nickname")
                .eq("conversation_id", value: conversation.id)
                .execute()
                .value

            let botIds = parts.filter { $0.participant_type == "bot" }
                .map(\.participant_id)
            let userIds = parts.filter { $0.participant_type == "user" }
                .map(\.participant_id)

            struct BotRow: Decodable { let id: String; let display_name: String }
            struct UserRow: Decodable { let id: String; let display_name: String? }

            async let botResp: [BotRow] = botIds.isEmpty ? [] : SupabaseStack.shared
                .from("bots").select("id, display_name").in("id", values: botIds)
                .execute().value
            async let userResp: [UserRow] = userIds.isEmpty ? [] : SupabaseStack.shared
                .from("users").select("id, display_name").in("id", values: userIds)
                .execute().value

            let botMap = Dictionary(uniqueKeysWithValues:
                (try await botResp).map { ($0.id, $0.display_name) })
            let userMap = Dictionary(uniqueKeysWithValues:
                (try await userResp).map { ($0.id, $0.display_name ?? "") })

            var lookup: [String: GroupBubbleSender] = [:]
            for p in parts {
                let key = "\(p.participant_type):\(p.participant_id)"
                let fallback: String = {
                    if p.participant_type == "bot" {
                        return botMap[p.participant_id] ?? "未知机器人"
                    }
                    let name = userMap[p.participant_id] ?? ""
                    return name.isEmpty ? String(p.participant_id.prefix(8)) : name
                }()
                let nick = p.nickname?.trimmingCharacters(in: .whitespaces)
                let display = (nick?.isEmpty == false ? nick! : fallback)
                lookup[key] = GroupBubbleSender(
                    kind: p.participant_type == "bot" ? .bot : .user,
                    id: p.participant_id,
                    displayName: display,
                    avatarPath: nil,  // user avatars TBD; UserAvatar(seed:) is still distinct
                )
            }
            self.groupSenders = lookup
        } catch {
            log.warning("group senders load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pick the sender for a single bubble. Returns nil for non-group
    /// convs (BubbleView falls through to peerProfile/selfAvatar/botID),
    /// and also nil for our own messages so they keep the right-side
    /// "user" layout instead of being rendered as a bot bubble with
    /// our own name on top.
    private func groupSenderFor(_ msg: ChatMessage) -> GroupBubbleSender? {
        guard conversation.conversation_type == "group" else { return nil }
        let me = AccountStore.shared.current?.id
        if msg.isMine(currentUserId: me) { return nil }
        let key: String
        switch msg.sender_type {
        case "bot":  key = "bot:\(msg.sender_id)"
        case "user", "human": key = "user:\(msg.sender_id)"
        default: return nil
        }
        return groupSenders[key]
    }

    /// Group conv only — pull the most recent pending continue-request
    /// row, if any. Realtime subscription would be nicer but lookback
    /// notes also poll-on-open today, so we follow the same pattern;
    /// continue prompts are infrequent enough that a refresh on open +
    /// after-send is sufficient.
    private func loadPendingContinueIfNeeded() async {
        guard conversation.conversation_type == "group" else { return }
        guard !conversation.id.isEmpty else { return }
        do {
            struct Row: Decodable {
                let id: String
                let pending_bot_ids: [String]
            }
            let rows: [Row] = try await SupabaseStack.shared
                .from("group_continue_requests")
                .select("id, pending_bot_ids")
                .eq("conversation_id", value: conversation.id)
                .eq("status", value: "pending")
                .order("requested_at", ascending: false)
                .limit(1)
                .execute()
                .value
            self.pendingContinue = rows.first.map {
                PendingContinue(id: $0.id, pendingBotIds: $0.pending_bot_ids)
            }
        } catch {
            log.warning("pending continue load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Detects an in-progress @-mention at the end of `input`. Returns
    /// the substring AFTER the `@` (possibly empty when the user just
    /// typed `@`). nil when there's no @-trigger active. We trigger on
    /// "@" preceded by whitespace or start-of-string so emails / inline
    /// at-signs don't accidentally open the picker.
    private var mentionPrefix: String? {
        guard let atRange = input.range(of: "@", options: .backwards) else { return nil }
        // Must be followed only by chars that look like a name token (no
        // whitespace, no newlines) — anything else means the user moved on.
        let after = input[atRange.upperBound...]
        if after.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return nil
        }
        // The `@` must be at the start of input or immediately after a
        // whitespace; reject things like "alice@host" inside an email.
        if atRange.lowerBound > input.startIndex {
            let prev = input[input.index(before: atRange.lowerBound)]
            if !prev.isWhitespace { return nil }
        }
        return String(after)
    }

    /// Filter groupSenders by the in-progress prefix (case-insensitive),
    /// drop "myself" so I don't mention me. Cap at a few rows so the
    /// picker doesn't push the message list off-screen.
    private func mentionCandidates(prefix: String) -> [GroupBubbleSender] {
        let me = AccountStore.shared.current?.id ?? ""
        let needle = prefix.lowercased()
        return groupSenders.values
            .filter { sender in
                if sender.kind == .user && sender.id == me { return false }
                if needle.isEmpty { return true }
                return sender.displayName.lowercased().contains(needle)
            }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
            .prefix(6)
            .map { $0 }
    }

    @ViewBuilder
    private func mentionPickerOverlay(prefix: String) -> some View {
        let candidates = mentionCandidates(prefix: prefix)
        if candidates.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(candidates, id: \.id) { sender in
                    Button {
                        insertMention(sender, prefix: prefix)
                    } label: {
                        HStack(spacing: 10) {
                            switch sender.kind {
                            case .bot:
                                BotAvatar(emojiSeed: sender.id, colorSeed: sender.id, size: 24)
                            case .user:
                                UserAvatar(seed: sender.id, attachmentId: sender.avatarPath, size: 24)
                            }
                            Text(sender.displayName)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.Palette.ink)
                            Spacer()
                            if sender.kind == .bot {
                                Text("机器人")
                                    .font(Theme.Fonts.rounded(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                        }
                        .padding(.horizontal, Theme.Metrics.gutter)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
            .background(Theme.Palette.surface)
            .overlay(
                Rectangle().frame(height: 0.5).foregroundStyle(Theme.Palette.hairline),
                alignment: .top,
            )
        }
    }

    private func insertMention(_ sender: GroupBubbleSender, prefix: String) {
        // Drop the trailing "@<prefix>" and re-insert "@<displayName> ".
        // Spaces inside nicknames stay because we replace by length, not
        // by whitespace boundary — DB enforces no-whitespace inside a
        // single nickname so this is unambiguous in practice.
        let dropCount = prefix.count + 1   // include the "@"
        let head = String(input.dropLast(dropCount))
        input = head + "@" + sender.displayName + " "
        Haptics.tap()
    }

    @ViewBuilder
    private func continueRequestBanner(_ pc: PendingContinue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("机器人还有话想说,让它继续吗?")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if continueDeciding {
                ProgressView()
            } else {
                Button {
                    Task { await decideContinue(pc, allow: false) }
                } label: {
                    Text("✕ 闭嘴")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await decideContinue(pc, allow: true) }
                } label: {
                    Text("✓ 继续")
                        .font(Theme.Fonts.body)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 10)
        .background(Theme.Palette.surface)
    }

    private func decideContinue(_ pc: PendingContinue, allow: Bool) async {
        continueDeciding = true
        defer { continueDeciding = false }
        struct Body: Encodable {
            let requestId: String
            let decision: String
        }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/\(conversation.id)/continue-decision")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(
                requestId: pc.id,
                decision: allow ? "allowed" : "denied",
            ))
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "ContinueVote",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            // The decision message is inserted by the worker (Realtime
            // delivers it); just clear the local banner.
            self.pendingContinue = nil
            Haptics.tap()
        } catch {
            self.error = "投票失败: \(error.localizedDescription)"
            Haptics.error()
        }
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
            // (review step entries) which are rendered separately.
            struct Row: Decodable {
                let id: String
                let client_message_id: String?
                let conversation_id: String
                let user_id: String?
                let sender_bot_id: String?
                let role: String
                let log_kind: String?
                let content: String?
                let status: String?
                let created_at: String
                let citations: [MessageCitation]?
            }
            // role='log' rows (review step entries) are server-only and
            // filtered out client-side — they don't render here.
            let rows: [Row] = try await SupabaseStack.shared
                .from("messages")
                .select("id, client_message_id, conversation_id, user_id, sender_bot_id, role, log_kind, content, status, created_at, citations")
                .eq("conversation_id", value: conversation.id)
                .order("created_at", ascending: true)
                .limit(200)
                .execute()
                .value
            var viewMessages: [ChatMessage] = []
            var cacheRows: [LocalDatabase.MessageRow] = []
            viewMessages.reserveCapacity(rows.count)
            cacheRows.reserveCapacity(rows.count)
            var citationsLoaded: [String: [MessageCitation]] = [:]
            for r in rows {
                if r.role == "log" { continue }
                let senderType: String = r.role == "bot" ? "bot" : "user"
                let senderId = r.role == "bot" ? (r.sender_bot_id ?? "") : (r.user_id ?? "")
                let secs = ServerTimestamp.epochSeconds(r.created_at, default: 0)
                viewMessages.append(ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: senderType,
                    sender_id: senderId,
                    content: r.content ?? "",
                    created_at: secs,
                    attachments: nil
                ))
                if let cites = r.citations, !cites.isEmpty {
                    citationsLoaded[r.id] = cites
                }
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
            // Merge — keep any in-flight live snapshots that the SSE turn
            // already populated; history's persisted values win on key collision.
            self.citationsByMsgId.merge(citationsLoaded) { _, new in new }
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
        // Per-conv model override endpoint not yet on the new Worker; the
        // conversation_settings sheet still calls this. UI affordance is
        // present but the change doesn't persist until the route lands.
        _ = slug
        Haptics.tap()
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

