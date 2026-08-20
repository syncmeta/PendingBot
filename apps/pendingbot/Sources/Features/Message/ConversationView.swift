import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#endif
import Combine
import OSLog
import Supabase
import UniformTypeIdentifiers

private let log = Logger.category("conversation")

/// One conversation. Loads history from Supabase, runs the user-direct
/// chat turn over Worker SSE (ChatStream), and listens for cross-device /
/// background-task messages via the Cloudflare realtime hub WebSocket
/// (`/v1/realtime-hub/conv/<id>` — replaced Supabase Realtime on
/// 2026-05-16).

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
    /// Self-fetched bot record for the `bot == nil` case. The Mac 3-column
    /// shell builds the detail column from a *different* MessageTabView /
    /// FriendsTabView instance than the list, so `bot(for:)` reads an empty
    /// `@State bots` and passes `bot: nil`. `resolveBotIfNeeded()` (in
    /// ConversationView+Loading) fills this from the conv's / pending peer's
    /// bot id so the header model suffix + BotConfigView entry come back.
    /// Stays nil on iOS, where the list always supplies a real `bot`.
    @State var resolvedBot: Bot?
    /// The bot to drive header + settings off of: the caller-supplied one
    /// when present, else the self-resolved record. On iOS this is always
    /// `bot` (the resolve path is gated on `bot == nil` and never fires).
    var effectiveBot: Bot? { bot ?? resolvedBot }
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
    @State var cameraImage: PlatformImage?
    /// Set true to present the system document picker (any file type).
    @State var showFileImporter = false
    /// Set true to present the photo library picker / camera. Driven by the
    /// composer's "+" action tiles. Presented from the main view tree (not
    /// from inside the composer's inputAccessoryView) so the pickers are
    /// reliable — same pattern as `showFileImporter`.
    @State var showPhotoPicker = false
    @State var showCamera = false
    /// Composer content height (excluding the home-indicator strip), reported
    /// by the inputAccessoryView. The message list reserves this much bottom
    /// inset while the keyboard is DOWN so the floating composer doesn't cover
    /// the last message. Default ≈ a one-line bar so the very first frame is
    /// already roughly right (no "last message hidden until you scroll").
    @State private var composerContentHeight: CGFloat = 52
    /// True while the real software keyboard is up. When up, SwiftUI's
    /// automatic keyboard avoidance already insets for keyboard+accessory, so
    /// the manual composer inset is dropped to 0 to avoid double-counting.
    @State private var keyboardVisible = false
    /// Per-id attachment metadata (mime/filename) used to hydrate
    /// AttachmentGrid for loaded/realtime messages. Populated on upload
    /// and on history load — see bubbleMessage.
    @State var attachmentMetaById: [String: Attachment] = [:]
    @State var error: String?
    /// 余额不足(402 insufficient_balance)专属提示。与普通 error alert 分开:
    /// 弹一张带"去充值"的卡片,点击直接开 PurchaseSheet(而不是干巴巴的 alert)。
    @State private var showInsufficientBalance = false
    @State private var showRechargeSheet = false
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
    /// Cloudflare realtime hub subscription for this conv (WebSocket to
    /// /v1/realtime-hub/conv/<id>; replaced Supabase Realtime on
    /// 2026-05-16). Dropped when the view disappears. Picks up cross-
    /// device messages and bot rows that land via background paths
    /// (cron, review).
    @State var realtimeToken: ConvSubscriptionToken?
    /// Lookback notes the bot wrote about prior turns (pushed from
    /// pendingbot.bot_lookbacks via the Cloudflare realtime hub).
    /// Invisible to the user; passed in `activeLookbacks` on the next
    /// POST so the bot sees them as context.
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
    /// permission_request payload per log message id (spec v2 §10).
    /// Populated by loadHistory from `role='log'` rows with
    /// `log_kind='permission_request'`. The timeline renderer swaps in
    /// a `PermissionRequestCardView` for each entry; `decidePermissionRequest`
    /// updates the status when the user taps 批准 / 拒绝.
    @State var permissionRequestsByMsgId: [String: PermissionRequestPayload] = [:]
    /// Message ids whose permission-decide HTTP call is currently in
    /// flight. Used to disable the card's buttons mid-round-trip.
    @State var permissionRequestBusy: Set<String> = []
    /// Message ids of `role='log'` rows with `log_kind='guess_prompt'`
    /// (Model Blind Box). Populated in loadHistory; the timeline renderer
    /// swaps in a `GuessPromptCard` (instead of a bubble) for each entry,
    /// which opens the `GuessModelSheet` while the model isn't revealed.
    @State var guessPromptMsgIds: Set<String> = []
    /// Local id of the user message currently driving an SSE turn — set in
    /// sendViaSSE before the stream starts, cleared when the turn ends.
    /// Multiple traces can land for the same user msg if the agent loops.
    @State var liveTraceUserMsgId: String?
    /// Web-search citations attached to a bot bubble, keyed by message id.
    /// Sources: history `select citations`, hub-pushed UPDATE on the row
    /// (CF realtime hub), and the per-turn `citations` SSE event copied
    /// to each in-flight bubble.
    /// `MarkdownText` reads the entry to resolve inline `[N]` markers.
    @State var citationsByMsgId: [String: [MessageCitation]] = [:]
    /// Cumulative citations for the in-flight turn — last value pushed by the
    /// `citations` SSE event. Snapshotted onto each bubble created during
    /// the turn so the live preview can resolve `[N]` taps before the
    /// canonical row arrives via the realtime hub.
    @State var liveCitations: [MessageCitation] = []
    /// Per-trace citations bucket so the inline `搜索` trace can list the
    /// hits it surfaced even after the turn ends + `liveCitations` resets.
    /// Keyed by user-message id like `tracesByUserMsgId`; rekeyed on the
    /// optimistic-id → canonical-id swap so re-expanding an old trace still
    /// shows its results.
    @State var traceCitationsByUserMsgId: [String: [MessageCitation]] = [:]
    /// Attachment ids per message id. Populated from `messages.attachments`
    /// jsonb on load + via the realtime hub, and from the local pending
    /// attachment set when the user sends. Used on recall (own + peer's,
    /// via the status='deleted' hub-pushed UPDATE) to scrub the matching
    /// responses from URLCache.shared so cached image bytes for a recalled message
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
    /// App-level call ownership. The call session itself lives on
    /// `CallCenter.shared`, so the user can minimize the call surface,
    /// navigate to other tabs, and the transport keeps running. The
    /// full-screen cover and the floating pill are presented by
    /// `TabRoot`, not here. Call slice is iOS-only — on macOS the
    /// conversation works fully minus the voice-call entry.
    #if os(iOS)
    @Environment(CallCenter.self) var callCenter
    #endif

    // Jump-to-latest pill state. `isAtBottom` is recomputed from a
    // geometry preference on the bottom marker; while it's false, new
    // messages don't auto-scroll — they bump `unreadCount` and surface
    // the bottom-right pill instead. The user's own sends always scroll
    // regardless (see the messages.count onChange).
    @State private var isAtBottom = true
    @State private var unreadCount = 0
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var messageStackContentHeight: CGFloat = 0
    /// Flips on the first history population so the conv opens already
    /// parked at the latest message: that initial settle jumps with no
    /// animation (no visible scroll), and only later arrivals animate.
    @State private var didInitialScroll = false

    private var composerScrollInset: CGFloat {
        keyboardVisible ? 0 : composerContentHeight
    }

    private var messageContentNeedsComposerInset: Bool {
        guard composerScrollInset > 0, scrollViewportHeight > 0 else { return false }
        return messageStackContentHeight > max(0, scrollViewportHeight - composerScrollInset) + 1
    }

    private var effectiveComposerScrollInset: CGFloat {
        messageContentNeedsComposerInset ? composerScrollInset : 0
    }

    private var minimumMessageStackHeight: CGFloat {
        max(0, scrollViewportHeight - effectiveComposerScrollInset)
    }

    private var messageStackCanScroll: Bool {
        messageStackContentHeight + effectiveComposerScrollInset > scrollViewportHeight + 1
    }

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

    /// Maps `local-<uuid>` → `client_message_id` so a hub-pushed INSERT echo
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

    /// Conversation-level drawn-model state from `GET /v1/conversations/:id/model`.
    /// nil until loaded (or when the fetch fails / the conv is user_user); the
    /// header pill falls back to the bot's pinned model in that case.
    @State var convModelState: ConvModelState? = nil

    /// 盲盒「猜模型」sheet 的呈现开关。由 composer "+" 菜单的「猜模型」tile 翻起；
    /// 仅 `shouldOfferGuess` 为真时该 tile 才出现。
    @State private var showGuessSheet = false
    /// 盲盒「换模型」sheet 的呈现开关。任何带 bot 的 conv 都可换。
    @State private var showSwitchSheet = false

    /// 全局「显示 PendingModel 还是真实模型」偏好(设置页那档,跟账号走)。
    /// 用 @AppStorage 读同一个键 —— 设置页一改,正开着的会话 pill 立刻跟着变,
    /// 不用重进会话。
    @AppStorage(ModelRevealPreference.storageKey)
    private var modelRevealPrefRaw = ModelRevealPreference.default.rawValue

    /// 会话侧的盲盒事实。nil = 还没取到 `GET /v1/conversations/:id/model`。
    private var modelRevealFacts: ModelRevealFacts? {
        guard let s = convModelState else { return nil }
        return ModelRevealFacts(revealMode: s.reveal_mode,
                                modelRevealed: s.model_revealed,
                                hasPool: s.has_pool)
    }

    /// 全局档位 + 会话事实 → 显示真名 / 是否给猜的入口。判定本身在
    /// `ModelRevealPolicy`(纯函数,有独立测试);这里只负责喂数据。
    private var modelRevealDecision: ModelRevealDecision {
        ModelRevealPolicy.decide(
            preference: ModelRevealPreference.normalized(modelRevealPrefRaw),
            facts: modelRevealFacts
        )
    }

    /// 是否给该 conv 提供「猜模型」入口。
    private var shouldOfferGuess: Bool { modelRevealDecision.offersGuess }

    /// "<bot_name> · <model-tag>". 模型标签显示真名还是 "PendingModel",由
    /// `modelRevealDecision` 决定(全局档位压过 bot 的 revealMode)。会话状态
    /// 没取到时真名回落成 bot 固定的模型(bots.model_id)。
    private var botName: String {
        let base = effectiveBot?.display_name ?? conversation.bot_name ?? conversation.bot_id
        guard conversation.conversation_type != "user_user" else { return base }
        guard modelRevealDecision.showsRealName else {
            return "\(base) · PendingModel"
        }
        // 会话态在手就用它抽中的模型;没取到才回落 bot 固定的模型(老行为)。
        let slug: String?
        if let s = convModelState {
            slug = s.current_model_slug
        } else {
            slug = effectiveBot?.model.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let slug else { return base }
        return "\(base) · \(modelCatalog.displayName(for: slug))"
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

    @MainActor
    init(conversation: Conversation, bot: Bot?, pendingPeer: PendingPeer? = nil,
         onChange: @escaping () -> Void = {}) {
        self._conversation = State(initialValue: conversation)
        self.bot = bot
        self._pendingPeer = State(initialValue: pendingPeer)
        self.onChange = onChange
        // When the caller didn't supply a bot — the Mac/iPad 3-column shell
        // builds the detail column from a *different* MessageTabView instance
        // whose `bots` @State is empty, so `bot` arrives nil — seed
        // `resolvedBot` synchronously from the local bots cache so the header
        // name + model suffix + voice button paint from cache on the FIRST
        // frame instead of popping in only after the async
        // `resolveBotIfNeeded()` lands. Falls back to nil (the prior async
        // path) when the bot isn't cached, so non-added/public bots are
        // unchanged.
        let seededBot: Bot? = (bot == nil && !conversation.bot_id.isEmpty)
            ? CacheRepository.cachedBots()
                .first(where: { $0.id == conversation.bot_id })
                .map {
                    Bot(id: $0.id, display_name: $0.display_name, access_mode: nil,
                        model: $0.model_id, visibility: $0.visibility,
                        creator_id: $0.creator_id, voice_call_enabled: $0.voice_call_enabled)
                }
            : nil
        self._resolvedBot = State(initialValue: seededBot)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            #if os(iOS)
            activeCallBanner
            #endif

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
                            } else if msg.sender_type == "permission_request_log",
                                      let payload = permissionRequestsByMsgId[msg.id] {
                                // Agent's request_permission card
                                // (spec v2 §10). 批准 / 拒绝 while
                                // payload.status == 'pending'; once
                                // decided it just shows a status badge.
                                // sessionLabel uses a generic "Session"
                                // since session names aren't threaded
                                // through to ConversationView yet.
                                PermissionRequestCardView(
                                    sessionLabel: "Session",
                                    payload: payload,
                                    busy: permissionRequestBusy.contains(msg.id),
                                    onApprove: {
                                        Task { await decidePermissionRequest(msg.id, decision: .approve) }
                                    },
                                    onDeny: {
                                        Task { await decidePermissionRequest(msg.id, decision: .reject) }
                                    }
                                )
                                .id(msg.id)
                                .transition(.opacity)
                            } else if msg.sender_type == "guess_prompt_log" {
                                // Model Blind Box (Task 9.1) — the
                                // `prompt_model_guess` tool dropped a
                                // 「猜一猜」card here. Tapping it opens the
                                // GuessModelSheet while the model isn't
                                // revealed; once revealed (or in disclose
                                // mode) it just shows the friendly name.
                                // 全局档位同样管着这张卡:always_real 时它
                                // 直接以「已揭晓」形态显示真名(不再邀请猜),
                                // always_blind 时即使 bot 是 disclose 也保持
                                // 可猜 —— 与 pill / "+" 菜单同一个判定,不另
                                // 立一套规则。
                                GuessPromptCard(
                                    revealed: modelRevealDecision.showsRealName,
                                    revealedName: convModelState?.current_model_slug
                                        .map { modelCatalog.displayName(for: $0) },
                                    onTapGuess: { showGuessSheet = true }
                                )
                                .id("guess:\(msg.id)")
                                .transition(.opacity)
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
                                       onRetry: { retryFailedMessage(msg) },
                                       // 右键(macOS)/长按(iOS)头像 → @ 该发送者。
                                       // 仅群消息有 groupSender，modifier 内 gate 掉 1:1/自己。
                                       onMentionSender: { appendMention($0) }) {
                                    Button {
                                        Clipboard.copy(msg.content)
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
                                            // 重新生成: re-stream a fresh bot answer
                                            // to this prompt via POST /v1/messages/
                                            // :id/regenerate (:id = this user msg).
                                            // Only meaningful in bot convs (a
                                            // human peer has no model to re-roll);
                                            // gate on a persisted UUID id so we
                                            // never POST a local- optimistic id.
                                            if conversation.conversation_type != "user_user",
                                               msg.id.range(of: "^[0-9a-f-]{36}$",
                                                            options: .regularExpression) != nil {
                                                Button {
                                                    Task { await regenerate(promptId: msg.id) }
                                                } label: {
                                                    Label("重新生成", systemImage: "arrow.clockwise")
                                                }
                                            }
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
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { updateMessageStackContentHeight(geo.size.height) }
                                .onChange(of: geo.size.height) { _, h in
                                    updateMessageStackContentHeight(h)
                                }
                        }
                    )
                    // Short conversations should occupy exactly one viewport
                    // and stay top-aligned. Only once the natural message
                    // content outgrows the area above the docked composer do we
                    // subtract the composer clearance and add that clearance as
                    // scroll content margin below.
                    .frame(minHeight: minimumMessageStackHeight, alignment: .top)
                    .readableColumnWidth()
                }
                .coordinateSpace(.named("convScroll"))
                // 初始进入聊天时让 ScrollView 锚在底部 — 否则 LazyVStack 从顶部
                // 开始 materialise,后续的 scrollToBottom 在底部行尚未测量时
                // 落位,最终最后一条会贴 ScrollView frame 底、被 composer 盖住。
                // 配合 .safeAreaInset 后,底部锚点位于 composer 上沿。
                .defaultScrollAnchor(.bottom)
                // Reserve room for the floating composer by shrinking the
                // scrollable viewport, not by appending bottom margin to the
                // scroll content. A content margin becomes reachable space
                // after the last bubble, which feels like an invisible message.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: effectiveComposerScrollInset)
                        .allowsHitTesting(false)
                }
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
                .platformScrollKeyboardDismiss()
                .onChange(of: messages.count) { oldCount, newCount in
                    // The user's own send always scrolls into view; incoming
                    // messages only auto-scroll when already at the bottom.
                    // Otherwise they bump the unread pill instead of yanking
                    // the user away from the history they're reading.
                    let mine = messages.last?
                        .isMine(currentUserId: AccountStore.shared.current?.id) ?? false
                    if !didInitialScroll && newCount > 0 {
                        // First history population (cache or network) — land
                        // straight on the latest message with no animated
                        // scroll, so opening the conv doesn't visibly skid
                        // past or jump around while rows settle.
                        didInitialScroll = true
                        unreadCount = 0
                        scrollToBottom(proxy: proxy, animated: false)
                    } else if isAtBottom || mine {
                        unreadCount = 0
                        scrollToBottom(proxy: proxy)
                    } else if newCount > oldCount {
                        withAnimation(.easeOut(duration: 0.2)) {
                            unreadCount += newCount - oldCount
                        }
                    }
                }
                .onChange(of: messageStackCanScroll) { _, canScroll in
                    guard canScroll, didInitialScroll, isAtBottom else { return }
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if unreadCount > 0 && !isAtBottom {
                        unreadJumpButton(proxy: proxy)
                    }
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(macOS)
        // The main macOS scene hides the title bar, but SwiftUI still reserves
        // its top safe area for the toolbar. The conversation header lives in
        // the detail pane, away from the traffic lights, so let it occupy that
        // space instead of leaving a blank strip above the chat.
        .ignoresSafeArea(.container, edges: .top)
        #endif
        #if os(iOS)
        // System nav bar stays hidden — this view paints its own `chatHeader`.
        // Only valid on iOS; macOS NavigationStack detail has no nav bar to hide.
        .toolbar(.hidden, for: .navigationBar)
        // Mount the composer (plus its banners) as a UIKit inputAccessoryView
        // rather than a SwiftUI bottom safe-area inset. The accessory is
        // physically attached to the keyboard, so it tracks
        // `.scrollDismissesKeyboard(.interactively)` frame-by-frame instead of
        // lagging behind on SwiftUI's animation curve. The message list keeps
        // its automatic keyboard avoidance — iOS reports the accessory as part
        // of the keyboard frame, so the list insets correctly whether the bar
        // is docked or riding the keyboard. See ChatComposerAccessory.swift.
        .background { composerAccessory }
        #else
        // macOS has no UIKit inputAccessoryView / keyboard-frame tracking, so
        // the cross-platform ComposerView is hosted in a normal bottom
        // safe-area inset instead. Same bindings the iOS accessory passes.
        .safeAreaInset(edge: .bottom, spacing: 0) { macComposer }
        #endif
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoPickerItems,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { cameraImage = image }
            }
            .ignoresSafeArea()
        }
        // Track whether the real software keyboard is up, to gate the
        // composer's bottom inset (see `.contentMargins` above). Use the
        // discrete show/hide events (not willChangeFrame) so an interactive
        // scroll-to-dismiss doesn't flip the inset mid-drag — keyboardVisible
        // stays true through the drag (auto-avoidance follows the keyboard
        // down) and flips on commit. The height guard on show ignores the
        // short docked accessory bar (and a hardware keyboard, where only the
        // bar shows, correctly reads as "down").
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification
        )) { note in
            guard let info = note.userInfo,
                  let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            let visibleH = max(0, UIScreen.main.bounds.height - endFrame.minY)
            guard visibleH > 180, !keyboardVisible else { return }
            let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { note in
            guard keyboardVisible else { return }
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) { keyboardVisible = false }
        }
        #endif
        .onAppear {
            // Set synchronously so a push arriving in the first few ms
            // after view-appear sees the right id. .task below is async-
            // scheduled and leaves a tiny race window in which willPresent
            // reads nil and pops a foreground banner.
            if !conversation.id.isEmpty {
                #if os(iOS)
                PushService.shared.activeConversationId = conversation.id
                #endif
                // Pin this conv read while it's on screen — any message
                // that arrives now stays read no matter which realtime
                // path (or refetch) reports it.
                UnreadStore.shared.enterConversation(
                    conversation.id,
                    throughLastMessageId: conversation.last_message_id
                )
            }
        }
        .task {
            // Resolve the bot record when the shell handed us `bot: nil`
            // (Mac 3-column detail is a separate instance from the list).
            // Before the pending-conv guard so pending bot chats — whose
            // bot id rides on `pendingPeer` — also get the header model
            // suffix + BotConfigView entry. No-op on iOS (bot is non-nil).
            await resolveBotIfNeeded()
            // Pending convs (lazy-created on first send) have no row yet —
            // skip history / skills / realtime until they materialise.
            guard !conversation.id.isEmpty else { return }
            // Paint group sender avatars + nicknames from cache on the first
            // frame, before any await — otherwise this cache read sits behind
            // loadHistory's round-trip and the bubbles flash id-prefix labels
            // for ~1s. (1:1 peers are carried in via pendingPeer, so they're
            // already correct on frame one.)
            hydrateGroupSendersFromCache()
            // Refresh peer profile + group senders concurrently with the
            // history load so the names/avatars don't queue up behind it.
            // @MainActor keeps their @State writes on the main actor.
            let identity = Task { @MainActor in
                await loadPeerProfileIfNeeded()
                await loadGroupSendersIfNeeded()
            }
            // 盲盒会话模型状态 — drives the header pill; fetch concurrently with
            // history so the pill doesn't queue behind loadHistory's round-trip.
            let convModel = Task { @MainActor in await loadConvModelState() }
            await loadHistory()
            await loadSkills()
            await loadActiveLookbacks()
            await subscribeRealtime()
            // Ensure the roster is in before the auto-join below reads it.
            await identity.value
            await convModel.value
            await loadPendingContinueIfNeeded()
            // Cold-launch path: we arrived here because the user
            // accepted a CallKit incoming voice ring. Now that
            // loadGroupSendersIfNeeded() has populated `groupSenders`
            // (required for GroupCallSession's roster labels), open
            // GroupCallView so the user doesn't have to tap "join"
            // after already accepting on the system call surface.
            #if os(iOS)
            consumePendingAutoJoinIfMatches()
            #endif
        }
        #if os(iOS)
        .onChange(of: IncomingCallStore.shared.pendingAutoJoinConversationId) { _, _ in
            // Warm-launch path: app was already open in this conv when
            // the push landed and the user accepted via CallKit; the
            // .task above already ran, so this onChange covers the
            // late arrival of the auto-join signal.
            consumePendingAutoJoinIfMatches()
        }
        #endif
        .onDisappear {
            #if os(iOS)
            if PushService.shared.activeConversationId == conversation.id {
                PushService.shared.activeConversationId = nil
            }
            #endif
            UnreadStore.shared.leaveConversation(
                conversation.id,
                throughLastMessageId: messages.last?.id ?? conversation.last_message_id
            )
            if let token = realtimeToken {
                Task { await RealtimeManager.shared.stopConvChannel(token) }
                realtimeToken = nil
            }
            lookbackAutoFireTask?.cancel()
            lookbackAutoFireTask = nil
            revealTask?.cancel()
            revealTask = nil
        }
        // Call full-screen covers live on TabRoot — see CallHostWrapper.
        // Hosted there so minimizing the call (chevron-down) hides the
        // surface without tearing down the session, and the user can
        // browse other tabs while it keeps running.
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
            } else if let bot = effectiveBot {
                BotConfigView(bot: bot, currentUserId: AccountStore.shared.current?.id)
            }
        }
        .navigationDestination(isPresented: $showingBotConfig) {
            // Bot-level config (model / voice / vision / envelope /
            // lookback / skills). Reached from the pre-chat action bar.
            if let bot = effectiveBot {
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
            .platformDragIndicator()
        }
        .sheet(item: Binding(
            get: { selectableTextBody.map { SelectableTextBody(body: $0) } },
            set: { selectableTextBody = $0?.body }
        )) { body in
            SelectableTextSheet(text: body.body)
                .tint(Theme.Palette.accent)
                .platformDetents([.medium, .large])
                .platformDragIndicator()
        }
        .sheet(isPresented: $showGuessSheet) {
            GuessModelSheet(conversationId: conversation.id) { _ in
                Task { await loadConvModelState() }
            }
            .environmentObject(modelCatalog)
            .tint(Theme.Palette.accent)
            .platformDragIndicator()
        }
        .sheet(isPresented: $showSwitchSheet) {
            SwitchModelSheet(
                conversationId: conversation.id,
                hasPool: convModelState?.has_pool ?? false
            ) {
                Task { await loadConvModelState() }
            }
            .environmentObject(modelCatalog)
            .tint(Theme.Palette.accent)
            .platformDragIndicator()
        }
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            uploadTasks.append(Task { await ingestPhotos(items) })
        }
        #if os(iOS)
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            uploadTasks.append(Task { await ingestCameraImage(image) })
        }
        #endif
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
        .alert("余额不足", isPresented: $showInsufficientBalance) {
            Button("去充值") { showRechargeSheet = true }
            Button("好", role: .cancel) {}
        } message: {
            Text("你的 PNC 余额不足以完成这次对话，充值后即可继续。")
        }
        .sheet(isPresented: $showRechargeSheet) {
            PurchaseSheet()
        }
    }

    /// 把一次发送/回复失败落到合适的 UI 上:若是 402 insufficient_balance
    /// (后端返回体含该 code),弹"去充值"卡片;否则走普通 error alert。
    /// `rawText` 可传原始错误串或响应体 —— 只做子串检测,对两条发送路径(群 raw
    /// URLRequest / 私聊 SSE)都成立。
    func presentSendFailure(_ rawText: String) {
        if rawText.contains("insufficient_balance") {
            showInsufficientBalance = true
        } else {
            self.error = rawText
        }
    }

    #if os(iOS)
    /// The composer + its banners (continue-request / @-mention picker),
    /// mounted as a UIKit inputAccessoryView so it tracks the keyboard
    /// frame-by-frame. Extracted from `body` so the large initializer doesn't
    /// blow the type-checker's budget inside body's expression tree. See
    /// ChatComposerAccessory.swift.
    private var composerAccessory: some View {
        ChatComposerAccessory(
            content: ComposerAccessoryContent(
                input: $input,
                pendingAttachments: $pendingAttachments,
                photoPickerItems: $photoPickerItems,
                cameraImage: $cameraImage,
                showFileImporter: $showFileImporter,
                showPhotoPicker: $showPhotoPicker,
                showCamera: $showCamera,
                pendingContinue: pendingContinue,
                continueDeciding: continueDeciding,
                conversationType: conversation.conversation_type ?? "",
                mentionActive: mentionPrefix != nil,
                mentionCandidates: mentionPrefix.map { mentionCandidates(prefix: $0) } ?? [],
                canSend: canSend,
                isStreaming: chatTurnTask != nil,
                onSend: { Task { await send() } },
                onStop: {
                    chatTurnTask?.cancel()
                    flushRevealImmediately()
                },
                // Show 检查 only when the conv has a single bot — group
                // dispatches across multiple bots and user_user has none.
                onLookback: (conversation.conversation_type == "user_bot"
                             || conversation.conversation_type == "self")
                    ? { Task { await triggerManualLookback() } }
                    : nil,
                onGuessModel: shouldOfferGuess ? { showGuessSheet = true } : nil,
                onSwitchModel: { showSwitchSheet = true },
                onInsertMention: { sender in
                    if let prefix = mentionPrefix {
                        insertMention(sender, prefix: prefix)
                    }
                },
                onDecideContinue: { pc, allow in
                    Task { await decideContinue(pc, allow: allow) }
                }
            ),
            composerHeight: $composerContentHeight,
            keyboardVisible: keyboardVisible
        )
    }
    #else
    /// macOS composer host. The iOS path mounts the composer in a UIKit
    /// inputAccessoryView (ChatComposerAccessory, iOS-only) so it rides the
    /// keyboard; macOS has no such surface, so the cross-platform
    /// `ComposerView` is rendered directly in a bottom safe-area inset
    /// (see `body`). The iOS accessory also stacks the continue-request /
    /// @-mention banners above the input row — those are NOT yet ported to
    /// the macOS host (tracked as tech-debt), so the bare input row is shown.
    private var macComposer: some View {
        ComposerView(
            input: $input,
            pending: $pendingAttachments,
            photoItems: $photoPickerItems,
            cameraImage: $cameraImage,
            showFileImporter: $showFileImporter,
            showPhotoPicker: $showPhotoPicker,
            showCamera: $showCamera,
            canSend: canSend,
            onSend: { Task { await send() } },
            isStreaming: chatTurnTask != nil,
            onStop: {
                chatTurnTask?.cancel()
                flushRevealImmediately()
            },
            onLookback: (conversation.conversation_type == "user_bot"
                         || conversation.conversation_type == "self")
                ? { Task { await triggerManualLookback() } }
                : nil,
            onGuessModel: shouldOfferGuess ? { showGuessSheet = true } : nil,
            onSwitchModel: { showSwitchSheet = true }
        )
        .background(Theme.Palette.canvas)
    }
    #endif

    private var canSend: Bool {
        return !input.trimmingCharacters(in: .whitespaces).isEmpty
            || pendingAttachments.contains(where: \.isUploaded)
    }

    private var displayedMessages: [ChatMessage] {
        return messages
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

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        // Defer one runloop so LazyVStack has measured any just-appended row;
        // scrolling synchronously inside the same state-change tick lands on a
        // stale offset and the list visibly jumps past the bottom.
        DispatchQueue.main.async {
            guard messageStackCanScroll else { return }
            let land = {
                if let lastId = messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // The first settle on conv-open is instant (no animation) so the
            // view simply appears at the latest message; later arrivals glide.
            if animated {
                withAnimation(.easeOut(duration: 0.22)) { land() }
            } else {
                land()
            }
        }
    }

    private func updateMessageStackContentHeight(_ height: CGFloat) {
        DispatchQueue.main.async {
            if abs(messageStackContentHeight - height) > 0.5 {
                messageStackContentHeight = height
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
                    .font(Theme.Fonts.glyph(size: 11, weight: .bold))
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
                // Sans, not serif — serif design (New York) lacks CJK glyphs, so a
                // Chinese title falls back to PingFang (sans) on iOS but Songti
                // (serif) on macOS. System design keeps it sans on both.
                .font(Theme.Fonts.system(size: 22, weight: .semibold))
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
        conversation.conversation_type == "user_bot" && effectiveBot != nil
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

                // 致电 (voice call) is iOS-only — the Call slice doesn't
                // build on macOS.
                #if os(iOS)
                PreChatActionButton(title: "致电", systemImage: "phone.fill") {
                    Task { await startPreChatCall() }
                }
                #endif

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
            _ = try await api.envelopeTrigger(conversationId: conversation.id)
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
    /// instead of failing silently. iOS-only — the Call slice (startVoiceCall)
    /// doesn't build on macOS.
    #if os(iOS)
    private func startPreChatCall() async {
        guard bot?.voice_call_enabled == true else {
            self.error = "这个机器人还没开启语音通话,可以在「设置」里打开。"
            return
        }
        guard await materializeIfPending() else { return }
        Haptics.tap()
        startVoiceCall()
    }
    #endif

    /// Slim in-conv banner shown when a group voice call is live in this
    /// conversation. Tapping it rejoins the call. From left to right:
    ///   phone-icon · MM:SS elapsed · "N 人"
    /// Driven by ActiveVoiceCallStore which mirrors the conv-channel's
    /// voice_call frames. Call slice is iOS-only.
    #if os(iOS)
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
    #endif

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
                        .font(Theme.Fonts.glyph(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.trailing, 2)
                }
                .buttonStyle(.plain)
            }

            headerAvatar(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    // Sans, not serif — serif design (New York) lacks CJK glyphs, so
                    // a Chinese title falls back to PingFang (sans) on iOS but Songti
                    // (serif) on macOS. System design keeps it sans on both.
                    .font(Theme.Fonts.system(size: 16, weight: .semibold))
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
            // Voice-call entries are iOS-only (the Call slice doesn't build
            // on macOS). On macOS the conversation works fully minus these.
            #if os(iOS)
            if canStartVoiceCall {
                Button {
                    Haptics.tap()
                    startVoiceCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(Theme.Fonts.glyph(size: 17, weight: .regular))
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
                        .font(Theme.Fonts.glyph(size: 17, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("群语音")
            }
            #endif
            if canStartNewBotConv {
                Button {
                    Haptics.tap()
                    Task { await startNewBotConv() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(Theme.Fonts.glyph(size: 17, weight: .regular))
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
                    .font(Theme.Fonts.glyph(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("会话设置")
        }
        .animation(.easeInOut(duration: 0.2), value: pending)
        .padding(.horizontal, Theme.Metrics.conversationGutter)
        // macOS hides the title bar and the detail pane ignores the top safe
        // area (so there's no blank strip) — that left the header glued to the
        // window edge. Add the breathing room back ourselves here; on iOS the
        // safe-area inset already sits above this 6pt.
        #if os(macOS)
        .padding(.top, 20)
        #else
        .padding(.top, 6)
        #endif
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
            last_message_content: nil, last_message_sender_type: nil
        )
        pendingPeer = PendingPeer(kind: "bot", peerId: botId, displayName: displayName)
        messages = []
        input = ""
        pendingAttachments = []
        photoPickerItems = []
        activeLookbacks = []
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
                let newId: UUID = try await SupabaseStack.authedClient()
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
                    last_message_content: nil, last_message_sender_type: nil
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
                    last_message_content: nil, last_message_sender_type: nil
                )
            case "self":
                // Singleton self-chat conv. RPC is find-or-create so
                // re-tapping the friends-tab self row reuses the same
                // conv (and its history) instead of stacking.
                let newId: UUID = try await SupabaseStack.authedClient()
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
                    last_message_content: nil, last_message_sender_type: nil
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
        let attachmentSnapshot = pendingAttachments.filter(\.isUploaded)
        let attachIds = attachmentSnapshot.compactMap(\.uploadedAttachmentId)
        pendingAttachments.removeAll(where: \.isUploaded)
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
                attachmentIdsByMsgId[localId] = attachIds
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

        // group: optimistic — same shape as user_user. Drop the light-green
        // bubble in immediately so the sender sees their own message without
        // waiting on the realtime hub echo, then materialise (if pending) and
        // POST to the worker. The hub echo, keyed on client_message_id,
        // replaces the optimistic row with the canonical one when it lands;
        // if the hub is slow or drops, the optimistic row stays put.
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
            // Re-stamp conv id on the optimistic row so the hub dedup keys
            // on the right conversation when the canonical echo lands.
            restampConversationId(on: localId)
        }
        // Bubble stays "sending" (light green) until the worker returns 200;
        // sendGroupUserMessage flips it to "sent" on success or "failed" on
        // error. The canonical hub echo replaces the row shortly after.
        await sendGroupUserMessage(text, attachmentIds: attachIds,
                                   localId: localId, clientMessageId: cmid)
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

        // group — worker POST path (GroupRouterDO fans out + hub echoes).
        if conversation.conversation_type == "group" {
            Task {
                if conversation.id.isEmpty {
                    guard await materializeIfPending() else {
                        markUserMessageFailed(localId)
                        return
                    }
                    restampConversationId(on: localId)
                }
                await sendGroupUserMessage(text, attachmentIds: attachIds,
                                           localId: localId, clientMessageId: cmid)
            }
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
            try await SupabaseStack.authedClient()
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

    private func sendGroupUserMessage(_ text: String, attachmentIds: [String],
                                      localId: String, clientMessageId: String) async {
        struct Body: Encodable {
            let conversationId: String
            let clientMessageId: String
            let newMessage: String
            let attachmentIds: [String]?
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
                clientMessageId: clientMessageId,
                newMessage: text,
                attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
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
            // 200 — flip the optimistic bubble from "sending" (light green)
            // to "sent" (full green). The Cloudflare realtime hub then
            // delivers the canonical message row (replacing this one) plus
            // any bot replies the GroupRouterDO wakes.
            markUserMessageSent(localId)
        } catch {
            presentSendFailure(error.localizedDescription.contains("insufficient_balance")
                ? "insufficient_balance"
                : "发送失败: \(error.localizedDescription)")
            markUserMessageFailed(localId)
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
    //
    // `regeneratePromptId` re-streams a fresh bot answer to an existing user
    // prompt via POST /v1/messages/:id/regenerate (`:id` = that prompt). No
    // new user message is sent — the worker re-runs the turn off the parent
    // prompt's content. For blind-box bots with regenReroll on, the worker
    // also re-rolls + persists the conversation model and resets reveal, so
    // we refresh `convModelState` once the stream finishes (see below).
    func sendViaSSE(text: String, attachmentIds: [String], autoLookback: Bool = false, userMsgId: String? = nil, clientMessageId: String? = nil, startBotId: String? = nil, regeneratePromptId: String? = nil) {
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
            // (Regenerate has no optimistic row, so `userMsgId` is nil and
            // the filter is a no-op — the parent prompt is already part of
            // the persisted history and the worker reads it server-side.)
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
            // Regenerate: the endpoint takes only { conversationId,
            // recentContext?, clientTz? } and re-runs off the parent prompt
            // server-side. No newMessage / attachments / start fields.
            if regeneratePromptId != nil {
                return [
                    "conversationId": conversation.id,
                    "recentContext": recent,
                    "clientTz": TimeZone.current.identifier,
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
            return b
        }()

        let path: String = {
            if let regeneratePromptId { return "v1/messages/\(regeneratePromptId)/regenerate" }
            return startBotId == nil ? "v1/messages" : "v1/messages/start"
        }()
        chatTurnTask = Task { @MainActor in
            let splitter = BubbleSplitter()
            let stream = ChatStream().send(body: body, path: path)
            // Model Blind Box: the `prompt_model_guess` tool drops a
            // `role='log'`, `log_kind='guess_prompt'` row mid-turn. That row
            // is only dispatched into `guessPromptMsgIds` (→ GuessPromptCard)
            // by `loadHistory`, and the live SSE path never reloads history,
            // so without a nudge the card only appears on a manual reopen.
            // Flag the tool here and run a single post-turn history refresh
            // (below) instead of refreshing on every tool_result.
            var sawGuessPrompt = false
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
                                last_message_sender_type: conversation.last_message_sender_type
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
                                message_seq: prev.message_seq,
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
                    case .bubble(let id, let index, _, _, let messageSeq):
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
                            rekeyBotBubble(at: index - 1, to: id, messageSeq: messageSeq)
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
                        if name == "prompt_model_guess" { sawGuessPrompt = true }
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
                            presentSendFailure(msg.isEmpty ? "发送失败" : msg)
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
                    presentSendFailure(error.localizedDescription.contains("insufficient_balance")
                        ? "insufficient_balance"
                        : "发送失败: \(error.localizedDescription)")
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
            // Mirror this turn's canonical rows into the local cache now —
            // the SSE path only touched the in-memory list, so without this
            // the cache is a turn behind the moment the user leaves (see
            // persistTurnToCache). `turnBubbleIds` is still this turn's set
            // here; it's reset at the start of the next turn, not now.
            persistTurnToCache(userMsgId: userMsgId)
            // Trace bucket stays in tracesByUserMsgId so the user can keep
            // expanding it after the turn completes; only the live binding
            // is cleared here.
            liveTraceUserMsgId = nil
            // Regenerate may have re-rolled + persisted a new conversation
            // model (blind-box regenReroll resets reveal server-side), so
            // refresh the pill — it should flip back to "PendingModel".
            if regeneratePromptId != nil {
                await loadConvModelState()
            }
            // Model Blind Box: a turn that called `prompt_model_guess`
            // inserted a `guess_prompt` log row. Reload history so it gets
            // dispatched into `guessPromptMsgIds` (→ GuessPromptCard) and
            // refresh the pill, instead of waiting for a manual reopen. One
            // refresh at turn end keeps this off the per-event hot path.
            if sawGuessPrompt {
                await loadHistory()
                await loadConvModelState()
            }
        }
    }

    /// Re-stream a fresh bot answer to an existing user prompt. Reuses the
    /// regular SSE consumption path (bubbles append as a new bot group) and
    /// refreshes the model pill on completion — see `sendViaSSE`.
    func regenerate(promptId: String) async {
        guard !conversation.id.isEmpty, !promptId.isEmpty else { return }
        Haptics.tap()
        sendViaSSE(text: "", attachmentIds: [], regeneratePromptId: promptId)
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
    // loadGroupSendersIfNeeded + loadPendingContinueIfNeeded + loadHistory
    // live in ConversationView+Loading.swift.

    // Group-only surfaces — groupSenderFor + mentionPrefix /
    // mentionCandidates / insertMention + decideContinue — live in
    // ConversationView+Group.swift. The composer + its banners
    // (continue-request / @-mention picker) render inside the
    // inputAccessoryView; see ChatComposerAccessory.swift.

    // Recall + delete + URLCache scrubbing live in ConversationView+Recall.swift.

    // ingestPhotos + ingestCameraImage live in ConversationView+Attachments.swift.
}

struct PendingAttachment: Identifiable, Hashable {
    let id: String
    var remoteId: String? = nil
    let mime: String
    let size: Int
    /// Original filename — set for non-image files, nil for images.
    var filename: String? = nil
    var uploadState: UploadState = .uploaded
    /// Local bytes used for immediate thumbnail preview while the upload is
    /// still in flight. Cleared for server-backed attachments.
    var localPreviewData: Data? = nil
    var errorMessage: String? = nil

    enum UploadState: String, Hashable {
        case uploading
        case uploaded
        case failed
    }

    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
    var isUploaded: Bool { uploadState == .uploaded && uploadedAttachmentId != nil }
    var uploadedAttachmentId: String? { remoteId ?? (uploadState == .uploaded ? id : nil) }

    /// Materialise into an `Attachment` for an optimistic bubble. The
    /// worker-served path is `/v1/uploads/<id>` (the auth-gated route);
    /// `kind` is left to the renderer, which classifies by `mime`.
    func asAttachment() -> Attachment {
        let attachmentId = uploadedAttachmentId ?? id
        return Attachment(
            id: attachmentId, kind: isImage ? "image" : "file", mime: mime,
            size: size, width: nil, height: nil,
            url: "/v1/uploads/\(attachmentId)", filename: filename
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
#if os(iOS)
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
#else
/// macOS twin — the UIKit gesture conflict that makes SwiftUI text
/// selection unreliable on iOS doesn't apply on macOS, so a plain
/// selectable `Text` in a `ScrollView` gives native selection + the
/// system Copy / Look Up menu without an NSViewRepresentable.
private struct SelectableTextUIView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: Theme.Fonts.scaled(16)))
                .foregroundStyle(Theme.Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        }
    }
}
#endif

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
                .inlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .tint(Theme.Palette.accent)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            Clipboard.copy(text)
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

// NOTE: `AttachmentRef` moved to the shared `MessagesFetch`
// (Networking/MessagesFetch.swift) with the rest of the message row types.

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
            .font(Theme.Fonts.caption2)
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
                        .font(Theme.Fonts.glyph(size: 22, weight: .light))
                        .opacity(busy ? 0 : 1)
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 28)
                Text(title)
                    .font(Theme.Fonts.rounded(size: 12, weight: .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.ink)
            .frame(width: 92, height: 92)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1.5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 盲盒 model state

extension ConversationView {
    /// Fetch the conversation's drawn-model state so the header pill can show
    /// "PendingModel" (surprise, not revealed) or the friendly name (revealed /
    /// disclose). Non-fatal: on any failure the pill falls back to the bot's
    /// pinned model name. Skips user_user convs (no bot model there).
    func loadConvModelState() async {
        guard conversation.conversation_type != "user_user" else { return }
        guard !conversation.id.isEmpty else { return }
        guard let api else { return }
        do {
            let s: ConvModelState = try await api.get("v1/conversations/\(conversation.id)/model")
            await MainActor.run { self.convModelState = s }
        } catch {
            // non-fatal: pill falls back to bot model name
        }
    }
}
