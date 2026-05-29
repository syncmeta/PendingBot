import SwiftUI
import Supabase
import OSLog
import PhotosUI
import CoreImage

private let log = Logger.category("conv-list")

/// Navigation target for the message tab. `.existing` is a row already in
/// the conversations list (DB-backed); `.pending` is a freshly opened
/// chat that hasn't been materialised yet — ConversationView creates the
/// `conversations` row on first send. Keeping both behind one Hashable
/// type lets a single NavigationStack path carry either.
enum ChatDest: Hashable {
    case existing(Conversation)
    case pending(PendingPeer)
    case composeGroup
}

/// 消息 tab — primary chat.
///
/// Two layouts driven by horizontal size class:
///   • compact (iPhone): NavigationStack push from list into ConversationView
///   • regular (iPad landscape, Mac Catalyst): NavigationSplitView with the
///     conversations list as a sidebar and ConversationView always visible
///     on the right — picking another row swaps the detail in place, like
///     ChatGPT / Claude / WeChat / QQ desktop.
///
/// The two paths share the same `sidebarBody` view so styling stays in lock
/// step; only the row tap target differs (NavigationLink push vs setting
/// `selected`).
struct MessageTabView: View {
    @Environment(\.api) private var api
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var unread: UnreadStore
    /// Store fed by CallKitManager when the user accepts an incoming
    /// voice call. The .onChange below drives the navigation step;
    /// ConversationView reads `pendingAutoJoinConversationId` on appear
    /// to auto-open GroupCallView (no second tap to enter the call).
    @State private var incomingCall = IncomingCallStore.shared
    @State private var conversations: [Conversation] = []
    @State private var bots: [Bot] = []
    /// Peer profile keyed by user_user conv id. Populated alongside the
    /// conversations fetch — joins the embedded `participants` rows back
    /// against `/v1/contacts` so each user_user row can render the other
    /// person's avatar + name (alias > display_name) without each row
    /// hitting the worker on its own.
    @State private var userPeers: [String: UserUserPeer] = [:]
    @State private var loading = false
    @State private var pullRefreshing = false
    @State private var error: String?
    @State private var joiningGroup = false
    @State private var addingFriend = false
    @State private var scanning = false
    /// Two-way 加好友 chooser (扫码 / 输号码). Shown when the user taps
    /// 加好友 from the "+" menu; picking either option dismisses the
    /// chooser and opens the corresponding next sheet.
    @State private var addFriendChooser = false
    /// Handle pre-filled into AddFriendSheet from the scan flow — non-
    /// empty means the sheet should auto-run the lookup on appear so the
    /// user lands on the preview page without re-typing.
    @State private var addFriendPrefill: String = ""
    /// Bot-add sheet driven by a scanned bot-share QR. `addBotPrefill`
    /// carries the slug so AddBotSheet opens straight on the preview.
    @State private var addingBot = false
    @State private var addBotPrefill: String = ""
    @State private var pendingScannedFriendHandle: String?
    @State private var pendingScannedBotSlug: String?
    // Path-based nav for compact: keyed to .toolbar(.hidden, for: .tabBar)
    // so the bottom tab bar slides out alongside the push transition (rather
    // than snapping back in *after* the back transition finishes, which is
    // what we'd get if the modifier lived on the destination view).
    @State private var path: [ChatDest] = []
    // Selection-driven detail for regular size class.
    @State private var selected: ChatDest?

    var body: some View {
        Group {
            if sidebarLayout {
                regularBody
            } else {
                compactBody
            }
        }
        .task {
            await load()
            // Pull the active-voice-calls snapshot so the row-level phone
            // icon paints right away. The store also self-updates from
            // conv-channel voice_call frames whenever the user opens a
            // conversation that's live.
            await ActiveVoiceCallStore.shared.refresh()
            // Subscribe to user-level Realtime — every unread-counts row
            // change (new bot/cron message anywhere) triggers a reload so
            // last_activity_at + preview + ordering refresh without a pull.
            // Cheap enough for a single-user list; add debounce when conv
            // counts grow past O(100).
            if let userId = AccountStore.shared.current?.id {
                await RealtimeManager.shared.startUserChannel(userId: userId) { _ in
                    Task { @MainActor in await self.load() }
                }
            }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                Task { await ActiveVoiceCallStore.shared.refresh() }
            }
        }
        // React to a CallKit-accepted incoming call — navigate to the
        // conversation so ConversationView mounts and its onAppear
        // consumes `pendingAutoJoinConversationId` to open the call view
        // directly. Two separate slots: this one is the navigation
        // trigger, the auto-join slot is read by ConversationView.
        .onChange(of: incomingCall.pendingNavConversationId) { _, convId in
            guard let convId, !convId.isEmpty else { return }
            incomingCall.pendingNavConversationId = nil
            let userId = AccountStore.shared.current?.id ?? ""
            let stub = Conversation(
                id: convId, bot_id: "", user_id: userId,
                title: nil, feature_type: "message",
                conversation_type: "group",
                last_activity_at: Int(Date().timeIntervalSince1970),
                round_count: 0, bot_name: nil,
                last_message_content: nil, last_message_sender_type: nil
            )
            if sidebarLayout {
                selected = .existing(stub)
            } else {
                path.append(.existing(stub))
            }
        }
        .alert("出错了", isPresented: .constant(error != nil), actions: {
            Button("好") { error = nil }
        }, message: { Text(error ?? "") })
        .sheet(isPresented: $joiningGroup) {
            GroupJoinView { convId in
                // After successful join, refresh the conv list and
                // navigate into the new group conv.
                Task { await load() }
                // Build a Conversation stub so the existing nav path
                // works without waiting on Realtime to deliver the row.
                let userId = AccountStore.shared.current?.id ?? ""
                let stub = Conversation(
                    id: convId, bot_id: "", user_id: userId,
                    title: nil, feature_type: "message",
                    conversation_type: "group",
                    last_activity_at: Int(Date().timeIntervalSince1970),
                    round_count: 0, bot_name: nil,
                    last_message_content: nil, last_message_sender_type: nil
                )
                if sidebarLayout {
                    selected = .existing(stub)
                } else {
                    path.append(.existing(stub))
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $addingFriend, onDismiss: { addFriendPrefill = "" }) {
            AddFriendSheet(
                onAdded: { Task { await load() } },
                prefilledHandle: addFriendPrefill
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $scanning, onDismiss: {
            if let token = pendingScannedFriendHandle {
                pendingScannedFriendHandle = nil
                addFriendPrefill = token
                addingFriend = true
            } else if let slug = pendingScannedBotSlug {
                pendingScannedBotSlug = nil
                addBotPrefill = slug
                addingBot = true
            }
        }) {
            ScanQRSheet(
                onAdded: { Task { await load() } },
                onScannedUserHandle: { token in
                    // Scanned a known user handle — flip to the add-friend
                    // preview page with the token pre-loaded, matching the
                    // 输号码 → 查找 review screen.
                    pendingScannedFriendHandle = token
                    scanning = false
                },
                onScannedBotSlug: { slug in
                    // Scanned a bot-share QR — open the add-bot preview
                    // with the slug pre-loaded.
                    pendingScannedBotSlug = slug
                    scanning = false
                }
            )
        }
        .sheet(isPresented: $addingBot, onDismiss: { addBotPrefill = "" }) {
            AddBotSheet(
                onAdded: { _ in Task { await load() } },
                prefilledSlug: addBotPrefill
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $addFriendChooser) {
            AddFriendChooserSheet(
                onPickScan: {
                    addFriendChooser = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        scanning = true
                    }
                },
                onPickHandle: {
                    addFriendChooser = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        addingFriend = true
                    }
                }
            )
            .presentationDetents([.fraction(0.32)])
            .presentationDragIndicator(.visible)
        }
    }

    // ── Compact (iPhone) ────────────────────────────────────────────────────

    private var compactBody: some View {
        NavigationStack(path: $path) {
            sidebarBody
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ChatDest.self) { dest in
                    destinationView(for: dest)
                }
        }
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
    }

    // ── Regular (iPad landscape, Mac Catalyst) ──────────────────────────────

    private var regularBody: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarBody
                if let topTabSelection {
                    SidebarTabBar(selection: topTabSelection)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sidebarColumnWidth()
        } detail: {
            if let dest = selected {
                destinationView(for: dest)
                    // .id forces a fresh ConversationView (and a fresh WS)
                    // when the user picks a different row — without it the
                    // existing view would just rebind, leaking the prior
                    // chat's state. For pending bot convs key on the bot
                    // id so re-tapping the same bot reuses the pending view.
                    .id(destinationKey(dest))
            } else {
                EmptyDetailHint(text: "选一条对话开始", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    @ViewBuilder
    private func destinationView(for dest: ChatDest) -> some View {
        switch dest {
        case .existing(let conv):
            // user_user 行点进去时,把列表里已经解析过的 peer (alias /
            // displayName / avatarPath / avatarSeed) 直接喂给
            // ConversationView 当 pendingPeer,这样头像 + 标题第一帧就对,
            // 不用等 loadPeerProfileIfNeeded() 那次 round-trip。
            let pending: PendingPeer? = {
                guard conv.conversation_type == "user_user",
                      let p = userPeers[conv.id] else { return nil }
                return PendingPeer(kind: "user", peerId: p.userId,
                                   displayName: p.rowName,
                                   avatarPath: p.avatarPath,
                                   avatarSeed: p.avatarSeed)
            }()
            ConversationView(conversation: conv, bot: bot(for: conv), pendingPeer: pending) {
                reload()
            }
            .onAppear { unread.markRead(conv.id, throughLastMessageId: conv.last_message_id) }
        case .pending(let peer):
            ConversationView(
                conversation: pendingConversation(for: peer),
                bot: bots.first { $0.id == peer.peerId },
                pendingPeer: peer
            ) {
                reload()
            }
        case .composeGroup:
            CreateGroupView(
                recentOrder: recentParticipantOrder,
                onCreated: { convId, title in groupCreated(convId: convId, title: title) }
            )
        }
    }

    private func destinationKey(_ dest: ChatDest) -> String {
        switch dest {
        case .existing(let c): return "conv:\(c.id)"
        case .pending(let p):  return "pending:\(p.kind):\(p.peerId)"
        case .composeGroup:    return "composeGroup"
        }
    }

    private func pendingConversation(for peer: PendingPeer) -> Conversation {
        let userId = AccountStore.shared.current?.id ?? ""
        return Conversation(
            id: "",
            bot_id: peer.kind == "bot" ? peer.peerId : "",
            user_id: userId,
            title: peer.displayName,
            feature_type: "message",
            conversation_type: peer.kind == "bot" ? "user_bot" : "user_user",
            last_activity_at: Int(Date().timeIntervalSince1970),
            round_count: 0,
            bot_name: peer.kind == "bot" ? peer.displayName : nil,
            last_message_content: nil,
            last_message_sender_type: nil
        )
    }

    // ── Sidebar (shared) ────────────────────────────────────────────────────

    private var sidebarBody: some View {
        VStack(spacing: 0) {
            TabHeaderBar(
                title: "消息",
                trailing: {
                    GroupedHeaderControls {
                        Menu {
                            if !recentBots.isEmpty {
                                Section("最近聊过") {
                                    ForEach(recentBots) { bot in
                                        Button {
                                            Haptics.tap()
                                            Task { await createAndNavigate(with: bot) }
                                        } label: {
                                            Label(bot.display_name, systemImage: "bubble.left")
                                        }
                                    }
                                }
                            }
                            Section("右滑新建会话\n左滑标未读/删除") {
                            }
                        } label: {
                            CircleComposeButton()
                        }
                    } trailing: {
                        PlusActionPopover(items: [
                            PlusActionItem(title: "加好友", systemImage: "person.badge.plus") {
                                addFriendChooser = true
                            },
                            PlusActionItem(title: "扫码", systemImage: "qrcode.viewfinder") {
                                scanning = true
                            },
                            PlusActionItem(title: "拉群", systemImage: "person.3") {
                                openCreateGroup()
                            },
                            PlusActionItem(title: "加群", systemImage: "person.3.sequence") {
                                joiningGroup = true
                            },
                        ])
                    }
                }
            )
            Group {
                if loading && conversations.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversations.isEmpty {
                    EmptyHint(text: "和 AI 聊天")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if pullRefreshing {
                                pullRefreshIndicator
                            }
                            ForEach(conversations) { conv in
                                SwipeRevealRow(
                                    actions: [
                                        SwipeRevealAction(
                                            systemImage: "envelope.badge",
                                            tint: Color(red: 0.20, green: 0.40, blue: 0.78)
                                        ) {
                                            // Direct to the singleton —
                                            // @EnvironmentObject access from
                                            // a stored escaping closure can
                                            // resolve to a placeholder when
                                            // the closure outlives the view
                                            // body, which silently swallows
                                            // the insert and leaves the row
                                            // never flipping to isUnread.
                                            UnreadStore.shared.markUnread(conv.id)
                                        },
                                        SwipeRevealAction(
                                            systemImage: "trash",
                                            tint: Color(red: 0.78, green: 0.22, blue: 0.26)
                                        ) {
                                            Task { await delete(conv) }
                                        },
                                    ],
                                    leadingTrigger: leadingTrigger(for: conv),
                                    onTap: { openConversation(conv) }
                                ) {
                                    rowVisual(conv)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Metrics.gutter)
                        .padding(.vertical, 12)
                        // Cap on compact only; on regular the sidebar already
                        // has a fixed-width column so the cap would just push
                        // rows further from the trailing edge.
                        .readableColumnWidth(sidebarLayout ? .infinity : Theme.Metrics.readableColumn)
                    }
                    .refreshable { await refreshFromPull() }
                }
            }
        }
    }

    private var pullRefreshIndicator: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(Theme.Palette.accent)
                .accessibilityLabel("刷新中")
            Spacer()
        }
        .frame(height: 28)
    }

    /// Right-swipe-to-create-new — only available on bot conversations
    /// where we know the bot the user wanted to chat with again. Group
    /// and human chats fall through (no useful "default" target).
    private func leadingTrigger(for conv: Conversation) -> SwipeLeadingTrigger? {
        guard conv.conversation_type == "user_bot",
              let bot = bot(for: conv) else { return nil }
        return SwipeLeadingTrigger(
            systemImage: "plus",
            label: "继续聊",
            armedLabel: "松手新建",
            tint: Theme.Palette.accent
        ) {
            Task { await createAndNavigate(with: bot) }
        }
    }

    /// Last-N unique bots from the conversations list, newest first.
    /// Drives the leading "+" menu in the header so the user can quickly
    /// start a fresh chat with someone they were just talking to.
    private var recentBots: [Bot] {
        var seen = Set<String>()
        var result: [Bot] = []
        for conv in conversations {
            guard conv.conversation_type == "user_bot",
                  !conv.bot_id.isEmpty,
                  !seen.contains(conv.bot_id) else { continue }
            if let b = bot(for: conv) {
                seen.insert(conv.bot_id)
                result.append(b)
                if result.count >= 5 { break }
            }
        }
        return result
    }

    @ViewBuilder
    /// Purely-visual conversation row. Navigation is driven by
    /// SwipeRevealRow's `onTap` (see openConversation) — never embed a
    /// NavigationLink/Button here, or a sideways swipe will trigger it.
    private func rowVisual(_ conv: Conversation) -> some View {
        let isSelected: Bool = {
            guard sidebarLayout, case .existing(let s) = selected else { return false }
            return s.id == conv.id
        }()
        return ConversationListRow(
            conv: conv,
            bot: bot(for: conv),
            userPeer: userPeers[conv.id],
            isSelected: isSelected
        )
    }

    private func openConversation(_ conv: Conversation) {
        Haptics.tap()
        if sidebarLayout {
            selected = .existing(conv)
        } else {
            path.append(.existing(conv))
        }
    }

    private func openCreateGroup() {
        Haptics.tap()
        if sidebarLayout {
            selected = .composeGroup
        } else {
            path.append(.composeGroup)
        }
    }

    /// Build a [participantId: rank] map so the create-group picker can
    /// sort members by recent chat activity. The conversations list is
    /// already sorted by `last_activity_at` desc, so the first appearance
    /// of each participant id is its most-recent activity rank.
    private var recentParticipantOrder: [String: Int] {
        var order: [String: Int] = [:]
        let myId = AccountStore.shared.current?.id ?? ""
        for conv in conversations {
            switch conv.conversation_type {
            case "user_bot":
                let id = conv.bot_id
                if !id.isEmpty, order[id] == nil { order[id] = order.count }
            case "user_user":
                if let peer = userPeers[conv.id], peer.userId != myId,
                   order[peer.userId] == nil {
                    order[peer.userId] = order.count
                }
            default:
                break
            }
        }
        return order
    }

    /// Land the newly-created group's conversation in place of the
    /// compose page so the back button returns to the conv list rather
    /// than to the empty compose UI.
    private func groupCreated(convId: String, title: String) {
        let userId = AccountStore.shared.current?.id ?? ""
        let stub = Conversation(
            id: convId, bot_id: "", user_id: userId,
            title: title.isEmpty ? nil : title, feature_type: "message",
            conversation_type: "group",
            last_activity_at: Int(Date().timeIntervalSince1970),
            round_count: 0, bot_name: nil,
            last_message_content: nil, last_message_sender_type: nil
        )
        Task { await load() }
        if sidebarLayout {
            selected = .existing(stub)
        } else {
            if !path.isEmpty, case .composeGroup = path.last {
                path[path.count - 1] = .existing(stub)
            } else {
                path.append(.existing(stub))
            }
        }
    }

    private func bot(for conv: Conversation) -> Bot? {
        bots.first { $0.id == conv.bot_id }
    }

    private func reload() { Task { await load() } }

    @MainActor
    private func refreshFromPull() async {
        guard !pullRefreshing else { return }
        pullRefreshing = true
        let started = DispatchTime.now().uptimeNanoseconds
        defer { pullRefreshing = false }

        await load()

        // SwiftUI keeps the native refresh control visible only while this
        // async action is suspended. Fast no-op refreshes otherwise snap back
        // before the user sees any spinner, which makes a real reload feel
        // like a decorative pull gesture.
        let minimumVisibleNanos: UInt64 = 650_000_000
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        if elapsed < minimumVisibleNanos {
            try? await Task.sleep(nanoseconds: minimumVisibleNanos - elapsed)
        }
    }

    private func load() async {
        // Hydrate from local cache instantly — UI shows last-known state
        // before we await the network. The Supabase fetch below replaces it.
        // Cache hydrate is a first-paint fallback only — its rows lack
        // last_message_content, so re-hydrating during a pull-to-refresh
        // would visibly wipe the preview text back to "还没有消息" while
        // the network call is in flight (and leave it that way if the
        // network response is delayed / cancelled).
        let cached = LocalDatabase.shared.loadConversations()
        if conversations.isEmpty && !cached.isEmpty {
            self.conversations = cached.map { row in
                Conversation(
                    id: row.id,
                    bot_id: row.bot_id ?? "",
                    user_id: row.user_id ?? "",
                    title: row.title,
                    feature_type: row.feature,
                    conversation_type: row.conversation_type,
                    last_activity_at: row.last_activity_at,
                    round_count: row.round_count,
                    bot_name: row.bot_name,
                    last_message_content: row.last_message_content,
                    last_message_sender_type: row.last_message_sender_type
                )
            }
            .sorted { l, r in
                if l.last_activity_at != r.last_activity_at {
                    return l.last_activity_at > r.last_activity_at
                }
                return l.id < r.id
            }
        }
        loading = true; defer { loading = false }
        do {
            async let botRows: [BotRow] = SupabaseStack.shared
                .from("bots")
                .select("id, display_name, model_id, visibility, creator_id, voice_call_enabled")
                .eq("is_active", value: true)
                .execute()
                .value
            // user_unread_counts has a row per (user, conv) only after the
            // conv received its first non-recap message — the unread
            // trigger skips role='log' / status='replaced' / voice-call
            // recap rows, so a conv that has only ever held a voice-call
            // recap has no row here. !inner makes the embed an INNER
            // JOIN so those convs drop out of the list entirely instead
            // of showing as empty rows (the conv list query is the
            // empty-conv filter; previously LEFT-joined and let blanks
            // through).
            // `participants` is embedded so user_user rows know the peer's
            // user id without a second trip — RLS lets us see both rows of
            // a conv we participate in.
            async let convRows: [ConvRow] = SupabaseStack.shared
                .from("conversations")
                .select("""
                    id, bot_id, user_id, title, conversation_type, feature, round_count, updated_at,
                    bot:bots!conversations_bot_id_fkey(display_name, model_id, visibility, creator_id),
                    unread:user_unread_counts!inner(last_message_id, last_message_at, last_message_preview, unread_count),
                    participants:conversation_participants(participant_type, participant_id)
                """)
                // Subagent child conversations are opened from the parent
                // tool trace only; they should never appear as top-level
                // message-list rows even though the user is a participant.
                .neq("conversation_type", value: "subagent")
                .order("updated_at", ascending: false)
                // Tie-break: ascending id so the order is deterministic when
                // multiple convs share an updated_at timestamp (e.g. all
                // bootstrapped at the same instant for a fresh user).
                .order("id", ascending: true)
                .execute()
                .value
            // Friends list — cheap (single worker round-trip, even cheaper
            // when the cache is warm), and we need it to render avatars +
            // names on user_user rows. Empty list on auth/network failure
            // is fine; rows fall back to the id-prefix.
            let contactsTask = Task { (try? await ContactsAPI.fetchContacts()) ?? [] }

            self.bots = try await botRows.map(\.asBot)
            // Sort client-side too — the local cache hydrate above and any
            // future Realtime patch can interleave; keep the visible order
            // (newest first, then ascending id on ties) consistent.
            let convFetched = try await convRows
            let fresh = convFetched.map(\.asConversation).sorted { l, r in
                if l.last_activity_at != r.last_activity_at {
                    return l.last_activity_at > r.last_activity_at
                }
                return l.id < r.id
            }
            // Only reassign when the row set actually changed. The list has
            // no realtime, so every appear refetches — reassigning an
            // identical array still forces a full SwiftUI re-render, which
            // is the visible "刷新一次" flash on returning to the tab.
            if self.conversations != fresh {
                self.conversations = fresh
            }

            // Push server-truth unread counts into the shared store so the
            // per-row badge, the tab dot, and the app icon badge all read
            // from one place. Preset conversations are pre-zeroed at seed
            // time (migration 20260520020753), so we just trust the server
            // count here — no epoch-year guard needed.
            var counts: [String: Int] = [:]
            var lastMessageIds: [String: String] = [:]
            for row in convFetched {
                counts[row.id] = row.unread?.first?.unread_count ?? 0
                if let lastMessageId = row.unread?.first?.last_message_id {
                    lastMessageIds[row.id] = lastMessageId
                }
            }
            unread.setServerCounts(counts, lastMessageIds: lastMessageIds)

            // Build the user_user peer map. Only convs of that type carry
            // a meaningful peer; bot/group/self rows skip the lookup.
            let myId = AccountStore.shared.current?.id ?? ""
            let contactsById: [String: FriendsTabView.HumanPick] =
                Dictionary(uniqueKeysWithValues: (await contactsTask.value).map { ($0.id, $0) })
            var peers: [String: UserUserPeer] = [:]
            for row in convFetched where row.conversation_type == "user_user" {
                let otherId = row.participants?.first {
                    $0.participant_type == "user" && $0.participant_id != myId
                }?.participant_id
                guard let otherId else { continue }
                let pick = contactsById[otherId]
                peers[row.id] = UserUserPeer(
                    userId: otherId,
                    alias: pick?.alias,
                    displayName: pick?.displayName ?? "",
                    avatarPath: pick?.avatarPath,
                    avatarSeed: pick?.avatarSeed ?? otherId
                )
            }
            self.userPeers = peers
            // Capture the cached last_activity_at *before* overwriting the
            // conversations cache below, so the staleness diff compares
            // against last-known state, not the value we're about to write.
            let prevActivity = Dictionary(
                cached.map { ($0.id, $0.last_activity_at) },
                uniquingKeysWith: { first, _ in first }
            )
            LocalDatabase.shared.upsertConversations(fresh.map { c in
                LocalDatabase.ConversationRow(
                    id: c.id,
                    bot_id: c.bot_id.isEmpty ? nil : c.bot_id,
                    user_id: c.user_id.isEmpty ? nil : c.user_id,
                    title: c.title,
                    conversation_type: c.conversation_type,
                    feature: c.feature_type,
                    round_count: c.round_count,
                    last_activity_at: c.last_activity_at,
                    bot_name: c.bot_name,
                    last_message_content: c.last_message_content,
                    last_message_sender_type: c.last_message_sender_type
                )
            })

            // A message that arrived while the user was NOT inside the conv
            // was never persisted locally — the conv-level Realtime socket is
            // lazy (open only while ConversationView is on screen) and push
            // payloads carry no body. So opening the conv would show the stale
            // message cache until loadHistory's network round-trip lands.
            // Here, for conversations whose last_activity_at advanced past the
            // cached value (or that weren't cached at all), refresh the local
            // message cache so the conv opens with the new message already in
            // place. Capped + backgrounded so it never delays the list paint.
            let staleConvIds = fresh
                .filter { conv in
                    guard let prev = prevActivity[conv.id] else { return true }
                    return conv.last_activity_at > prev
                }
                .prefix(8)
                .map(\.id)
            if !staleConvIds.isEmpty {
                Task { await self.prefetchRecentMessages(convIds: Array(staleConvIds)) }
            }
        } catch is CancellationError {
            // navigation / refreshable cancellation — silent
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled {
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    /// Refresh the local message cache for `convIds` so a conv the user
    /// opens shows messages received while they were elsewhere on the very
    /// first paint, instead of after loadHistory's network round-trip.
    ///
    /// One fetch per conv: the conv-list query only carries a truncated
    /// `last_message_preview` string (no message id), which isn't enough to
    /// persist as a real `messages` row. Fetches run concurrently and the
    /// caller already bounds `convIds`, so worst case is a handful of small
    /// reads. Failures are swallowed — this is a cache warm, not load-bearing.
    private func prefetchRecentMessages(convIds: [String]) async {
        struct MsgRow: Decodable {
            let id: String
            let client_message_id: String?
            let conversation_id: String
            let user_id: String?
            let sender_bot_id: String?
            let role: String
            let content: String?
            let status: String?
            let created_at: String
            let message_seq: Int?
        }
        await withTaskGroup(of: [LocalDatabase.MessageRow].self) { group in
            for convId in convIds {
                group.addTask {
                    do {
                        let rows: [MsgRow] = try await SupabaseStack.shared
                            .from("messages")
                            .select("id, client_message_id, conversation_id, user_id, sender_bot_id, role, content, status, created_at, message_seq")
                            .eq("conversation_id", value: convId)
                            .order("message_seq", ascending: false)
                            .order("created_at", ascending: false)
                            .limit(30)
                            .execute()
                            .value
                        return rows.compactMap { r in
                            // Mirror loadHistory's cache policy: only real
                            // bot/user bubbles belong in the cache. role='log'
                            // rows (recall tombstones, review steps) and
                            // soft-deleted rows are skipped — the conv-open
                            // hydrate maps any non-'bot' role to a user
                            // bubble, so a stray log row would mis-render.
                            guard r.role != "log", r.status != "deleted" else { return nil }
                            return LocalDatabase.MessageRow(
                                id: r.id,
                                client_message_id: r.client_message_id,
                                conversation_id: r.conversation_id,
                                user_id: r.user_id,
                                sender_bot_id: r.sender_bot_id,
                                role: r.role,
                                content: r.content,
                                status: r.status,
                                created_at: ServerTimestamp.epochSeconds(r.created_at, default: 0),
                                message_seq: r.message_seq
                            )
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await rows in group where !rows.isEmpty {
                LocalDatabase.shared.upsertMessages(rows)
            }
        }
    }

    // PostgREST decode shapes. Translated to view models (Bot / Conversation)
    // immediately so the rest of the view doesn't need to know the wire form.
    private struct BotRow: Decodable {
        let id: String
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
        let voice_call_enabled: Bool?
        var asBot: Bot {
            Bot(
                id: id, display_name: display_name,
                access_mode: nil, model: model_id,
                visibility: visibility, creator_id: creator_id,
                voice_call_enabled: voice_call_enabled
            )
        }
    }
    private struct ConvRow: Decodable {
        static func parseTimestamp(_ s: String) -> Int? {
            if let secs = ServerTimestamp.parse(s).map({ Int($0.timeIntervalSince1970) }) {
                return secs
            }
            log.warning("timestamp parse failed: \(s, privacy: .public)")
            return nil
        }

        let id: String
        let bot_id: String?
        let user_id: String?
        let title: String?
        let conversation_type: String?
        let feature: String?
        let round_count: Int?
        let updated_at: String? // ISO 8601
        let bot: BotJoin?
        // PostgREST returns the embedded user_unread_counts as an array
        // (the FK has no unique constraint on conversation_id alone — one
        // row per (user, conv)). With !inner + RLS, callers see at most one.
        let unread: [UnreadJoin]?
        let participants: [ParticipantJoin]?
        struct BotJoin: Decodable {
            let display_name: String?
            let model_id: String?
            let visibility: String?
            let creator_id: String?
        }
        struct UnreadJoin: Decodable {
            let last_message_id: String?
            let last_message_at: String?
            let last_message_preview: String?
            let unread_count: Int?
        }
        struct ParticipantJoin: Decodable {
            let participant_type: String
            let participant_id: String
        }
        var asConversation: Conversation {
            let unreadRow = unread?.first
            let secs: Int = {
                if let s = unreadRow?.last_message_at,
                   let ts = ConvRow.parseTimestamp(s) {
                    return ts
                }
                if let updated_at, let ts = ConvRow.parseTimestamp(updated_at) {
                    return ts
                }
                return 0
            }()
            return Conversation(
                id: id,
                bot_id: bot_id ?? "",
                user_id: user_id ?? "",
                title: title,
                feature_type: feature,
                conversation_type: conversation_type,
                last_activity_at: secs,
                round_count: round_count,
                bot_name: bot?.display_name,
                last_message_content: unreadRow?.last_message_preview,
                last_message_sender_type: nil,
                last_message_id: unreadRow?.last_message_id
            )
        }
    }

    /// Open a fresh chat with `bot` lazily — no DB row is inserted here.
    /// ConversationView materialises the conv on first send, so the user
    /// can hit "+" → bot, change their mind, back out, and leave no empty
    /// row littering the list. Mirrors FriendsTabView's tap-to-chat path.
    private func createAndNavigate(with bot: Bot) async {
        let peer = PendingPeer(kind: "bot",
                               peerId: bot.id,
                               displayName: bot.display_name)
        if sidebarLayout {
            selected = .pending(peer)
        } else {
            path.append(.pending(peer))
        }
        Haptics.tap()
    }

    private func delete(_ conv: Conversation) async {
        do {
            try await SupabaseStack.shared
                .from("conversations")
                .delete()
                .eq("id", value: conv.id)
                .execute()
            conversations.removeAll { $0.id == conv.id }
            LocalDatabase.shared.deleteConversation(id: conv.id)
            unread.markRead(conv.id)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

/// Resolved peer for a user_user conv shown in the list. Built once during
/// `load()` from the participants embed + the friends list so each row can
/// render the other person's name + avatar without per-row worker calls.
struct UserUserPeer: Hashable {
    let userId: String
    let alias: String?
    let displayName: String
    let avatarPath: String?
    /// Server-supplied placeholder-emoji seed (mirrored from the friends
    /// list HumanPick.avatarSeed) so the conv row renders the same emoji
    /// every viewer of this peer sees.
    let avatarSeed: String

    /// Title shown on the row + carried into ConversationView's pendingPeer
    /// so opening the chat doesn't re-flicker the header label.
    var rowName: String {
        if let a = alias, !a.isEmpty { return a }
        if !displayName.isEmpty { return displayName }
        return String(userId.prefix(8))
    }
}

private struct ConversationListRow: View {
    let conv: Conversation
    let bot: Bot?
    /// Resolved peer for user_user rows; nil for bot / group / self.
    let userPeer: UserUserPeer?
    /// True only in the regular-size sidebar layout when this row's
    /// conversation is the one currently shown in the detail pane.
    /// Drives a tinted background so the user can see what's selected
    /// (compact mode pushes a new screen, so it never needs this).
    var isSelected: Bool = false

    /// Subscribe directly to the unread store rather than receiving
    /// `unreadCount` / `isUnread` as drilled props — prop-drilling
    /// from MessageTabView's @EnvironmentObject worked for the numeric
    /// badge (count fetched alongside the conv list) but the manual
    /// "标未读" dot was flaky: the Set<String> mutation fires
    /// objectWillChange on the store, but SwiftUI's diff on the
    /// ConversationListRow struct sometimes skipped the body re-run
    /// because the other props (Conversation / Bot) hadn't changed.
    /// Observing the store here makes the dot pop reliably.
    @EnvironmentObject private var unreadStore: UnreadStore
    private var unreadCount: Int { unreadStore.unreadCount(conv.id) }
    private var isUnread: Bool { unreadStore.isUnread(conv.id) }

    // Right-side name pill. For user_user it carries the peer's nickname
    // (the user's own profile name, not the local alias — the title above
    // already shows the alias). For bots it carries the bot's name. Falls
    // back to bot_name / title / "—" so we never show a raw uuid.
    private var primaryName: String {
        if isHumanConv {
            if let p = userPeer, !p.displayName.isEmpty { return p.displayName }
            if let p = userPeer { return p.rowName }
        }
        if let n = bot?.display_name, !n.isEmpty { return n }
        if let n = conv.bot_name, !n.isEmpty { return n }
        if let t = conv.title, !t.isEmpty { return t }
        return "—"
    }
    private var isHumanConv: Bool { conv.conversation_type == "user_user" }

    /// What the row title reads as. user_user prefers the local alias
    /// (备注) → peer nickname → id-prefix; everything else keeps the
    /// existing `conv.title` path with the "新对话" placeholder.
    private var rowTitle: String {
        if isHumanConv, let p = userPeer { return p.rowName }
        return conv.title?.isEmpty == false ? conv.title! : "新对话"
    }
    private var rowTitleIsPlaceholder: Bool {
        if isHumanConv, userPeer != nil { return false }
        return !(conv.title?.isEmpty == false)
    }

    /// Pill colors for the name tag carry the bot type now that the
    /// dedicated 公/私 tag is gone: green = human, plum = private bot,
    /// amber = public bot.
    private var nameTagColors: (fg: Color, bg: Color) {
        if isHumanConv { return (Theme.Palette.accent, Theme.Palette.accentBg) }
        if bot?.visibility == "private" { return (Theme.Palette.plum, Theme.Palette.plumBg) }
        return (Theme.Palette.amber, Theme.Palette.amberBg)
    }

    private var isGroupConv: Bool { conv.conversation_type == "group" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // user_user → peer's photo / generated; group → cluster
            // GroupAvatar; bot/self → per-bot BotAvatar with per-conv tint.
            if isHumanConv, let p = userPeer {
                UserAvatar(seed: p.avatarSeed, attachmentId: p.avatarPath, size: 36)
            } else if isGroupConv {
                GroupAvatar(seed: conv.id, size: 36)
            } else {
                BotAvatar(
                    emojiSeed: conv.bot_id.isEmpty ? conv.id : conv.bot_id,
                    colorSeed: conv.id,
                    size: 36
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(rowTitle)
                        .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                        .foregroundStyle(
                            rowTitleIsPlaceholder ? Theme.Palette.inkMuted : Theme.Palette.ink
                        )
                        .lineLimit(1)
                    if ActiveVoiceCallStore.shared.calls[conv.id] != nil {
                        Image(systemName: "phone.fill")
                            .font(Theme.Fonts.glyph(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                            .accessibilityLabel("通话中")
                    }
                    Spacer(minLength: 8)
                    if conv.last_activity_at > 0 {
                        // Preset preseeded conversations are stamped with a
                        // slug-keyed offset on 1970-01-01 (see migration
                        // 0024). Render those as a literal "1970年" instead
                        // of the "55 年前" relative form so the badge reads
                        // as a deliberate marker, not a stale timestamp.
                        let date = Date(timeIntervalSince1970: TimeInterval(conv.last_activity_at))
                        let isEpochYear = Calendar.current.component(.year, from: date) == 1970
                        Group {
                            if isEpochYear {
                                Text("1970年")
                            } else {
                                Text(date, format: .relative(presentation: .numeric))
                            }
                        }
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conv.previewLine.isEmpty ? "还没有消息" : conv.previewLine)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    // Unread badge sits immediately left of the name tag.
                    HStack(spacing: 6) {
                        unreadBadge
                        nameTag
                    }
                    .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(isSelected ? Theme.Palette.accentBg : Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.Palette.accent.opacity(0.5) : Theme.Palette.hairline,
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }

    /// The 公/私 / 群 name pill on the right of the second row.
    @ViewBuilder
    private var nameTag: some View {
        if isGroupConv {
            GroupChatTag()
        } else {
            Text(primaryName)
                .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                .foregroundStyle(nameTagColors.fg)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(nameTagColors.bg))
                .lineLimit(1)
        }
    }

    /// Unread indicator shown just left of the name tag — a green capsule
    /// with the message count when the server reports unread messages,
    /// or a small green dot for the manual "标未读" flag. Green matches
    /// the app's brand accent.
    @ViewBuilder
    private var unreadBadge: some View {
        if unreadCount > 0 {
            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                .font(Theme.Fonts.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18)
                .frame(height: 18)
                .background(Capsule().fill(Theme.Palette.accent))
        } else if isUnread {
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - 扫码 sheet (camera + photo library QR decode)

/// Camera-backed QR scanner. PendingBot user-handle QRs land on the
/// add-friend preview page (avatar + nickname + 验证信息); group QRs auto-
/// join via /v1/groups/join (no useful preview — the join either lands or
/// it doesn't). The "扫相册里的码" button opens the system PhotosPicker
/// directly; the picked image is run through CIDetector and the result
/// fans out the same way as the camera path.
private struct ScanQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void = {}
    /// Called with the bare token when the scanned QR points at a user
    /// handle (resolved via /v1/friend-requests/lookup). Caller dismisses
    /// the scanner and presents AddFriendSheet with the handle pre-loaded,
    /// so both 扫码 and 输号码 land on the same review page.
    var onScannedUserHandle: (String) -> Void = { _ in }
    /// Called with the bot slug when the scanned QR is a bot-share link
    /// (`/b/<slug>`). Caller dismisses the scanner and presents
    /// AddBotSheet with the slug pre-loaded, landing on the bot preview.
    var onScannedBotSlug: (String) -> Void = { _ in }

    @State private var scannedValue: String?
    @State private var submitting = false
    @State private var error: String?
    @State private var displayText: String?
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let displayText {
                    Text(displayText)
                        .font(Theme.Fonts.system(size: 22, weight: .regular, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(10)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                        .textSelection(.enabled)
                } else if scannedValue == nil {
                    QRScannerView { value in
                        scannedValue = value
                        Haptics.tap()
                        Task { await handle(value: value) }
                    } onError: { err in
                        error = err.localizedDescription
                    }
                    .ignoresSafeArea()
                } else if submitting {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).controlSize(.large)
                        Text("处理中...")
                            .foregroundStyle(.white)
                    }
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Theme.Fonts.glyph(size: 40))
                            .foregroundStyle(.yellow)
                        Text(error)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("重新扫码") {
                            self.error = nil
                            self.scannedValue = nil
                        }
                        .foregroundStyle(.white)
                    }
                }

                // "扫相册里的码" affordance — pinned to the bottom while
                // the live camera is showing. Hidden once a code is decoded
                // (the sheet has already shifted into its result state).
                // Uses PhotosPicker directly so the tap opens the system
                // picker — no intermediate sheet with a second button.
                if scannedValue == nil, displayText == nil {
                    VStack {
                        Spacer()
                        PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                            Label("扫相册里的码", systemImage: "photo.on.rectangle")
                                .font(Theme.Fonts.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        }
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("扫码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                let decoded = await decodeQRFromPhoto(item)
                pickedPhoto = nil
                guard let decoded else {
                    error = "相册里这张图没找到二维码"
                    scannedValue = ""  // flip out of live-preview state
                    return
                }
                scannedValue = decoded
                Haptics.tap()
                await handle(value: decoded)
            }
        }
    }

    /// Fan-out for whatever the camera (or album decoder) produced:
    ///   1. PendingBot contact-share URL → try group join first (still an
    ///      immediate action — there's no useful "preview" for groups);
    ///      if the token isn't a group, hand the bare token back up to
    ///      the parent so it can open the add-friend preview page.
    ///   2. Other http(s) URL → hand off to Safari and dismiss.
    ///   3. Anything else → render the raw text in the centre of the sheet.
    private func handle(value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bot-share link (/b/<slug>) — disjoint from the /c/ contact path,
        // so check it first and hand the slug up for the add-bot preview.
        if BotShareLink.isBotShareLink(trimmed) {
            onScannedBotSlug(BotShareLink.slug(fromScanned: trimmed))
            return
        }
        if PendingBotQR.isPendingBotQR(trimmed) {
            submitting = true
            defer { submitting = false }
            let token = PendingBotQR.token(fromScanned: trimmed)
            if await tryJoinGroup(token: token) { return }
            // Not a group — hand the token off to the parent for the
            // preview/review flow. The parent dismisses us.
            onScannedUserHandle(token)
            return
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host?.isEmpty == false {
            await UIApplication.shared.open(url)
            dismiss()
            return
        }
        displayText = trimmed
    }

    /// Returns true when we either joined or filed a pending request.
    /// Returns false (without setting error) when the token isn't a
    /// known group handle — caller falls back to the user-handle path.
    private func tryJoinGroup(token: String) async -> Bool {
        do {
            let url = HostedConfig.environment.workerURL.appendingPathComponent("v1/groups/join")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let accessToken = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["handleValue": token])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            if http.statusCode == 404 { return false }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                error = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                return true   // surfaced the error; don't try friend path
            }
            Haptics.success()
            onAdded()
            dismiss()
            return true
        } catch {
            // Network glitch or auth error — let the friend path try too,
            // it'll fail the same way and surface a real message.
            return false
        }
    }
}

// MARK: - 加好友 chooser (扫码 / 输号码)

/// Two-way fork shown when the user taps 加好友 from the message tab's
/// "+" menu. Two side-by-side tiles, icon + short label, no copy.
private struct AddFriendChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onPickScan: () -> Void
    var onPickHandle: () -> Void

    var body: some View {
        NavigationStack {
            HStack(spacing: 14) {
                chooserTile(title: "扫码", systemImage: "qrcode.viewfinder", action: onPickScan)
                chooserTile(title: "输号码", systemImage: "number", action: onPickHandle)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func chooserTile(title: String, systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(Theme.Fonts.glyph(size: 36, weight: .regular))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 72, height: 72)
                Text(title)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 扫相册里的码 (decode QR from a picked photo)

/// Loads the picked photo via PhotosPickerItem and runs CIDetector over
/// it; returns the first decoded QR string, or nil if the image has none.
/// iOS 16+ only, which matches the app's deployment target.
private func decodeQRFromPhoto(_ item: PhotosPickerItem) async -> String? {
    guard let data = try? await item.loadTransferable(type: Data.self),
          let uiImage = UIImage(data: data),
          let ciImage = CIImage(image: uiImage) else { return nil }
    let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    let features = detector?.features(in: ciImage) ?? []
    for f in features {
        if let q = f as? CIQRCodeFeature, let s = q.messageString, !s.isEmpty {
            return s
        }
    }
    return nil
}

// MARK: - Create group page

/// Group chat creation page (pushed onto the message-tab nav stack so it
/// gets a full screen rather than a half-sheet). Title is auto-filled
/// from `/v1/groups/random-name` on appear, with a regenerate button at
/// the trailing edge of the name field. The member picker merges bots
/// + humans into one list sorted by recent chat activity — same ranking
/// as the parent conversations list (most-recent first), with anyone the
/// caller hasn't talked to yet appended at the bottom in name order.
private struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modelCatalog: ModelCatalog

    /// participant id → rank (lower = more recently chatted). Built by
    /// MessageTabView from its already-sorted conversations list so this
    /// view doesn't re-query.
    let recentOrder: [String: Int]
    var onCreated: (String, String) -> Void

    enum MemberKind { case bot, human }
    struct Member: Identifiable, Hashable {
        let id: String
        let kind: MemberKind
        let name: String
        /// Bot model_id (subtitle); nil for humans.
        let modelId: String?
        /// Avatar inputs — humans use the seed/path pair, bots use the
        /// emoji-glyph deterministic avatar keyed off `id`.
        let avatarSeed: String
        let avatarPath: String?
    }

    private struct BotDecodable: Decodable {
        let id: String
        let slug: String?
        let display_name: String
        let model_id: String?
        let visibility: String?
        let is_active: Bool?
    }

    private struct BotContactDecodable: Decodable {
        let added_at: String?
        let bot: BotDecodable
    }

    @State private var title = ""
    @State private var members: [Member] = []
    @State private var selectedIds = Set<String>()
    @State private var loading = true
    @State private var creating = false
    @State private var generatingName = false
    @State private var didPreloadTitle = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("群名") {
                HStack(spacing: 8) {
                    TextField("起个名字", text: $title)
                        .textInputAutocapitalization(.never)
                    Button {
                        Task { await regenerateTitle() }
                    } label: {
                        Image(systemName: generatingName ? "hourglass" : "arrow.clockwise")
                            .font(Theme.Fonts.glyph(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.Palette.accentBg))
                    }
                    .buttonStyle(.plain)
                    .disabled(generatingName)
                    .accessibilityLabel("换一个名字")
                }
            }
            Section("成员") {
                if loading && members.isEmpty {
                    HStack { ProgressView(); Text("加载中...").foregroundStyle(.secondary) }
                } else if members.isEmpty {
                    Text("还没有可选成员").foregroundStyle(.secondary)
                }
                ForEach(members) { m in
                    memberRow(m)
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote) }
            }
        }
        .navigationTitle("发起群聊")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("创建") { Task { await create() } }
                    .disabled(creating
                              || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || selectedIds.isEmpty)
            }
        }
        .task {
            await load()
            if !didPreloadTitle {
                didPreloadTitle = true
                if title.trimmingCharacters(in: .whitespaces).isEmpty {
                    await regenerateTitle()
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ m: Member) -> some View {
        let selected = selectedIds.contains(m.id)
        Button {
            toggle(id: m.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.inkMuted)
                Group {
                    switch m.kind {
                    case .bot:
                        BotAvatar(emojiSeed: m.id, colorSeed: m.id, size: 32)
                    case .human:
                        UserAvatar(seed: m.avatarSeed, attachmentId: m.avatarPath, size: 32)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).foregroundStyle(Theme.Palette.ink)
                    if let mid = m.modelId {
                        Text(modelCatalog.displayName(for: mid))
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func toggle(id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
        Haptics.tap()
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            async let botRowsResp: [BotContactDecodable] = SupabaseStack.shared
                .from("user_bot_contacts")
                .select("added_at, bot:bots!user_bot_contacts_bot_id_fkey!inner(id, slug, display_name, model_id, visibility, is_active)")
                .order("added_at", ascending: true)
                .execute()
                .value
            async let humanRowsResp: [FriendsTabView.HumanPick] = ContactsAPI.fetchContacts()
            // Bot choices must match the user's bot contacts, not the
            // global public bot table. Drop private and self bots because
            // open_group_conv rejects private bots and self-chat is not a
            // group participant.
            let bots = try await botRowsResp
                .filter { $0.bot.is_active != false }
                .filter { $0.bot.visibility != "private" }
                .filter { !($0.bot.slug?.hasPrefix("self-") ?? false) }
                .map { Member(
                    id: $0.bot.id, kind: .bot, name: $0.bot.display_name,
                    modelId: $0.bot.model_id, avatarSeed: $0.bot.id, avatarPath: nil
                ) }
            let humans = try await humanRowsResp.map { h in
                Member(
                    id: h.id, kind: .human, name: h.rowName,
                    modelId: nil, avatarSeed: h.avatarSeed, avatarPath: h.avatarPath
                )
            }
            // Merge + sort: anyone in `recentOrder` ranks first (lower
            // rank = more recent). Everyone else is appended below in
            // localized name order so the list stays deterministic.
            let merged = bots + humans
            self.members = merged.sorted { a, b in
                switch (recentOrder[a.id], recentOrder[b.id]) {
                case let (.some(ra), .some(rb)): return ra < rb
                case (.some, .none):             return true
                case (.none, .some):             return false
                case (.none, .none):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func regenerateTitle() async {
        generatingName = true; defer { generatingName = false }
        struct Response: Decodable { let name: String }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/random-name")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            self.title = decoded.name
            Haptics.tap()
        } catch {
            // Silent — leave whatever title was there. The user can still
            // type one in by hand.
        }
    }

    private func create() async {
        creating = true; defer { creating = false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let selectedBots = members.filter { $0.kind == .bot && selectedIds.contains($0.id) }.map(\.id)
        let selectedHumans = members.filter { $0.kind == .human && selectedIds.contains($0.id) }.map(\.id)
        do {
            // Worker /v1/groups (open_group_conv RPC). Direct INSERTs would
            // skip conversation_group_meta + group_billing_config +
            // group_member_billing seeding, leave the 30-member cap
            // unenforced, and let private bots through. The RPC is the
            // single contract that keeps all those side-tables consistent.
            struct Body: Encodable {
                let title: String?
                let memberUserIds: [String]
                let memberBotIds: [String]
            }
            struct Response: Decodable {
                let conversationId: String
                let invitationIds: [String]?
            }

            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                memberUserIds: selectedHumans,
                memberBotIds: selectedBots,
            ))

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "CreateGroup",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            Haptics.success()
            if let sent = decoded.invitationIds, !sent.isEmpty {
                self.error = "已创建群聊，并发送 \(sent.count) 个入群邀请。"
            }
            onCreated(decoded.conversationId, trimmedTitle)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
