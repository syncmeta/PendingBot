import SwiftUI
import PhotosUI
import UIKit
import OSLog
import Supabase
import UniformTypeIdentifiers

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
    /// Peer avatar carried over from whatever list the tap came from
    /// (message list / friends list), so the chat header + incoming
    /// bubbles render the correct face on the very first frame instead
    /// of flashing a generic glyph until `loadPeerProfileIfNeeded()`'s
    /// round-trip lands. nil when the tap origin had no avatar (e.g. the
    /// group-member-tap path); `peerProfileForBubble` falls back to the
    /// peer id as the emoji seed in that case.
    var avatarPath: String? = nil
    var avatarSeed: String? = nil
    /// Pre-resolved conv id, populated by the friends-tab tap path when
    /// we already looked up the singleton user_user conv before navigating.
    /// When set, `pendingConversation(for:)` builds a fully-keyed Conversation
    /// instead of one with `id: ""`, so ConversationView jumps straight to
    /// loading existing history instead of waiting for a first message to
    /// materialize the row.
    var existingConvId: String? = nil
}

/// Reports the bottom marker's Y offset within the scroll viewport so
/// ConversationView can tell whether the user is parked at the latest
/// message. A value larger than the viewport height means they've
/// scrolled up into history.
private struct ScrollBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ConversationView: View {
    @State var conversation: Conversation
    let bot: Bot?
    /// Mutable so the "+ new conv" header button can flip a materialized
    /// chat back to pending without reconstructing the view.
    @State var pendingPeer: PendingPeer?
    var onChange: () -> Void = {}

    // Note: these are intentionally module-internal (not `private`) so
    // that cross-file `extension ConversationView { … }` blocks (Recall,
    // Loading, ToolTrace, Attachments) can read them. Within the module,
    // only ConversationView instances expose them — same effective scope.
    @Environment(\.api) var api
    @Environment(\.account) var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @EnvironmentObject private var modelCatalog: ModelCatalog
    @State var messages: [ChatMessage] = []
    // Composer text — needs to be accessible from ConversationView+Group
    // (mention picker / insertMention rewrites the trailing "@<prefix>"),
    // so it can't be file-private.
    @State var input = ""
    @State var pendingAttachments: [PendingAttachment] = []
    /// In-flight attachment uploads. `send()` awaits these so an upload
    /// that lags the send tap still lands on the outgoing message.
    @State var uploadTasks: [Task<Void, Never>] = []
    @State var photoPickerItems: [PhotosPickerItem] = []
    @State var cameraImage: UIImage?
    /// Set true to present the system document picker (any file type).
    @State var showFileImporter = false
    /// Per-id attachment metadata (mime/filename) used to hydrate
    /// AttachmentGrid for loaded/realtime messages. Populated on upload
    /// and on history load — see bubbleMessage.
    @State var attachmentMetaById: [String: Attachment] = [:]
    @State var modelOverride: String = ""    // "" = use bot default
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
    @State var error: String?
    @State private var pending = false              // server is generating (bot_typing active)
    /// Outstanding tool calls this turn. Incremented on each `tool_call`,
    /// decremented on its `tool_result`. When > 0 we suppress the typing
    /// dots — the model isn't producing user-visible output during tool
    /// execution, the tool-trace row covers that phase instead.
    @State private var activeToolCount = 0
    /// Active SSE turn task; canceling it closes the stream which Worker
    /// reads as request.signal.aborted (= interrupt). Set by sendViaSSE,
    /// cleared on completion. Non-nil while a turn is in flight.
    // chatTurnTask gates the auto-lookback fire timer in
    // ConversationView+Realtime, so it needs to be cross-extension visible.
    @State var chatTurnTask: Task<Void, Never>?
    /// Realtime subscription token for this conv's `messages` channel —
    /// dropped when the view disappears. Picks up cross-device messages
    /// and bot rows that land via background paths (cron, review).
    @State var realtimeToken: ConvSubscriptionToken?
    /// Lookback notes the bot wrote about prior turns (Realtime push from
    /// pendingbot.bot_lookbacks). Invisible to the user; passed in
    /// `activeLookbacks` on the next POST so the bot sees them as context.
    @State var activeLookbacks: [LookbackNote] = []
    /// 30s grace timer started when a new lookback arrives. If user hasn't
    /// sent anything before it fires, we auto-trigger a continuation turn
    /// so the bot's fact-check actually surfaces.
    @State var lookbackAutoFireTask: Task<Void, Never>?
    /// Tool-call trace per user message. Rendered inline (non-bubble, auto-
    /// collapsed) right after the user message that triggered it. Worker emits
    /// `tool_call` / `tool_result` SSE events during a turn — we accumulate
    /// them into the bucket for the in-flight `liveTraceUserMsgId`.
    @State var tracesByUserMsgId: [String: [ToolTraceEvent]] = [:]
    /// Local id of the user message currently driving an SSE turn — set in
    /// sendViaSSE before the stream starts, cleared when the turn ends.
    /// Multiple traces can land for the same user msg if the agent loops.
    @State var liveTraceUserMsgId: String?
    /// Web-search citations attached to a bot bubble, keyed by message id.
    /// Sources: history `select citations`, Realtime UPDATE on the row, and
    /// the per-turn `citations` SSE event copied to each in-flight bubble.
    /// `MarkdownText` reads the entry to resolve inline `[N]` markers.
    @State var citationsByMsgId: [String: [MessageCitation]] = [:]
    /// Cumulative citations for the in-flight turn — last value pushed by the
    /// `citations` SSE event. Snapshotted onto each bubble created during
    /// the turn so the live preview can resolve `[N]` taps before the
    /// canonical row arrives via Realtime.
    @State var liveCitations: [MessageCitation] = []
    /// Per-trace citations bucket so the inline `搜索` trace can list the
    /// hits it surfaced even after the turn ends + `liveCitations` resets.
    /// Keyed by user-message id like `tracesByUserMsgId`; rekeyed on the
    /// optimistic-id → canonical-id swap so re-expanding an old trace still
    /// shows its results.
    @State var traceCitationsByUserMsgId: [String: [MessageCitation]] = [:]
    /// Attachment ids per message id. Populated from `messages.attachments`
    /// jsonb on load + Realtime, and from the local pending attachment set
    /// when the user sends. Used on recall (own + peer's, via the
    /// status='deleted' Realtime UPDATE) to scrub the matching responses
    /// from URLCache.shared so cached image bytes for a recalled message
    /// don't linger on disk after the server-side R2 object is purged.
    @State var attachmentIdsByMsgId: [String: [String]] = [:]
    // Skill summaries — counted in the settings sheet so the user sees
    // how many are active without leaving the conversation.
    @State var skills: [SkillSummary] = []
    @State private var showingSettings = false
    /// Drives the push into BotConfigView from the pre-chat 设置 button.
    @State private var showingBotConfig = false
    /// In-flight / done state for the pre-chat 请它写信 action.
    @State private var triggeringLetter = false
    @State private var letterTriggered = false
    @State private var saveAsSkillBody: String?
    /// Body of a message the user wants to partial-copy. The bubble's
    /// own `.textSelection(.enabled)` is shadowed by SwiftUI's
    /// `.contextMenu`, so long-press only offers a whole-message copy.
    /// Presenting the body in a sheet gives us a surface with no
    /// competing long-press gesture, where the system's selection
    /// handles work normally.
    @State private var selectableTextBody: String?
    /// Active voice call session, present while CallView is on screen.
    /// Created on phone-button tap and torn down when CallView dismisses.
    @State var callSession: CallSession?
    /// Active group voice call session, present while GroupCallView is on
    /// screen. Created on the group-call header button; group convs only.
    @State var groupCallSession: GroupCallSession?

    // Jump-to-latest pill state. `isAtBottom` is recomputed from a
    // geometry preference on the bottom marker; while it's false, new
    // messages don't auto-scroll — they bump `unreadCount` and surface
    // the bottom-right pill instead. The user's own sends always scroll
    // regardless (see the messages.count onChange).
    @State private var isAtBottom = true
    @State private var unreadCount = 0
    @State private var scrollViewportHeight: CGFloat = 0

    // Streaming bubble state — see applyBubbleEmissions. The splitter
    // (BubbleSplitter.swift) decides whether a bubble pops in whole or
    // streams; for the streaming case `revealTargetId` is the local key
    // of the live bubble (tokens append to its tail as they arrive),
    // and `streamPaused` drives the cursor's blink mode (solid while
    // tokens flow, blink after a short idle). `revealTask` holds the
    // idle debounce that flips streamPaused.
    @State var revealTargetId: String?
    @State var revealTask: Task<Void, Never>?
    @State var streamPaused: Bool = false

    /// This turn's bot-bubble message ids, in creation order. A bubble is
    /// born under a `live-<uuid>` id (the client splitter has no canonical
    /// id yet); when the SSE `bubble` event announces the server's
    /// canonical id for bubble N, entry N-1 is rekeyed to it (see
    /// `case .bubble` → `rekeyBotBubble`). Reset at the start of each turn.
    ///
    /// This is what makes SSE/realtime dedup order-independent: by the time
    /// the realtime INSERT for a bubble arrives, the live-* bubble already
    /// carries its canonical id, so the INSERT is a plain id-keyed in-place
    /// upsert in `applyRealtimeEvent` — never a duplicate.
    @State var turnBubbleIds: [String] = []

    /// Maps `local-<uuid>` → `client_message_id` so a Realtime INSERT echo
    /// can dedupe against our optimistic row by matching the server's
    /// `client_message_id` field exactly, instead of guessing via a 5s
    /// recency window that fails on slow networks. Cleared once the
    /// canonical row has replaced the optimistic one.
    @State var localMsgClientIds: [String: String] = [:]

    /// Other-side profile for a user_user conv, fetched once on appear
    /// when we don't already have a `pendingPeer`. Drives the chat
    /// header (title + avatar) and the left-side avatar on incoming
    /// bubbles.
    struct ResolvedPeer {
        let userId: String
        let displayName: String
        let avatarPath: String?
        /// Server-supplied placeholder-emoji seed (users.custom_fields
        /// .avatar_seed). Falls back to userId when the peer is a legacy
        /// account that never bootstrapped.
        let avatarSeed: String
    }
    @State var resolvedPeer: ResolvedPeer?

    /// Group conv only — sender lookup keyed by "user:<id>" / "bot:<id>"
    /// so each bubble can render its own avatar + nickname above the
    /// content. Loaded on appear via loadGroupSenders(); 1v1 stays nil
    /// and the existing peerProfile path serves it.
    @State var groupSenders: [String: GroupBubbleSender] = [:]

    /// Group conv only — when the GroupRouterDO held back a bot turn
    /// because the last 30s of messages was bot-only, it filed a
    /// pending continue request. The banner above the composer renders
    /// allow / deny buttons; either decision posts a normal user
    /// message *and* unblocks (or kills) the held bots.
    struct PendingContinue: Equatable {
        let id: String
        let pendingBotIds: [String]
    }
    @State var pendingContinue: PendingContinue?
    // Decision-in-flight for the continue-request banner — accessed by
    // both the banner view (in ConversationView+Group) and the worker
    // POST handler in the same extension.
    @State var continueDeciding: Bool = false

    /// Group conv only — set when the caller's group_member_billing.
    /// overdrawn = true (per-group cap exhausted OR wallet balance can't
    /// cover the next allocation; migration 0066 unifies both into the
    /// same flag). The timestamp is the moment of the flip — messages
    /// from this point forward are hidden and the composer locks. Older
    /// messages stay visible so the user can still scroll their history.
    @State var groupFreezeAt: Date?

    /// "<bot_name> · <effective-model-tag>". Effective model = the per-conv
    /// override if set, otherwise the bot's resolved model (which itself
    /// already accounts for the user's per-bot pin from 我 → 机器人管理).
    private var botName: String {
        let base = bot?.display_name ?? conversation.bot_name ?? conversation.bot_id
        let tag: String? = {
            let trimmed = modelOverride.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return modelCatalog.displayName(for: trimmed) }
            guard let slug = bot?.model, !slug.isEmpty else { return nil }
            return modelCatalog.displayName(for: slug)
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
            UserAvatar(seed: peer.avatarSeed, attachmentId: peer.avatarPath, size: size)
        } else if conversation.conversation_type == "group" {
            GroupAvatar(seed: conversation.id, size: size)
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
    private var peerProfileForBubble: (userId: String, displayName: String, avatarPath: String?, avatarSeed: String)? {
        guard conversation.conversation_type == "user_user" else { return nil }
        if let p = resolvedPeer {
            return (userId: p.userId, displayName: p.displayName, avatarPath: p.avatarPath, avatarSeed: p.avatarSeed)
        }
        if let p = pendingPeer, p.kind == "user" {
            // Avatar carried over from the originating list — correct on
            // the first frame, no flash. Seed falls back to peerId when
            // the tap origin had none (matches the legacy-account glyph).
            return (userId: p.peerId, displayName: p.displayName,
                    avatarPath: p.avatarPath, avatarSeed: p.avatarSeed ?? p.peerId)
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

    /// Hydrate a message's `attachments` from the `attachmentIdsByMsgId`
    /// sidecar so BubbleView's AttachmentGrid renders them. Loaded /
    /// realtime rows arrive with `attachments == nil` and their ids
    /// tracked separately; this fills them in at render time. Per-id
    /// mime/filename come from `attachmentMetaById` (populated on upload
    /// and on history load); an id with no metadata falls back to an
    /// image, which is the pre-arbitrary-file invariant.
    private func bubbleMessage(_ msg: ChatMessage) -> ChatMessage {
        guard msg.attachments == nil,
              let ids = attachmentIdsByMsgId[msg.id], !ids.isEmpty else { return msg }
        let atts = ids.map { id -> Attachment in
            if let meta = attachmentMetaById[id] { return meta }
            return Attachment(id: id, kind: "image", mime: "image/png",
                              size: nil, width: nil, height: nil,
                              url: "/v1/uploads/\(id)")
        }
        return ChatMessage(
            id: msg.id, conversation_id: msg.conversation_id,
            sender_type: msg.sender_type, sender_id: msg.sender_id,
            content: msg.content, created_at: msg.created_at,
            attachments: atts, status: msg.status
        )
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
            activeCallBanner

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: 8)

                        if displayedMessages.isEmpty && !pending {
                            emptyConversation
                        }

                        ForEach(displayedMessages) { msg in
                            if idsWithLeadingTimeSeparator.contains(msg.id) {
                                TimeSeparatorPill(
                                    date: Date(timeIntervalSince1970: TimeInterval(msg.created_at))
                                )
                                .id("time-sep:\(msg.id)")
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                            }
                            if msg.sender_type == "recall_log" {
                                // Tombstone for a recall. `content`
                                // carries the original message's epoch
                                // seconds (see loadHistory mapping);
                                // `sender_id` is the recaller's user
                                // id, used to pick the 1st-person vs
                                // 3rd-person wording.
                                let originalSecs = Int(msg.content) ?? msg.created_at
                                RecallTombstoneView(
                                    wasMine: msg.sender_id == AccountStore.shared.current?.id,
                                    originalAt: Date(timeIntervalSince1970: TimeInterval(originalSecs))
                                )
                                .id(msg.id)
                            } else {
                            BubbleView(message: bubbleMessage(msg),
                                       botName: botName,
                                       conversationID: conversation.id,
                                       botID: avatarEmojiSeed,
                                       selfAvatar: bubbleSelfAvatar,
                                       currentUserId: AccountStore.shared.current?.id,
                                       peerProfile: peerProfileForBubble,
                                       groupSender: groupSenderFor(msg),
                                       serverURL: account?.workerURL,
                                       citations: citationsByMsgId[msg.id] ?? [],
                                       isStreaming: revealTargetId == msg.id,
                                       streamPaused: revealTargetId == msg.id && streamPaused,
                                       onRetry: { retryFailedMessage(msg) }) {
                                    Button {
                                        UIPasteboard.general.string = msg.content
                                        Haptics.tap()
                                    } label: { Label("复制", systemImage: "doc.on.doc") }
                                    Button {
                                        selectableTextBody = msg.content
                                        Haptics.tap()
                                    } label: { Label("复制部分文字", systemImage: "selection.pin.in.out") }
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
                                    if msg.isMine(currentUserId: AccountStore.shared.current?.id) {
                                        if msg.isFailed {
                                            // Failed sends never reached the
                                            // server — offer a re-send instead
                                            // of 撤回 (which would 404 on the
                                            // local-only id).
                                            Button {
                                                retryFailedMessage(msg)
                                            } label: { Label("重新发送", systemImage: "arrow.clockwise") }
                                        } else {
                                            // 撤回: WeChat-style sender-only retract.
                                            // In user_user convs this leaves a
                                            // tombstone log row visible to both
                                            // parties; in user_bot / group convs
                                            // it's a hard purge (bot's future
                                            // context won't see it either).
                                            // Server side: POST /v1/messages/:id/recall.
                                            Button {
                                                Task { await recallMessage(msg) }
                                            } label: { Label("撤回", systemImage: "arrow.uturn.backward") }
                                        }
                                    }
                                    Button(role: .destructive) {
                                        Task { await deleteMessage(msg) }
                                    } label: { Label("删除", systemImage: "trash") }
                                }
                                .id(msg.id)
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
                            }  // end else (non-recall_log branch)
                        }

                        Color.clear.frame(height: 8).id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ScrollBottomOffsetKey.self,
                                        value: geo.frame(in: .named("convScroll")).minY
                                    )
                                }
                            )
                    }
                    .padding(.top, 4)
                    .readableColumnWidth()
                }
                .coordinateSpace(.named("convScroll"))
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { scrollViewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in
                                scrollViewportHeight = h
                            }
                    }
                )
                .onPreferenceChange(ScrollBottomOffsetKey.self) { offset in
                    // The bottom marker sits at the viewport's bottom edge
                    // when the user is parked at the latest message; a
                    // larger offset means they've scrolled up. The 80pt
                    // slack keeps "almost at the bottom" counting as at-bottom.
                    guard scrollViewportHeight > 0 else { return }
                    let atBottom = offset - scrollViewportHeight <= 80
                    if atBottom != isAtBottom {
                        withAnimation(.easeOut(duration: 0.2)) { isAtBottom = atBottom }
                    }
                    if atBottom && unreadCount != 0 { unreadCount = 0 }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { oldCount, newCount in
                    // The user's own send always scrolls into view; incoming
                    // messages only auto-scroll when already at the bottom.
                    // Otherwise they bump the unread pill instead of yanking
                    // the user away from the history they're reading.
                    let mine = messages.last?
                        .isMine(currentUserId: AccountStore.shared.current?.id) ?? false
                    if isAtBottom || mine {
                        unreadCount = 0
                        scrollToBottom(proxy: proxy)
                    } else if newCount > oldCount {
                        withAnimation(.easeOut(duration: 0.2)) {
                            unreadCount += newCount - oldCount
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if unreadCount > 0 && !isAtBottom {
                        unreadJumpButton(proxy: proxy)
                    }
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
                if iAmFrozen {
                    frozenComposerBanner
                        .readableColumnWidth()
                }
                if let pc = pendingContinue {
                    continueRequestBanner(pc)
                        .readableColumnWidth()
                }
                if conversation.conversation_type == "group",
                   let prefix = mentionPrefix {
                    mentionPickerOverlay(prefix: prefix)
                        .readableColumnWidth()
                }
                ComposerView(
                    input: $input,
                    pending: $pendingAttachments,
                    photoItems: $photoPickerItems,
                    cameraImage: $cameraImage,
                    showFileImporter: $showFileImporter,
                    canSend: canSend,
                    onSend: { Task { await send() } },
                    isStreaming: chatTurnTask != nil,
                    onStop: {
                        chatTurnTask?.cancel()
                        flushRevealImmediately()
                    },
                    // Show 检查 only when the conv has a single bot — group
                    // dispatches across multiple bots and user_user has none.
                    onLookback: (conversation.conversation_type == "user_bot"
                                 || conversation.conversation_type == "self")
                        ? { Task { await triggerManualLookback() } }
                        : nil
                )
                .readableColumnWidth()
            }
        }
        .onAppear {
            // Set synchronously so a push arriving in the first few ms
            // after view-appear sees the right id. .task below is async-
            // scheduled and leaves a tiny race window in which willPresent
            // reads nil and pops a foreground banner.
            if !conversation.id.isEmpty {
                PushService.shared.activeConversationId = conversation.id
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
            await loadGroupFreezeIfNeeded()
        }
        .onDisappear {
            if PushService.shared.activeConversationId == conversation.id {
                PushService.shared.activeConversationId = nil
            }
            if let token = realtimeToken {
                Task { await RealtimeManager.shared.stopConvChannel(token) }
                realtimeToken = nil
            }
            lookbackAutoFireTask?.cancel()
            lookbackAutoFireTask = nil
            revealTask?.cancel()
            revealTask = nil
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { callSession != nil },
                set: { if !$0 { callSession = nil } },
            ),
        ) {
            if let session = callSession {
                CallView(session: session)
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { groupCallSession != nil },
                set: { if !$0 { groupCallSession = nil } },
            ),
        ) {
            if let session = groupCallSession {
                GroupCallView(session: session)
            }
        }
        .navigationDestination(isPresented: $showingSettings) {
            // 设置入口扁平化:不再有"会话设置"这一层 — gear 按钮直接落到对应
            // 实体的设置页 (人 / 机器人 / 群)。
            //   • group  → GroupSettingsView (成员 / 昵称 / 免打扰 / 退出)
            //   • user_user → ContactSettingsView (备注 / 免打扰 / 删除好友)
            //   • user_bot / self → BotConfigView (机器人本身的默认配置)
            if conversation.conversation_type == "group" {
                GroupSettingsView(conversationId: conversation.id)
            } else if conversation.conversation_type == "user_user",
                      let peer = peerProfileForBubble {
                ContactSettingsView(
                    contactUserId: peer.userId,
                    conversationId: conversation.id,
                    initialDisplayName: peer.displayName,
                    initialAvatarPath: peer.avatarPath,
                    initialAvatarSeed: peer.avatarSeed
                )
            } else if let bot {
                BotConfigView(bot: bot, currentUserId: AccountStore.shared.current?.id)
            }
        }
        .navigationDestination(isPresented: $showingBotConfig) {
            // Bot-level config (model / voice / vision / envelope /
            // lookback / skills). Reached from the pre-chat action bar.
            if let bot {
                BotConfigView(bot: bot, currentUserId: AccountStore.shared.current?.id)
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
        .sheet(item: Binding(
            get: { selectableTextBody.map { SelectableTextBody(body: $0) } },
            set: { selectableTextBody = $0?.body }
        )) { body in
            SelectableTextSheet(text: body.body)
                .tint(Theme.Palette.accent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            uploadTasks.append(Task { await ingestPhotos(items) })
        }
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            uploadTasks.append(Task { await ingestCameraImage(image) })
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                uploadTasks.append(Task { await ingestFiles(urls) })
            case .failure(let err):
                self.error = "选择文件失败: \(err.localizedDescription)"
            }
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var canSend: Bool {
        guard !iAmFrozen else { return false }
        return !input.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty
    }

    /// True iff this is a group conv and the caller has been frozen out
    /// by group_member_billing.overdrawn. Drives the banner above the
    /// composer and the displayed-message filter below.
    private var iAmFrozen: Bool {
        groupFreezeAt != nil
    }

    /// Messages the freeze gate allows the caller to see. Pre-freeze
    /// rows stay visible (they were already in this user's allowance
    /// when posted); rows whose `created_at` is at-or-after the freeze
    /// timestamp are hidden — that's the user-facing rule "你看不到
    /// 自从达到上限之后的新消息".
    private var displayedMessages: [ChatMessage] {
        guard let freezeAt = groupFreezeAt else { return messages }
        let cutoff = Int(freezeAt.timeIntervalSince1970)
        return messages.filter { $0.created_at < cutoff }
    }

    /// Set of message ids that should have a centered time-separator
    /// pill rendered immediately BEFORE them. WeChat-style cadence:
    /// always before the very first message in the visible window,
    /// then again whenever the gap to the previous message exceeds
    /// RelativeMessageTime.separatorGapSeconds (5 min). Kept as a
    /// derived Set so the ForEach body's lookup is O(1).
    private var idsWithLeadingTimeSeparator: Set<String> {
        var ids: Set<String> = []
        let shown = displayedMessages
        guard let first = shown.first else { return ids }
        ids.insert(first.id)
        for i in 1..<shown.count {
            let prev = shown[i - 1].created_at
            let cur = shown[i].created_at
            if Double(cur - prev) >= RelativeMessageTime.separatorGapSeconds {
                ids.insert(shown[i].id)
            }
        }
        return ids
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

    /// Bottom-right pill shown when new messages land while the user is
    /// scrolled up. Tapping it clears the count and jumps to the latest.
    private func unreadJumpButton(proxy: ScrollViewProxy) -> some View {
        Button {
            Haptics.tap()
            unreadCount = 0
            scrollToBottom(proxy: proxy)
        } label: {
            HStack(spacing: 5) {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Theme.Palette.surface)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.Palette.accent))
            .overlay(Capsule().stroke(Theme.Palette.surface.opacity(0.5), lineWidth: 0.5))
            .shadow(color: Theme.Palette.ink.opacity(0.18), radius: 6, y: 2)
        }
        .padding(.trailing, 14)
        .padding(.bottom, 14)
        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
    }

    private var emptyConversation: some View {
        VStack(spacing: 14) {
            headerAvatar(size: 64)
            Text(conversation.conversation_type == "user_user" ? headerTitle : botName)
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            if showsBotPreChatActions {
                botPreChatActions
                    .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.bottom, 24)
    }

    /// The pre-chat action bar (请它写信 / 致电 / 设置) sits under the
    /// empty-state avatar for a fresh bot chat. Once a message is sent
    /// the conversation is no longer empty, so the bar disappears on its
    /// own — no extra dismissal logic needed.
    private var showsBotPreChatActions: Bool {
        conversation.conversation_type == "user_bot" && bot != nil
    }

    @ViewBuilder
    private var botPreChatActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                PreChatActionButton(
                    title: triggeringLetter ? "派出中…" : "请它写信",
                    systemImage: "envelope.open",
                    busy: triggeringLetter
                ) { Task { await requestBotLetter() } }
                .disabled(triggeringLetter)

                PreChatActionButton(title: "致电", systemImage: "phone.fill") {
                    Task { await startPreChatCall() }
                }

                PreChatActionButton(title: "设置", systemImage: "gearshape") {
                    Haptics.tap()
                    showingBotConfig = true
                }
            }
            if letterTriggered {
                Text("已请它写信 — 去「来信」看进度")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .transition(.opacity)
            }
        }
    }

    /// Materialize the pending conv (if needed), then kick off an
    /// envelope with the bot's saved defaults. The letter surfaces on
    /// the 来信 tab; the chat itself stays empty so the action bar
    /// remains for the user to keep going.
    private func requestBotLetter() async {
        guard !triggeringLetter, let api else { return }
        guard await materializeIfPending() else { return }
        triggeringLetter = true
        defer { triggeringLetter = false }
        do {
            _ = try await api.envelopeTrigger(conversationId: conversation.id, settings: nil)
            withAnimation { letterTriggered = true }
            Haptics.success()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    /// Voice-call entry from the pre-chat bar. Voice is an opt-in per-bot
    /// gate, so a bot that hasn't enabled it sends the user to 设置
    /// instead of failing silently.
    private func startPreChatCall() async {
        guard bot?.voice_call_enabled == true else {
            self.error = "这个机器人还没开启语音通话,可以在「设置」里打开。"
            return
        }
        guard await materializeIfPending() else { return }
        Haptics.tap()
        startVoiceCall()
    }

    /// Slim in-conv banner shown when a group voice call is live in this
    /// conversation. Tapping it rejoins the call. From left to right:
    ///   phone-icon · MM:SS elapsed · "N 人"
    /// Driven by ActiveVoiceCallStore which mirrors the conv-channel's
    /// voice_call frames.
    @ViewBuilder
    private var activeCallBanner: some View {
        if let snap = ActiveVoiceCallStore.shared.calls[conversation.id] {
            ActiveCallBanner(snapshot: snap) {
                Haptics.tap()
                if canStartGroupCall {
                    startGroupCall()
                }
            }
        }
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
                // user_user 单聊没有 bot · model 这一行可显示;隐掉副标题
                // 让头像 + 备注/昵称就是全部识别信息,贴近普通 IM 的呈现。
                if conversation.conversation_type != "user_user" {
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
            }
            Spacer(minLength: 0)
            if canStartVoiceCall {
                Button {
                    Haptics.tap()
                    startVoiceCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("语音通话")
            }
            if canStartGroupCall {
                Button {
                    Haptics.tap()
                    startGroupCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("群语音")
            }
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

    // subscribeRealtime + applyContinueEvent + applyRealtimeEvent +
    // applyLookbackEvent + scheduleLookbackAutoFire + canStartVoiceCall
    // + startVoiceCall live in ConversationView+Realtime.swift.

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
        input = ""
        // Drain in-flight uploads first — an upload can lag the send tap
        // by seconds, and capturing pendingAttachments before it lands
        // would silently drop the attachment from this message.
        if !uploadTasks.isEmpty {
            let inflight = uploadTasks
            uploadTasks = []
            for t in inflight { await t.value }
        }
        let attachIds = pendingAttachments.map(\.id)
        let attachmentSnapshot = pendingAttachments
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
            // Bind a stable client_message_id to the optimistic row up
            // front so the Realtime INSERT echo can dedupe via exact-match
            // (see localMsgClientIds), not a recency window.
            let cmid = UUID().uuidString.lowercased()
            localMsgClientIds[localId] = cmid
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
                attachments: attachmentSnapshot.map { $0.asAttachment() },
                status: "sending"
            ))
            // Mirror the attachment ids into the sidecar dict the
            // recall path scrubs from URLCache — keyed by localId
            // here; rekeyed to the canonical id when Realtime resolves
            // (see the live-* → canonical swap below).
            if !attachmentSnapshot.isEmpty {
                attachmentIdsByMsgId[localId] = attachmentSnapshot.map { $0.id }
            }
            // Don't light the typing indicator here — TypingDots is gated
            // on the first bot token now, and the "sending" (light green)
            // bubble already signals that the request is in flight.

            // Lazy-cloud-conv: a fresh user_bot conv with no cloud row yet
            // skips the materialise round-trip entirely. /v1/messages/start
            // creates the conv inside the worker and surfaces the canonical
            // ids back via the first SSE `meta` frame, which sendViaSSE
            // wires into `conversation` + the optimistic row in real time.
            if conversation.id.isEmpty
                && conversation.conversation_type == "user_bot" {
                let botId = pendingPeer?.peerId ?? conversation.bot_id
                if botId.isEmpty {
                    self.error = "未知机器人"
                    markUserMessageFailed(localId)
                    return
                }
                // Bubble stays as "sending" (light green) — sendViaSSE
                // flips it to "sent" (full green) on the .connected event.
                sendViaSSE(text: text, attachmentIds: attachIds,
                           userMsgId: localId, clientMessageId: cmid,
                           startBotId: botId)
                return
            }

            if conversation.id.isEmpty {
                let ok = await materializeIfPending()
                guard ok else {
                    markUserMessageFailed(localId)
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

            // Conv exists now — hand off to the SSE turn. The bubble
            // stays "sending" (light green) until the .connected event
            // flips it to "sent"; SSE failures repaint it red from
            // inside sendViaSSE's catch.
            sendViaSSE(text: text, attachmentIds: attachIds, userMsgId: localId, clientMessageId: cmid)
            return
        }

        // user_user: optimistic — drop the bubble in immediately so the
        // sender sees their own message without waiting on the Realtime
        // echo, then materialise (if pending) and INSERT. The realtime
        // dedup keyed on `local-` prefix + recency replaces the optimistic
        // row with the canonical one when it lands; if realtime is slow
        // or drops, the optimistic row stays in place and reads correctly.
        if conversation.conversation_type == "user_user" {
            let myId = AccountStore.shared.current?.id ?? ""
            let localId = "local-\(UUID().uuidString)"
            let cmid = UUID().uuidString.lowercased()
            localMsgClientIds[localId] = cmid
            messages.append(ChatMessage(
                id: localId,
                conversation_id: conversation.id,
                sender_type: "user", sender_id: myId,
                content: text,
                created_at: Int(Date().timeIntervalSince1970),
                attachments: attachmentSnapshot.map { $0.asAttachment() },
                status: "sending"
            ))
            if conversation.id.isEmpty {
                let ok = await materializeIfPending()
                guard ok else {
                    markUserMessageFailed(localId)
                    return
                }
                // Re-stamp conv id on the optimistic row so the realtime
                // dedup match keys on the right (conv, content, recency).
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
            // Bubble stays "sending" (light green) until the Supabase
            // insert returns; sendUserUserMessage flips it to "sent" on
            // success or "failed" on error. The canonical Realtime echo
            // replaces the row shortly after.
            await sendUserUserMessage(text, attachmentIds: attachIds,
                                      localId: localId, clientMessageId: cmid)
            return
        }

        // group: still need a real conv id before the worker call, since
        // it goes straight to Postgres without an SSE handshake. The
        // existing flow (await materialise, then post) is correct here —
        // the round-trip is cheap relative to bot turns and there's no
        // typing indicator to play hide-and-seek with.
        if conversation.id.isEmpty {
            let ok = await materializeIfPending()
            guard ok else {
                input = text
                return
            }
        }
        await sendGroupUserMessage(text)
    }

    /// Flip an in-flight optimistic user row to .failed (red bubble + alert).
    /// No-op if the row has already been replaced by its canonical Realtime
    /// version — that means the message did persist and we shouldn't pretend
    /// otherwise.
    func markUserMessageFailed(_ localId: String) {
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

    /// Flip the optimistic user row from "sending" (light green) to
    /// "sent" (full green) once the server has acknowledged the request
    /// — HTTP 200 on the SSE call, or a successful Supabase insert. The
    /// canonical row arriving via Realtime will subsequently replace
    /// this row outright (with status=nil), which renders the same
    /// shade so the transition is seamless.
    func markUserMessageSent(_ localId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == localId }),
              messages[idx].status == "sending" else { return }
        let prev = messages[idx]
        messages[idx] = ChatMessage(
            id: prev.id, conversation_id: prev.conversation_id,
            sender_type: prev.sender_type, sender_id: prev.sender_id,
            content: prev.content, created_at: prev.created_at,
            attachments: prev.attachments, status: "sent"
        )
    }

    /// Re-stamp the canonical conversation id onto an optimistic row
    /// after a late materialise, leaving its status untouched.
    private func restampConversationId(on localId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == localId }) else { return }
        let prev = messages[idx]
        messages[idx] = ChatMessage(
            id: prev.id, conversation_id: conversation.id,
            sender_type: prev.sender_type, sender_id: prev.sender_id,
            content: prev.content, created_at: prev.created_at,
            attachments: prev.attachments, status: prev.status
        )
    }

    /// Re-send a message that failed to deliver. Reuses the failed
    /// bubble's localId + client_message_id, so the worker / Postgres
    /// dedupe on client_message_id and a retry can't double-post even if
    /// the original request actually landed. The red bubble flips back
    /// to "sending" (light green) in place — no new row is inserted.
    func retryFailedMessage(_ msg: ChatMessage) {
        guard msg.isFailed,
              let idx = messages.firstIndex(where: { $0.id == msg.id })
        else { return }
        let localId = msg.id
        let cmid = localMsgClientIds[localId] ?? UUID().uuidString.lowercased()
        localMsgClientIds[localId] = cmid
        let text = msg.content
        let attachIds = attachmentIdsByMsgId[localId]
            ?? (msg.attachments?.map(\.id) ?? [])

        // Repaint the red bubble light-green ("sending") in place.
        let prev = messages[idx]
        messages[idx] = ChatMessage(
            id: prev.id, conversation_id: prev.conversation_id,
            sender_type: prev.sender_type, sender_id: prev.sender_id,
            content: prev.content, created_at: prev.created_at,
            attachments: prev.attachments, status: "sending"
        )
        error = nil
        Haptics.send()

        let isUserBot = conversation.conversation_type != "user_user"
                     && conversation.conversation_type != "group"
        if isUserBot {
            // Lazy-cloud-conv: still no cloud row → re-run the start flow.
            if conversation.id.isEmpty
                && conversation.conversation_type == "user_bot" {
                let botId = pendingPeer?.peerId ?? conversation.bot_id
                guard !botId.isEmpty else {
                    markUserMessageFailed(localId)
                    return
                }
                sendViaSSE(text: text, attachmentIds: attachIds,
                           userMsgId: localId, clientMessageId: cmid,
                           startBotId: botId)
                return
            }
            // Pending non-cloud conv whose materialise never landed.
            if conversation.id.isEmpty {
                Task {
                    guard await materializeIfPending() else {
                        markUserMessageFailed(localId)
                        return
                    }
                    restampConversationId(on: localId)
                    sendViaSSE(text: text, attachmentIds: attachIds,
                               userMsgId: localId, clientMessageId: cmid)
                }
                return
            }
            sendViaSSE(text: text, attachmentIds: attachIds,
                       userMsgId: localId, clientMessageId: cmid)
            return
        }

        // user_user — Supabase insert path.
        Task {
            if conversation.id.isEmpty {
                guard await materializeIfPending() else {
                    markUserMessageFailed(localId)
                    return
                }
                restampConversationId(on: localId)
            }
            await sendUserUserMessage(text, attachmentIds: attachIds,
                                      localId: localId, clientMessageId: cmid)
        }
    }

    private func sendUserUserMessage(_ text: String, attachmentIds: [String],
                                     localId: String, clientMessageId: String) async {
        guard let userId = AccountStore.shared.current?.id else {
            markUserMessageFailed(localId)
            return
        }
        // messages.attachments is jsonb shaped { ids: [...] }. user_user
        // sends INSERT straight into Supabase (no worker), so the ids have
        // to be written here — otherwise the canonical realtime row carries
        // no attachment and the peer (and our own rekeyed bubble) lose it.
        struct AttachmentIds: Encodable { let ids: [String] }
        struct Insert: Encodable {
            let client_message_id: String
            let conversation_id: String
            let user_id: String
            let role = "user"
            let status = "done"
            let content: String
            let attachments: AttachmentIds?
        }
        do {
            try await SupabaseStack.shared
                .from("messages")
                .insert(Insert(
                    client_message_id: clientMessageId,
                    conversation_id: conversation.id,
                    user_id: userId,
                    content: text,
                    attachments: attachmentIds.isEmpty ? nil : AttachmentIds(ids: attachmentIds)
                ))
                .execute()
            markUserMessageSent(localId)
        } catch {
            self.error = "发送失败: \(error.localizedDescription)"
            markUserMessageFailed(localId)
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
    /// via incremental insert/update.
    ///
    /// Two modes:
    ///   - regular: conversation.id is set, POST /v1/messages with convId
    ///   - start: conversation.id is empty (lazy-cloud-conv first turn),
    ///     pass `startBotId` and POST /v1/messages/start. Worker creates
    ///     the conv server-side and emits `event: meta` with the canonical
    ///     ids before any tokens. We wire those back into the optimistic
    ///     local row + conversation state on the fly.
    // Internal access — called from scheduleLookbackAutoFire (auto-fire
    // a no-input turn) in ConversationView+Realtime.swift.
    func sendViaSSE(text: String, attachmentIds: [String], autoLookback: Bool = false, userMsgId: String? = nil, clientMessageId: String? = nil, startBotId: String? = nil) {
        chatTurnTask?.cancel()
        flushRevealImmediately()
        // User taking action (or auto-fire firing) cancels the pending
        // 30s lookback grace timer either way.
        lookbackAutoFireTask?.cancel()
        lookbackAutoFireTask = nil
        // pending (= TypingDots in the header) gets lit on the SSE
        // `.connected` event — i.e. the moment the worker returns 200,
        // which means the bot/balance resolved and the model call is
        // about to fire. Stays on through streaming output, drops only
        // while a tool is running (gated by activeToolCount below).
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
        // Fresh bubble-id slate — `bubble` events rekey entries in here.
        turnBubbleIds = []
        // Fresh tool-call counter — last turn's count should never leak
        // into this turn's typing-dots gating.
        activeToolCount = 0

        let body: [String: Any] = {
            // Reuse the cmid bound to the optimistic row when there is one
            // (caller threads it through from `send()`); auto-fire turns
            // and any future caller without an optimistic row still get a
            // fresh id.
            let clientMsgId = clientMessageId ?? UUID().uuidString.lowercased()
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
            var b: [String: Any] = [
                "clientMessageId": clientMsgId,
                "recentContext": recent,
                // IANA tz so the server can format the per-turn time hint in
                // the user's local clock (server only knows UTC otherwise).
                "clientTz": TimeZone.current.identifier,
            ]
            if let startBotId {
                // Start flow: server creates the conv, no convId yet.
                b["botId"] = startBotId
            } else {
                b["conversationId"] = conversation.id
                let oldestId = messages.first { $0.id.range(of: "^[0-9a-f-]{36}$",
                                                            options: .regularExpression) != nil }?.id
                if let oldestId { b["oldestContextMessageId"] = oldestId }
                if autoLookback { b["autoLookback"] = true }
                if !activeLookbacks.isEmpty {
                    b["activeLookbacks"] = activeLookbacks.map { ["id": $0.id, "body_md": $0.body_md] }
                }
            }
            if !text.isEmpty { b["newMessage"] = text }
            if !attachmentIds.isEmpty { b["attachmentIds"] = attachmentIds }
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

        let path = startBotId == nil ? "v1/messages" : "v1/messages/start"
        chatTurnTask = Task { @MainActor in
            let splitter = BubbleSplitter()
            let stream = ChatStream().send(body: body, path: path)
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .connected:
                        // Server returned 200 — flip the optimistic user
                        // bubble from "sending" (light green) to "sent"
                        // (full green) AND light the typing dots right
                        // away: 200 means the worker has resolved the
                        // bot/balance and is about to call the model, so
                        // a reply is on the way. Dots stay on through
                        // streaming output, get suppressed only while a
                        // tool is running (see .toolCall / .toolResult).
                        if let userMsgId { markUserMessageSent(userMsgId) }
                        if !pending { pending = true }
                    case .meta(let convId, let userMsgServerId):
                        // Lazy-cloud-conv first turn: rekey the optimistic
                        // local row to the canonical user-message id and
                        // promote the conversation from pending to materialised
                        // so subsequent UI (header, conv list refresh, realtime
                        // subscription) tracks the cloud row.
                        if conversation.id.isEmpty, !convId.isEmpty {
                            conversation = Conversation(
                                id: convId,
                                bot_id: conversation.bot_id,
                                user_id: conversation.user_id,
                                title: conversation.title,
                                feature_type: conversation.feature_type,
                                conversation_type: conversation.conversation_type,
                                last_activity_at: conversation.last_activity_at,
                                round_count: conversation.round_count,
                                bot_name: conversation.bot_name,
                                last_message_content: conversation.last_message_content,
                                last_message_sender_type: conversation.last_message_sender_type,
                                model_override: conversation.model_override,
                                provider_override: conversation.provider_override
                            )
                            await subscribeRealtime()
                            onChange()
                        }
                        if let localId = userMsgId, !userMsgServerId.isEmpty,
                           let idx = messages.firstIndex(where: { $0.id == localId }) {
                            let prev = messages[idx]
                            messages[idx] = ChatMessage(
                                id: userMsgServerId,
                                conversation_id: convId.isEmpty ? prev.conversation_id : convId,
                                sender_type: prev.sender_type,
                                sender_id: prev.sender_id,
                                content: prev.content,
                                created_at: prev.created_at,
                                attachments: prev.attachments,
                                status: nil
                            )
                            // Move tracked cmid + tool trace bookkeeping onto
                            // the canonical id so realtime echoes / trace
                            // expansion all key off the same row from now on.
                            if let cmid = localMsgClientIds.removeValue(forKey: localId) {
                                localMsgClientIds[userMsgServerId] = cmid
                            }
                            if let trace = tracesByUserMsgId.removeValue(forKey: localId) {
                                tracesByUserMsgId[userMsgServerId] = trace
                            }
                            if liveTraceUserMsgId == localId {
                                liveTraceUserMsgId = userMsgServerId
                            }
                        }
                    case .typing:
                        // Worker's typing pulse, fired right before each
                        // LLM round. Treated as a redundant top-up of the
                        // dots — `.connected` already lit them on 200,
                        // and the second round (after tools) re-asserts
                        // them via `.toolResult` clearing activeToolCount.
                        if !pending && activeToolCount == 0 { pending = true }
                    case .token(let delta):
                        if !pending { pending = true }
                        splitter.accept(token: delta)
                    case .bubble(let id, let index, _, _):
                        // The server persisted this bubble under canonical
                        // `id`. Rekey our optimistic live-* bubble (bubble
                        // `index`, 1-based) to that id NOW — so the realtime
                        // INSERT that follows resolves as a plain id-keyed
                        // upsert, never a duplicate, regardless of which
                        // path arrives first. `.begin` for a bubble always
                        // precedes its `bubble` event (the event trails all
                        // of the bubble's tokens), so the live-* row is
                        // already in `turnBubbleIds` here.
                        if !id.isEmpty, index >= 1, index <= turnBubbleIds.count {
                            rekeyBotBubble(at: index - 1, to: id)
                        }
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
                        // While a tool is running the model isn't producing
                        // user-visible output — the tool-trace row covers
                        // that phase. Suppress dots until every outstanding
                        // tool returns.
                        activeToolCount += 1
                        pending = false
                        appendToolCall(name: name, input: input)
                    case .toolResult(let name, let summary, let error, let detail):
                        activeToolCount = max(0, activeToolCount - 1)
                        if activeToolCount == 0 { pending = true }
                        completeToolCall(name: name, summary: summary, error: error, detail: detail)
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
                        // Start-mode failure with no meta yet means the
                        // worker rolled back the cloud conv (no bot output
                        // ever landed). Mirror that on the client: red the
                        // user's bubble, surface the reason, and leave
                        // conversation.id empty so retrying re-runs the
                        // /start path with the same cmid (idempotent at
                        // the worker, so a second tap is safe).
                        if startBotId != nil && conversation.id.isEmpty,
                           let userMsgId {
                            markUserMessageFailed(userMsgId)
                            self.error = msg.isEmpty ? "发送失败" : msg
                        }
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
            // Re-check the freeze flag after a turn — billing for this
            // turn may have flipped the caller from active to overdrawn,
            // and the banner / message filter need to update without
            // waiting for a manual refresh.
            await loadGroupFreezeIfNeeded()
        }
    }

    // Tool-call trace accumulation lives in ConversationView+ToolTrace.swift.

    // MARK: - Lookback notes (invisible context-edit notes from the bot)

    struct LookbackNote: Identifiable, Equatable {
        let id: String
        let body_md: String
        let active: Bool
    }

    // loadActiveLookbacks lives in ConversationView+Loading.swift.

    // applyLookbackEvent + scheduleLookbackAutoFire +
    // applyRealtimeEvent live in ConversationView+Realtime.swift.

    /// Decode a Realtime row's `citations` value into the typed model. Returns
    /// nil when absent / null / malformed — callers fall back to whatever was
    /// already in `citationsByMsgId` for the row (e.g. the live-bubble snapshot).
    // parseCitations lives in ConversationView+ToolTrace.swift.


    // applyBubbleEmissions + applyDirect + the streaming reveal smoother
    // (startRevealTaskIfNeeded + flushRevealImmediately + tuning lets)
    // live in ConversationView+Streaming.swift.

    // ── REST: history + delete ─────────────────────────────────────────────

    // loadSkills + loadPeerProfileIfNeeded + fetchGroupMemberProfiles +
    // loadGroupSendersIfNeeded + loadGroupFreezeIfNeeded +
    // loadPendingContinueIfNeeded + loadHistory live in
    // ConversationView+Loading.swift.

    // Group-only surfaces — groupSenderFor + frozenComposerBanner +
    // mentionPrefix / mentionCandidates / mentionPickerOverlay /
    // insertMention + continueRequestBanner / decideContinue — live in
    // ConversationView+Group.swift.

    // applyModelPick + patchConversationModel + patchConversationVisionModel
    // + patchBotDefaultModel live in ConversationView+Model.swift.

    // Recall + delete + URLCache scrubbing live in ConversationView+Recall.swift.

    // ingestPhotos + ingestCameraImage live in ConversationView+Attachments.swift.
}

struct PendingAttachment: Identifiable, Hashable {
    let id: String
    let mime: String
    let size: Int
    /// Original filename — set for non-image files, nil for images.
    var filename: String? = nil

    var isImage: Bool { mime.lowercased().hasPrefix("image/") }

    /// Materialise into an `Attachment` for an optimistic bubble. The
    /// worker-served path is `/v1/uploads/<id>` (the auth-gated route);
    /// `kind` is left to the renderer, which classifies by `mime`.
    func asAttachment() -> Attachment {
        Attachment(
            id: id, kind: isImage ? "image" : "file", mime: mime,
            size: size, width: nil, height: nil,
            url: "/v1/uploads/\(id)", filename: filename
        )
    }
}

/// Identifiable wrapper so a `String` body can drive a `.sheet(item:)` —
/// SwiftUI wants an `Identifiable` payload to disambiguate presentations.
private struct SkillDraft: Identifiable {
    let body: String
    var id: String { String(body.hashValue) }
}

/// Identifiable wrapper for the "复制部分文字" sheet's body — same role as
/// `SkillDraft` above, separate type so two different bodies can't
/// race onto the same sheet binding.
private struct SelectableTextBody: Identifiable {
    let body: String
    var id: String { String(body.hashValue) }
}

/// Read-only `UITextView` that allows native selection + copy.
/// SwiftUI's `Text(...).textSelection(.enabled)` is unreliable inside
/// a `ScrollView` in a sheet — the scroll gesture pre-empts the
/// selection handles, so partial copy silently fails. A `UITextView`
/// with `isEditable = false`, `isSelectable = true` gets the real
/// UIKit selection + "Copy" / "Look Up" menu, and scrolls itself.
private struct SelectableTextUIView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: Theme.Fonts.scaled(16))
        tv.textColor = UIColor(Theme.Palette.ink)
        tv.tintColor = UIColor(Theme.Palette.accent)
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        tv.textContainer.lineFragmentPadding = 0
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }
}

/// Standalone selectable-text presentation. The bubble itself has
/// `.contextMenu`, which on iOS pre-empts the long-press selection
/// gesture — so partial copy from inside the bubble doesn't work.
/// This sheet renders the same content in a surface with no
/// competing gesture, where standard selection handles + the system
/// "Copy" / "Look Up" menu behave normally.
private struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextUIView(text: text)
                .background(Theme.Palette.canvas)
                .navigationTitle("复制部分文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                            .tint(Theme.Palette.accent)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIPasteboard.general.string = text
                            Haptics.tap()
                        } label: { Label("全部复制", systemImage: "doc.on.doc") }
                            .tint(Theme.Palette.accent)
                    }
                }
        }
    }
}

/// Decoded shape of a `log_kind='recall'` row's `log_payload` jsonb.
/// Mirrors what the edge worker emits in apps/edge/src/routes/messages.ts.
/// `original_created_at` arrives as an ISO-8601 string from Postgres
/// (jsonb encoding of a timestamptz column); we parse it into epoch
/// seconds for the tombstone's relative-time formatter.
struct RecallPayload: Decodable, Hashable {
    let original_message_id: String?
    let original_created_at: String?
    let recaller_user_id: String?

    var original_created_at_secs: Int {
        guard let s = original_created_at else { return 0 }
        return ServerTimestamp.epochSeconds(s, default: 0)
    }
}

/// Decoded shape of a `messages.attachments` jsonb column. Worker writes
/// `{ ids: [uuid, ...] }` on insert; we only read the ids back to scrub
/// URLCache on recall — the full Attachment objects are reconstructed
/// elsewhere for rendering.
struct AttachmentRef: Decodable, Hashable {
    let ids: [String]?
}

/// Centered "我撤回了 X 的一条消息" / "对方撤回了 X 的一条消息" pill.
/// Rendered inline by ConversationView whenever a `sender_type ==
/// "recall_log"` ChatMessage shows up in the timeline. The original
/// message's epoch-seconds is encoded in the row's `content` field
/// — see loadHistory's row mapper for the upstream side.
struct RecallTombstoneView: View {
    let wasMine: Bool
    let originalAt: Date

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityLabel(label)
    }

    private var label: String {
        let timePhrase = RelativeMessageTime.format(originalAt, style: .tombstone)
        return wasMine
            ? "你撤回了 \(timePhrase) 的一条消息"
            : "对方撤回了 \(timePhrase) 的一条消息"
    }
}

// MARK: - Pre-chat action button

/// One pill in the pre-chat action bar shown under a fresh bot chat's
/// empty state. Surface-muted capsule with an icon over a label, sized
/// so the three actions sit evenly across the row.
private struct PreChatActionButton: View {
    let title: String
    let systemImage: String
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .regular))
                        .opacity(busy ? 0 : 1)
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 30)
                Text(title)
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.ink)
            .frame(width: 92, height: 92)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.Palette.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1.5)
        }
        .buttonStyle(.plain)
    }
}
