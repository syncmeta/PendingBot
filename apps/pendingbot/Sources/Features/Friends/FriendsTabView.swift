#if os(iOS)
import SwiftUI
import Supabase

/// 好友 tab — single alphabetically-sorted list of bots and humans, no
/// nav title. Filter chips above the list narrow by type (人类 / 私有
/// 机器人 / 公有机器人 / 群); each row carries an AI / 人类 tag on the
/// far right so the type stays visible in the merged list.
///
/// Toolbar:
///   left  qrcode → live QR sheet (mint + refresh)
///   right +      → add-friend sheet (handle code or email)
///
/// Two layouts driven by horizontal size class (mirrors MessageTabView):
///   • compact (iPhone): NavigationStack push from the row into ConversationView
///   • regular (iPad landscape, Mac Catalyst): NavigationSplitView with the
///     friends list as a sidebar; tapping a friend swaps the right detail
///     pane to that ConversationView in place.
///
/// Tap behavior is lazy — we navigate with a synthetic empty Conversation
/// + a PendingPeer; ConversationView materialises the conv row on first
/// send, so opening a friend and walking away leaves no DB trace.
struct FriendsTabView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var bots: [BotPick] = []
    @State private var humans: [HumanPick] = []
    /// Pending incoming friend requests — rendered as a section above the
    /// friend list with inline accept/decline buttons. Refreshed alongside
    /// the contacts list on every `load()` (and explicitly after the
    /// AddFriendSheet closes, since auto-accept paths can flip a request
    /// into a fresh contact).
    @State private var pendingFriendRequests: [PendingFriendRequest] = []
    @State private var pendingGroupInvitations: [PendingGroupInvitation] = []
    @State private var loading = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var addingBot = false
    /// Slug pre-filled into AddBotSheet from a scanned QR / tapped
    /// universal link — non-empty means the sheet jumps to the preview.
    @State private var addBotPrefill = ""
    /// App-level deep-link inbox. When a /b/<slug> link lands here while
    /// the friends tab is alive, we consume it into addBotPrefill.
    @State private var deepLink = DeepLinkStore.shared
    @State private var creatingBot = false
    @State private var managingBot: BotPick?
    @State private var aliasEditTarget: HumanPick?
    @State private var showingQR = false
    @State private var filter: FriendFilter = .all
    // Sort preference — persisted so the user's choice survives relaunches.
    // `sortField` is the column; `sortAscending` is the direction (A→Z / 旧→新
    // when true). Stored as raw strings via @AppStorage so no extra plumbing.
    @AppStorage("friendSortFieldRaw") private var sortFieldRaw = FriendSortField.name.rawValue
    @AppStorage("friendSortAscending") private var sortAscending = true
    private var sortField: FriendSortField { FriendSortField(rawValue: sortFieldRaw) ?? .name }
    // friendId ("bot:<id>" / "user:<id>") → last-chat epoch seconds, built
    // from the conversations the user participates in. Drives "按最近聊天".
    @State private var lastActivity: [String: Int] = [:]
    @State private var path: [PendingPeer] = []
    // Selection-driven detail for regular size class — mirrors
    // MessageTabView so tapping a friend on Mac / iPad-landscape opens
    // the chat in the right pane instead of pushing inside the sidebar.
    @State private var selectedPeer: PendingPeer?

    var body: some View {
        Group {
            if sidebarLayout {
                regularBody
            } else {
                compactBody
            }
        }
        .task { await load() }
        // Consume a /b/<slug> deep link both when it arrives while we're
        // already on screen (onChange) and when TabRoot has just switched
        // us in to handle it (onAppear).
        .onAppear { consumeDeepLink() }
        .onChange(of: deepLink.pendingAddBotSlug) { _, _ in consumeDeepLink() }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $addingFriend) {
            AddFriendSheet { Task { await load() } }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $addingBot, onDismiss: { addBotPrefill = "" }) {
            AddBotSheet(
                onAdded: { addedBot in
                    // Optimistic prepend so the row shows up immediately,
                    // even before the network refresh resolves. Refresh
                    // follows to pick up server-derived fields.
                    if !self.bots.contains(where: { $0.id == addedBot.id }) {
                        self.bots.insert(addedBot, at: 0)
                    }
                    Task {
                        await load()
                        // Drop straight into the new bot's chat — matches
                        // the "accept friend request → open chat"
                        // affordance for humans.
                        await tapBot(addedBot)
                    }
                },
                prefilledSlug: addBotPrefill
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $creatingBot) {
            CreateBotSheet { newBot in
                // Prepend so the user sees the new bot immediately,
                // then refresh from server to get any RLS-derived
                // ordering right.
                self.bots.insert(newBot, at: 0)
                Task { await load() }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $managingBot) { pick in
            ManageBotSheet(
                onChanged: { Task { await load() } },
                onDeleted: { id in
                    self.bots.removeAll { $0.id == id }
                },
                initial: pick
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingQR) {
            MyQRSheet()
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $aliasEditTarget) { contact in
            ContactAliasSheet(contact: contact) { Task { await load() } }
                .presentationDragIndicator(.visible)
        }
    }

    // ── Compact (iPhone) ────────────────────────────────────────────────────

    private var compactBody: some View {
        NavigationStack(path: $path) {
            sidebarBody
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: PendingPeer.self) { peer in
                    ConversationView(
                        conversation: pendingConversation(for: peer),
                        bot: bot(for: peer),
                        pendingPeer: peer
                    )
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
            if let peer = selectedPeer {
                ConversationView(
                    conversation: pendingConversation(for: peer),
                    bot: bot(for: peer),
                    pendingPeer: peer
                )
                // .id forces a fresh ConversationView (and a fresh WS)
                // when the user picks a different friend — without it
                // the existing view would just rebind, leaking the
                // prior chat's pending-send / message-list state.
                .id("\(peer.kind):\(peer.peerId)")
            } else {
                EmptyDetailHint(text: "选一位朋友开始", systemImage: "person.2")
            }
        }
    }

    // ── Sidebar (shared) ────────────────────────────────────────────────────

    @ViewBuilder
    private var sidebarBody: some View {
        VStack(spacing: 0) {
            // Background applied at the VStack level (not just inside
            // the lower ZStack) so the TabHeaderBar at the top sits
            // on canvas instead of the default white safe-area fill.
            TabHeaderBar(title: "好友") {
                HStack(spacing: 6) {
                    friendSortMenu
                    PlusActionPopover(items: [
                        PlusActionItem(title: "加好友", systemImage: "person.badge.plus") {
                            addingFriend = true
                        },
                        PlusActionItem(title: "加机器人", systemImage: "rectangle.badge.plus") {
                            addingBot = true
                        },
                        PlusActionItem(title: "新建机器人", systemImage: "sparkles") {
                            creatingBot = true
                        },
                    ])
                }
            }
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                List {
                    // Self row — pinned at the top, always visible
                    // regardless of filter. QR button on the right opens
                    // the user's name card; tapping the rest of the row
                    // pushes a chat with self.
                    Section {
                        let selfSelected = sidebarLayout && selectedPeer?.kind == "self"
                        SelfRow(
                            avatarSeed: AccountStore.shared.avatarSeed
                                ?? AccountStore.shared.current?.id ?? "?",
                            attachmentId: AccountStore.shared.avatarAttachmentId,
                            name: AccountStore.shared.profileDisplayName
                                ?? AccountStore.shared.current?.displayName ?? "你",
                            onTap: { Task { await tapSelf() } },
                            onQR: { showingQR = true; Haptics.tap() }
                        )
                        .listRowBackground(selfSelected ? Theme.Palette.accentBg : Theme.Palette.surface)
                    }

                    Section {
                        FilterPillBar(filter: $filter)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }

                    // Pending incoming friend requests — pinned above the
                    // friend list so the user notices and acts on them
                    // before scrolling. Each row carries 同意 / 拒绝 inline.
                    // Hidden when there's nothing pending.
                    if !pendingFriendRequests.isEmpty {
                        Section("好友申请") {
                            ForEach(pendingFriendRequests) { req in
                                FriendRequestRow(
                                    request: req,
                                    onAccept: { Task { await respondToRequest(req, accept: true) } },
                                    onDecline: { Task { await respondToRequest(req, accept: false) } }
                                )
                                .listRowBackground(Theme.Palette.surface)
                            }
                        }
                    }

                    if !pendingGroupInvitations.isEmpty {
                        Section("群邀请") {
                            ForEach(pendingGroupInvitations) { invite in
                                GroupInvitationRow(
                                    invitation: invite,
                                    onAccept: { Task { await respondToGroupInvitation(invite, accept: true) } },
                                    onDecline: { Task { await respondToGroupInvitation(invite, accept: false) } }
                                )
                                .listRowBackground(Theme.Palette.surface)
                            }
                        }
                    }

                    // Single merged section — bots and humans interleaved in
                    // alphabetical order. Filter chips above narrow by type.
                    if !friendsForFilter.isEmpty {
                        Section {
                            ForEach(friendsForFilter) { item in
                                switch item {
                                case .bot(let bot):
                                    let selected = sidebarLayout && isSelected(kind: "bot", id: bot.id)
                                    FriendRow(kind: .bot,
                                              avatarSeed: bot.id,
                                              name: bot.display_name,
                                              modelSlug: bot.model_id,
                                              botVisibility: bot.visibility)
                                        .listRowBackground(selected ? Theme.Palette.accentBg : Theme.Palette.surface)
                                        .contentShape(Rectangle())
                                        .onTapGesture { Task { await tapBot(bot) } }
                                        .modifier(BotRowOwnerActions(
                                            bot: bot,
                                            isMine: ownsBot(bot),
                                            onManage: { managingBot = bot }
                                        ))
                                case .human(let c):
                                    let selected = sidebarLayout && isSelected(kind: "user", id: c.id)
                                    FriendRow(kind: .human,
                                              avatarSeed: c.avatarSeed,
                                              avatarAttachmentId: c.avatarPath,
                                              name: c.rowName,
                                              modelSlug: nil,
                                              botVisibility: nil)
                                        .listRowBackground(selected ? Theme.Palette.accentBg : Theme.Palette.surface)
                                        .contentShape(Rectangle())
                                        .onTapGesture { Task { await tapHuman(c) } }
                                        .contextMenu {
                                            Button {
                                                aliasEditTarget = c
                                            } label: {
                                                Label(c.alias?.isEmpty == false ? "修改备注" : "设置备注",
                                                      systemImage: "person.text.rectangle")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    if let emptyText = emptyTextForFilter {
                        Section {
                            Text(emptyText)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Theme.Palette.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .refreshable { await load() }
            }
        }
    }

    /// True when the row's peer is the one currently shown in the
    /// regular-size detail pane. Used to tint the row so the user can
    /// see what's open on the right.
    private func isSelected(kind: String, id: String) -> Bool {
        guard let peer = selectedPeer else { return false }
        return peer.kind == kind && peer.peerId == id
    }

    // ── Sort menu ───────────────────────────────────────────────────────────

    /// Header sort control. The inline Picker picks the field (with native
    /// checkmarks); the row below flips the direction for the active field.
    /// Switching field resets to that field's natural default direction.
    private var friendSortMenu: some View {
        Menu {
            Picker("排序方式", selection: sortFieldBinding) {
                ForEach(FriendSortField.allCases, id: \.self) { field in
                    Label(field.label, systemImage: field.systemImage).tag(field)
                }
            }
            Divider()
            Button {
                sortAscending.toggle()
                Haptics.tap()
            } label: {
                Label(sortField.directionLabel(ascending: sortAscending),
                      systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
        } label: {
            HeaderActionIcon(systemImage: "arrow.up.arrow.down")
        }
    }

    private var sortFieldBinding: Binding<FriendSortField> {
        Binding(
            get: { sortField },
            set: { newValue in
                sortFieldRaw = newValue.rawValue
                sortAscending = newValue.defaultAscending
                Haptics.tap()
            }
        )
    }

    // MARK: - Data

    struct BotPick: Identifiable, Hashable {
        let id: String
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
        let voice_call_enabled: Bool?
        /// When this bot was added (user_bot_contacts.added_at), epoch
        /// seconds. Drives the "按加好友时间" sort; 0 when unknown (e.g. a
        /// pre-v7 cached row before the network refresh lands).
        var addedAt: Int = 0
    }
    struct HumanPick: Identifiable, Hashable {
        let id: String
        /// Caller's local remark for this contact. Wins over `displayName`
        /// when present so the user's own naming choice always takes
        /// precedence in the friend list.
        let alias: String?
        /// Peer's own profile name (read by the worker via service-role,
        /// because pendingbot.users RLS is self-only). Empty string when
        /// they haven't set one — the row falls back to id-prefix.
        let displayName: String
        /// Avatar attachment id if uploaded; nil falls through to the
        /// emoji-glyph deterministic avatar.
        let avatarPath: String?
        /// Stable per-account seed for the placeholder emoji. Source of
        /// truth lives in `users.custom_fields.avatar_seed` (set by
        /// onboarding); the worker's /v1/contacts response includes it
        /// so every viewer (self / friend / web) hashes the SAME string
        /// and lands on the same emoji. Falls back to `id` when the peer
        /// is a legacy account that never bootstrapped — different
        /// viewers will still pick the same emoji for that user since
        /// they're hashing the same id.
        let avatarSeed: String
        /// When this friend was added (user_contacts.created_at), epoch
        /// seconds. Drives the "按加好友时间" sort; 0 when unknown.
        var addedAt: Int = 0

        /// What to render in the row title and pass on to ConversationView
        /// as the header label. Mirrors the chat-header alias > displayName
        /// preference so opening a chat doesn't change the displayed name.
        var rowName: String {
            if let a = alias, !a.isEmpty { return a }
            if !displayName.isEmpty { return displayName }
            return String(id.prefix(8))
        }
    }
    /// Slim model for an inbox row. Only carries fields the inline accept /
    /// decline UI cares about — `peerDisplayName` falls back to the first 8
    /// chars of the user id when the peer hasn't filled out a profile yet.
    struct PendingFriendRequest: Identifiable, Hashable {
        let id: String
        let peerUserId: String
        let peerDisplayName: String
        let message: String?
        /// Server-supplied placeholder-emoji seed (peerAvatarSeed in the
        /// /v1/friend-requests response). Falls back to peerUserId when
        /// the request comes from a legacy account that never bootstrapped.
        let peerAvatarSeed: String
    }

    struct PendingGroupInvitation: Identifiable, Hashable {
        let id: String
        let conversationId: String
        let groupTitle: String
        let inviterName: String
        let inviterAvatarSeed: String
        let inviterAvatarPath: String?
        let billingText: String
    }

    /// Unified row type so bots and humans share one alphabetically-sorted
    /// section. Filter chips already do the type-narrowing that separate
    /// sections used to.
    enum FriendRowItem: Identifiable, Hashable {
        case bot(BotPick)
        case human(HumanPick)

        var id: String {
            switch self {
            case .bot(let b):   return "bot:\(b.id)"
            case .human(let h): return "user:\(h.id)"
            }
        }

        /// Name used for both the row label and the sort key, so the
        /// visible order matches what the user reads (alias > displayName
        /// for humans; display_name for bots).
        var sortName: String {
            switch self {
            case .bot(let b):   return b.display_name
            case .human(let h): return h.rowName
            }
        }

        /// Friend-added time (epoch seconds) for the "按加好友时间" sort.
        var addedAt: Int {
            switch self {
            case .bot(let b):   return b.addedAt
            case .human(let h): return h.addedAt
            }
        }
    }

    private struct BotDecodable: Decodable {
        let id: String
        let slug: String?
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
        let voice_call_enabled: Bool?
        let is_active: Bool?
    }

    /// Embed wrapper for `from("user_bot_contacts").select("added_at, bot:bots!fk(...)")`.
    /// The Friends Tab now lists bots the user has explicitly added (or that
    /// were added implicitly via the auto-conv trigger / bootstrap); the bot
    /// payload comes back nested under `bot`. `added_at` is the contact-row
    /// timestamp (ISO 8601) driving the "按加好友时间" sort.
    private struct BotContactDecodable: Decodable {
        let added_at: String?
        let bot: BotDecodable
    }

    /// Pull a pending /b/<slug> deep link out of the shared inbox and open
    /// the add-bot preview on it. The small defer lets a concurrent tab
    /// switch (regular layout: TabRoot flips us in) settle before the
    /// sheet animates in.
    private func consumeDeepLink() {
        guard let slug = deepLink.pendingAddBotSlug, !slug.isEmpty else { return }
        deepLink.pendingAddBotSlug = nil
        addBotPrefill = slug
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            addingBot = true
        }
    }

    private func load() async {
        // Hydrate from local cache so the tab paints last-known friends
        // instantly instead of flashing empty until the network round-trip
        // lands. First-paint fallback only — guarded on `bots.isEmpty &&
        // humans.isEmpty` so a pull-to-refresh on a warm screen doesn't
        // visibly drop fresh data back to cache while the call is in
        // flight. Pending friend requests aren't cached: the state changes
        // too quickly to be worth showing stale.
        if bots.isEmpty && humans.isEmpty {
            let cachedBots = LocalDatabase.shared.loadBots()
            let cachedContacts = LocalDatabase.shared.loadContacts()
            if !cachedBots.isEmpty {
                self.bots = cachedBots.map {
                    BotPick(id: $0.id, display_name: $0.display_name,
                            model_id: $0.model_id, visibility: $0.visibility,
                            creator_id: $0.creator_id,
                            voice_call_enabled: $0.voice_call_enabled,
                            addedAt: $0.added_at ?? 0)
                }
            }
            if !cachedContacts.isEmpty {
                self.humans = cachedContacts.map {
                    HumanPick(id: $0.id, alias: $0.alias,
                              displayName: $0.display_name,
                              avatarPath: $0.avatar_path,
                              avatarSeed: $0.avatar_seed ?? $0.id,
                              addedAt: $0.added_at ?? 0)
                }
            }
            // Seed the recent-chat sort key from the cached conversations so
            // the "按最近聊天" order is roughly right on first paint. Bots map
            // cleanly by bot_id; user_user convs don't carry the peer id in
            // the cache, so humans fill in once the network query below lands.
            if lastActivity.isEmpty {
                var seeded: [String: Int] = [:]
                for conv in LocalDatabase.shared.loadConversations() {
                    if let botId = conv.bot_id, !botId.isEmpty {
                        seeded["bot:\(botId)"] = max(seeded["bot:\(botId)"] ?? 0, conv.last_activity_at)
                    }
                }
                lastActivity = seeded
            }
        }
        loading = true; defer { loading = false }
        do {
            // Bot list now comes from `user_bot_contacts` (added bots only),
            // not the global `bots` table. Two reasons:
            //   1. UX: the previous query returned every public_open bot in
            //      the system, so the list grew unbounded and users couldn't
            //      curate it. With contacts, the user only sees what they
            //      explicitly (or implicitly, via past conversations) added.
            //   2. Visibility: the old path leaked public_open bots into the
            //      friends list whether the user cared about them or not.
            // `user_bot_contacts` is RLS-scoped to auth.uid(), and the !inner
            // join to `bots` drops rows whose bot was hard-deleted. is_active
            // is filtered client-side after decode — soft-deleted bots stay
            // hidden but their contact row remains (for cheap re-show if the
            // bot comes back).
            async let botRowsResp: [BotContactDecodable] = SupabaseStack.shared
                .from("user_bot_contacts")
                .select("added_at, bot:bots!user_bot_contacts_bot_id_fkey!inner(id, slug, display_name, model_id, visibility, creator_id, voice_call_enabled, is_active)")
                .order("added_at", ascending: true)
                .execute()
                .value
            async let contactsResp: [HumanPick] = loadContactsWithProfiles()
            async let incomingFR: [PendingFriendRequest] = loadIncomingFriendRequests()
            async let incomingGroupInvites: [PendingGroupInvitation] = loadIncomingGroupInvitations()
            // Recent-chat sort key. Non-fatal: an empty map just degrades the
            // "按最近聊天" order, it never blocks the list.
            async let activityResp: [ConvActivityRow] = loadConversationActivity()

            let botContactRows = try await botRowsResp

            // Drop the per-user self-bot from the regular bot list — its
            // entry is the SelfRow pinned at the top of the friends tab,
            // and chatting with it via the bot path would skip the
            // self-chat materialiser (open_self_conv RPC) and the
            // user-memory swap in bot-reply.
            self.bots = botContactRows
                .filter { $0.bot.is_active != false }
                .filter { !($0.bot.slug?.hasPrefix("self-") ?? false) }
                .map { row in
                    BotPick(id: row.bot.id, display_name: row.bot.display_name,
                            model_id: row.bot.model_id, visibility: row.bot.visibility,
                            creator_id: row.bot.creator_id,
                            voice_call_enabled: row.bot.voice_call_enabled,
                            addedAt: row.added_at.map { ServerTimestamp.epochSeconds($0, default: 0) } ?? 0)
                }
            // Persist bots wholesale on success — server is the source of
            // truth for which ones are still active / visible to us.
            LocalDatabase.shared.replaceBots(self.bots.map {
                LocalDatabase.BotRow(
                    id: $0.id, display_name: $0.display_name,
                    model_id: $0.model_id, visibility: $0.visibility,
                    creator_id: $0.creator_id,
                    voice_call_enabled: $0.voice_call_enabled,
                    added_at: $0.addedAt
                )
            })

            // Contacts: only overwrite the cache when the fetch actually
            // succeeded. A transient failure preserves whatever was last
            // persisted so the next tab entry can hydrate from it.
            if let contacts = try? await contactsResp {
                self.humans = contacts
                LocalDatabase.shared.replaceContacts(contacts.map {
                    LocalDatabase.ContactRow(
                        id: $0.id, alias: $0.alias,
                        display_name: $0.displayName,
                        avatar_path: $0.avatarPath,
                        avatar_seed: $0.avatarSeed,
                        added_at: $0.addedAt
                    )
                })
            } else {
                self.humans = []
            }
            self.lastActivity = buildActivityMap(await activityResp)
            self.pendingFriendRequests = await incomingFR
            self.pendingGroupInvitations = await incomingGroupInvites
        } catch is CancellationError {
            // Tab switch / refreshable cancellation — silent. The Mac
            // shell rebuilds the active tab on every selection change, so
            // any in-flight load() trips this when the user moves on.
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Contacts

    /// Pull the friends list from the worker so peer display_name +
    /// avatar_path land in one trip. iOS can't read those columns directly
    /// because pendingbot.users RLS is self-only.
    private func loadContactsWithProfiles() async throws -> [HumanPick] {
        try await ContactsAPI.fetchContacts()
    }

    // MARK: - Recent-chat activity

    /// One row of the conversations the caller participates in, trimmed to
    /// just what the "按最近聊天" sort needs. RLS (`is_participant`) scopes
    /// the read to the caller's own convs, so no explicit user filter is
    /// needed. `participants` is embedded so user_user rows can resolve the
    /// peer's user id (the conv row itself only carries the creator).
    private struct ConvActivityRow: Decodable {
        let bot_id: String?
        let conversation_type: String?
        let updated_at: String?
        struct Unread: Decodable { let last_message_at: String? }
        let unread: [Unread]?
        struct Participant: Decodable {
            let participant_type: String
            let participant_id: String
        }
        let participants: [Participant]?

        /// Prefer the unread row's last_message_at (mirrors the message list's
        /// ordering); fall back to updated_at, then 0.
        var activitySeconds: Int {
            if let s = unread?.first?.last_message_at,
               let d = ServerTimestamp.parse(s) { return Int(d.timeIntervalSince1970) }
            if let s = updated_at,
               let d = ServerTimestamp.parse(s) { return Int(d.timeIntervalSince1970) }
            return 0
        }
    }

    private func loadConversationActivity() async -> [ConvActivityRow] {
        do {
            return try await SupabaseStack.shared
                .from("conversations")
                .select("bot_id, conversation_type, updated_at, unread:user_unread_counts(last_message_at), participants:conversation_participants(participant_type, participant_id)")
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// Collapse the conversation rows into a friendId → last-chat-seconds map,
    /// keyed with the same "bot:<id>" / "user:<id>" scheme as FriendRowItem.id
    /// so the sort comparator can look up by `item.id` directly. A bot can
    /// have several convs (sub-conversations), so we keep the max.
    private func buildActivityMap(_ rows: [ConvActivityRow]) -> [String: Int] {
        let myId = AccountStore.shared.current?.id ?? ""
        var map: [String: Int] = [:]
        for row in rows {
            let ts = row.activitySeconds
            if let botId = row.bot_id, !botId.isEmpty {
                let key = "bot:\(botId)"
                map[key] = max(map[key] ?? 0, ts)
            }
            if row.conversation_type == "user_user" {
                let otherId = row.participants?.first {
                    $0.participant_type == "user" && $0.participant_id != myId
                }?.participant_id
                if let otherId {
                    let key = "user:\(otherId)"
                    map[key] = max(map[key] ?? 0, ts)
                }
            }
        }
        return map
    }

    // MARK: - Friend requests

    private func loadIncomingFriendRequests() async -> [PendingFriendRequest] {
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/friend-requests")
                .appending(queryItems: [URLQueryItem(name: "direction", value: "incoming")])
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return [] }
            struct Payload: Decodable {
                struct Row: Decodable {
                    let id: String
                    let status: String
                    let message: String?
                    let peerUserId: String
                    let peerDisplayName: String
                    let peerAvatarSeed: String?
                }
                let requests: [Row]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return payload.requests
                .filter { $0.status == "pending" }
                .map { r in
                    let name = r.peerDisplayName.isEmpty
                        ? String(r.peerUserId.prefix(8)) : r.peerDisplayName
                    return PendingFriendRequest(
                        id: r.id, peerUserId: r.peerUserId,
                        peerDisplayName: name, message: r.message,
                        peerAvatarSeed: r.peerAvatarSeed ?? r.peerUserId
                    )
                }
        } catch {
            return []
        }
    }

    /// Accept (or decline) by hitting the worker endpoint. Optimistically
    /// drops the row from the inbox so the UI feels responsive; a follow-
    /// up `load()` reconciles whatever the server actually committed.
    ///
    /// On accept, we ride the worker's `peerUserId` field straight into
    /// the new friend's 1:1 chat — same path as tapping their row in the
    /// friend list. open-chat finds-or-creates the user_user conv (it
    /// already exists at this point: accept_friend_request wrote both
    /// user_contacts rows before returning).
    private func respondToRequest(_ request: PendingFriendRequest, accept: Bool) async {
        pendingFriendRequests.removeAll { $0.id == request.id }
        do {
            let action = accept ? "accept" : "decline"
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/friend-requests/\(request.id)/\(action)")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw URLError(.badServerResponse) }
            Haptics.success()
            if accept {
                // Prefer the worker-returned peerUserId (canonical), but
                // fall back to whatever the inbox row carried.
                struct AcceptResp: Decodable { let peerUserId: String? }
                let peerId = (try? JSONDecoder().decode(AcceptResp.self, from: data).peerUserId)
                    ?? request.peerUserId
                await openChatWith(peerId: peerId, displayName: request.peerDisplayName,
                                   avatarSeed: request.peerAvatarSeed)
            }
        } catch {
            self.error = "处理好友申请失败: \(error.localizedDescription)"
            Haptics.error()
        }
        // Always refresh — accept also adds a row to user_contacts which
        // the friends list needs to pick up.
        await load()
    }

    private func loadIncomingGroupInvitations() async -> [PendingGroupInvitation] {
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/invitations")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return [] }
            struct Payload: Decodable {
                struct Row: Decodable {
                    struct Inviter: Decodable {
                        let display_name: String
                        let avatar_path: String?
                        let avatar_seed: String?
                    }
                    struct Billing: Decodable { let text: String? }
                    let id: String
                    let conversation_id: String
                    let status: String
                    let group_title: String
                    let billing_snapshot: Billing?
                    let inviter: Inviter
                }
                let invitations: [Row]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return payload.invitations
                .filter { $0.status == "pending" }
                .map { row in
                    PendingGroupInvitation(
                        id: row.id,
                        conversationId: row.conversation_id,
                        groupTitle: row.group_title,
                        inviterName: row.inviter.display_name.isEmpty ? "群成员" : row.inviter.display_name,
                        inviterAvatarSeed: row.inviter.avatar_seed ?? row.conversation_id,
                        inviterAvatarPath: row.inviter.avatar_path,
                        billingText: row.billing_snapshot?.text ?? "接受后会按当前群设置参与机器人 Token 分摊。"
                    )
                }
        } catch {
            return []
        }
    }

    private func respondToGroupInvitation(_ invitation: PendingGroupInvitation, accept: Bool) async {
        pendingGroupInvitations.removeAll { $0.id == invitation.id }
        struct Body: Encodable { let approve: Bool }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/invitations/\(invitation.id)/decide")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(approve: accept))
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw URLError(.badServerResponse) }
            Haptics.success()
        } catch {
            self.error = "处理群邀请失败: \(error.localizedDescription)"
            Haptics.error()
        }
        await load()
    }

    /// Resolve (or materialise) the singleton user_user conv between the
    /// caller and `peerId`, then route to it via the existing `open()`
    /// path. Same recipe as tapping a human friend row in the list, just
    /// driven from the accept-button instead of a tap gesture.
    private func openChatWith(peerId: String, displayName: String, avatarSeed: String) async {
        let convId = try? await fetchOrCreateUserUserConv(peerId: peerId)
        open(PendingPeer(kind: "user",
                         peerId: peerId,
                         displayName: displayName,
                         avatarPath: nil,
                         avatarSeed: avatarSeed,
                         existingConvId: convId))
    }

    // MARK: - Filtering

    /// Merged + sorted friend list for the current filter. Bots and humans
    /// share one section so the sort can interleave them. The order is driven
    /// by `sortField` / `sortAscending`; name comparison uses
    /// `localizedStandardCompare` (pinyin-aware for Chinese, case-insensitive
    /// for ASCII), and the time fields fall back to name on ties so the order
    /// stays stable when timestamps are missing/equal.
    private var friendsForFilter: [FriendRowItem] {
        let items: [FriendRowItem]
        switch filter {
        case .all:
            items = bots.map { .bot($0) } + humans.map { .human($0) }
        case .humans:
            items = humans.map { .human($0) }
        case .privateBots:
            items = bots.filter { $0.visibility == "private" }.map { .bot($0) }
        case .publicBots:
            items = bots.filter { $0.visibility != "private" }.map { .bot($0) }
        case .groups:
            items = []
        }
        return items.sorted(by: sortComparator)
    }

    /// Two-friend ordering for the active sort field + direction. Pulled out
    /// of `friendsForFilter` so the comparison logic reads top-to-bottom.
    private func sortComparator(_ a: FriendRowItem, _ b: FriendRowItem) -> Bool {
        func byName() -> Bool {
            let r = a.sortName.localizedStandardCompare(b.sortName)
            if r == .orderedSame { return a.id < b.id }
            return sortAscending ? (r == .orderedAscending) : (r == .orderedDescending)
        }
        switch sortField {
        case .name:
            return byName()
        case .recentChat:
            let la = lastActivity[a.id] ?? 0
            let lb = lastActivity[b.id] ?? 0
            if la == lb {
                // Tie (e.g. neither has chatted yet) → fall back to A→Z so
                // the list never looks randomly shuffled.
                return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
            }
            return sortAscending ? (la < lb) : (la > lb)
        case .addedTime:
            let aa = a.addedAt
            let ab = b.addedAt
            if aa == ab {
                return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
            }
            return sortAscending ? (aa < ab) : (aa > ab)
        }
    }

    /// Optional placeholder shown when a filter selection has no rows.
    /// `.all` never shows one — even an empty account still has the
    /// pinned self row above.
    private var emptyTextForFilter: String? {
        switch filter {
        case .all:
            return nil
        case .humans:
            return friendsForFilter.isEmpty ? "还没有人类朋友" : nil
        case .privateBots:
            return friendsForFilter.isEmpty ? "还没有私有机器人" : nil
        case .publicBots:
            return friendsForFilter.isEmpty ? "还没有公有机器人" : nil
        case .groups:
            return "还没有群聊"
        }
    }

    /// True when the current user is the bot's creator (preset bots have a
    /// nil creator). Drives whether the long-press "管理" entry shows up.
    private func ownsBot(_ bot: BotPick) -> Bool {
        guard let me = AccountStore.shared.current?.id, let owner = bot.creator_id
        else { return false }
        return owner == me
    }

    // MARK: - Tap handlers
    //
    // Lazy: navigate with a synthetic empty Conversation + a PendingPeer.
    // ConversationView materialises the conv row on first send, so tapping
    // a friend and backing out without sending leaves no DB trace.

    private func tapBot(_ bot: BotPick) async {
        // Bots land on a fresh, empty conversation — the pre-chat hub
        // (致电 / 请它写信 / 设置) is what greets the user, not an existing
        // thread. Humans go straight into their 1:1 chat; bots get the
        // action bar first. existingConvId nil → materialize-on-first-send.
        open(PendingPeer(kind: "bot",
                         peerId: bot.id,
                         displayName: bot.display_name))
    }

    private func bot(for peer: PendingPeer) -> Bot? {
        guard peer.kind == "bot",
              let pick = bots.first(where: { $0.id == peer.peerId }) else {
            return nil
        }
        return Bot(
            id: pick.id,
            display_name: pick.display_name,
            access_mode: nil,
            model: pick.model_id,
            visibility: pick.visibility,
            creator_id: pick.creator_id,
            voice_call_enabled: pick.voice_call_enabled
        )
    }

    /// Push a "chat with self" conv. Materialises server-side via the
    /// dedicated open_self_conv RPC, which find-or-creates the user's
    /// per-user private self-bot and a singleton self-conv attached to it.
    private func tapSelf() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let displayName = AccountStore.shared.profileDisplayName
            ?? AccountStore.shared.current?.displayName ?? "你"
        open(PendingPeer(kind: "self",
                         peerId: userId,
                         displayName: displayName))
    }

    private func tapHuman(_ c: HumanPick) async {
        // Eagerly resolve the singleton 1:1 conv id so the chat view
        // loads existing history immediately. The worker's
        // /v1/contacts/open-chat endpoint is find-or-create; if no conv
        // exists yet (brand-new friendship) it creates one and returns
        // the id. Failures here fall through to the materialize-on-first-
        // send path (PendingPeer with no convId).
        let existing = try? await fetchOrCreateUserUserConv(peerId: c.id)
        open(PendingPeer(kind: "user",
                         peerId: c.id,
                         displayName: c.rowName,
                         avatarPath: c.avatarPath,
                         avatarSeed: c.avatarSeed,
                         existingConvId: existing))
    }

    private func fetchOrCreateUserUserConv(peerId: String) async throws -> String {
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/contacts/open-chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["contactUserId": peerId])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct OpenChat: Decodable { let conversationId: String }
        return try JSONDecoder().decode(OpenChat.self, from: data).conversationId
    }

    /// Route to the right surface based on layout: regular (Mac /
    /// iPad-landscape) shows the chat in the right detail pane via a
    /// selection binding; compact (iPhone) pushes onto the nav stack.
    private func open(_ peer: PendingPeer) {
        if sidebarLayout {
            selectedPeer = peer
        } else {
            path.append(peer)
        }
        Haptics.tap()
    }

    private func pendingConversation(for peer: PendingPeer) -> Conversation {
        let userId = AccountStore.shared.current?.id ?? ""
        // If the caller already resolved an existing conv id, hand it
        // through so ConversationView treats this as a materialised conv
        // (id non-empty) and loads its history right away instead of
        // sitting blank until the first message is sent.
        return Conversation(
            id: peer.existingConvId ?? "",
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
}

// MARK: - Friend row

/// Pinned-to-top row representing "yourself". Tap the row to open a
/// chat-with-self conv; tap the QR icon to flip up the name-card
/// sheet. Visually mirrors FriendRow so the list reads consistently.
private struct SelfRow: View {
    let avatarSeed: String
    let attachmentId: String?
    let name: String
    let onTap: () -> Void
    let onQR: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            UserAvatar(seed: avatarSeed, attachmentId: attachmentId, size: 36)
            Text(name)
                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onQR) {
                Image(systemName: "qrcode")
                    .font(Theme.Fonts.glyph(size: 18, weight: .regular))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct FriendRow: View {
    enum Kind { case bot, human }
    let kind: Kind
    let avatarSeed: String
    /// Uploaded avatar attachment id for human friends; ignored for bots.
    /// nil falls through UserAvatar to its deterministic emoji glyph keyed
    /// off `avatarSeed` (the peer's user id), so the same person reads
    /// consistently across the friend list / chat header / bubbles.
    var avatarAttachmentId: String? = nil
    let name: String
    /// The bot's stored model slug (`bots.model_id`). Resolved to a
    /// friendly name + price multiplier via `ModelCatalog`. nil for humans.
    let modelSlug: String?
    /// Drives the right-side tag pill for bots. `nil` for humans
    /// (which render a `人类` pill instead).
    let botVisibility: String?

    @EnvironmentObject private var catalog: ModelCatalog

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .bot:
                BotAvatar(seed: avatarSeed, size: 36)
            case .human:
                UserAvatar(seed: avatarSeed, attachmentId: avatarAttachmentId, size: 36)
            }

            // Name + (bot) inline model tag — same pill style as the
            // message list's model badge.
            HStack(spacing: 6) {
                Text(name)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if kind == .bot, let slug = modelSlug, !slug.isEmpty {
                    // Friendly model name + blended price multiplier.
                    // Muted ink fg + surface-muted bg, matching the
                    // message-list model tag.
                    HStack(spacing: 4) {
                        Text(catalog.displayName(for: slug))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let mult = catalog.priceMultiplier(for: slug) {
                            Text(ModelCatalog.formatMultiplier(mult))
                                .foregroundStyle(Theme.Palette.inkMuted.opacity(0.65))
                        }
                    }
                    .font(Theme.Fonts.rounded(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.Palette.surfaceMuted))
                }
            }

            Spacer(minLength: 8)

            // Right-side type tag. For bots the visibility decides the
            // copy + color (公有机器人 vs 私有机器人); humans always read 人类.
            switch kind {
            case .bot:
                BotVisibilityTag(visibility: botVisibility)
            case .human:
                HumanKindTag()
            }
        }
        .padding(.vertical, 4)
    }
}

/// One pending incoming friend request, with inline 同意 / 拒绝.
/// Avatar uses the peer's server-supplied avatar seed so the same person
/// reads consistently across the inbox row, the chat header, and bubbles
/// once the request is accepted.
private struct FriendRequestRow: View {
    let request: FriendsTabView.PendingFriendRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UserAvatar(seed: request.peerAvatarSeed, attachmentId: nil, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.peerDisplayName)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let msg = request.message, !msg.isEmpty {
                    Text(msg)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(2)
                } else {
                    Text("想加你为好友")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Text("拒绝")
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Palette.surfaceMuted))
                }
                .buttonStyle(.plain)
                Button(action: onAccept) {
                    Text("同意")
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Palette.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct GroupInvitationRow: View {
    let invitation: FriendsTabView.PendingGroupInvitation
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UserAvatar(seed: invitation.inviterAvatarSeed,
                       attachmentId: invitation.inviterAvatarPath,
                       size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(invitation.groupTitle)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text("\(invitation.inviterName) 邀请你入群")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                Text(invitation.billingText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Text("拒绝")
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Palette.surfaceMuted))
                }
                .buttonStyle(.plain)
                Button(action: onAccept) {
                    Text("同意")
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Palette.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HumanKindTag: View {
    var body: some View {
        Text("人类")
            .font(Theme.Fonts.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.Palette.accentBg))
    }
}

// MARK: - Sort

/// How the merged friend list is ordered. The direction (A→Z vs Z→A,
/// 旧→新 vs 新→旧) is a separate `sortAscending` flag so each field can be
/// flipped without multiplying the cases.
enum FriendSortField: String, CaseIterable {
    case name        // 名称 (pinyin-aware)
    case recentChat  // 最近聊天
    case addedTime   // 加好友时间

    var label: String {
        switch self {
        case .name:       return "名称"
        case .recentChat: return "最近聊天"
        case .addedTime:  return "加好友时间"
        }
    }

    var systemImage: String {
        switch self {
        case .name:       return "textformat"
        case .recentChat: return "bubble.left.and.bubble.right"
        case .addedTime:  return "person.badge.clock"
        }
    }

    /// Sensible default direction when the user first switches to this field:
    /// names read A→Z; time fields lead with the most recent.
    var defaultAscending: Bool {
        switch self {
        case .name:                  return true
        case .recentChat, .addedTime: return false
        }
    }

    /// Direction-aware label for the active row in the sort menu, so the user
    /// can see (and toggle) whether tapping again flips the order.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name:       return ascending ? "A→Z" : "Z→A"
        case .recentChat: return ascending ? "最早优先" : "最近优先"
        case .addedTime:  return ascending ? "最早添加" : "最近添加"
        }
    }
}

// MARK: - Filter pills

/// Five-way filter sitting between the self row and the friend list.
/// Each pill carries the colour of the tag it scopes to (人类 → accent
/// green, 私有机器人 → plum, 公有机器人 → amber, 群聊 → tri-tone gradient).
/// 全部 stays neutral white. All pills share the same frosted-glass
/// capsule treatment as the login screen's brand pills.
enum FriendFilter: Hashable, CaseIterable {
    case all, humans, privateBots, publicBots, groups

    var label: String {
        switch self {
        case .all:         return "全部"
        case .humans:      return "人类"
        case .privateBots: return "私有机器人"
        case .publicBots:  return "公有机器人"
        case .groups:      return "群聊"
        }
    }

    /// Foreground colour when the pill is selected (and used for the
    /// selected-state stroke). 全部 stays in plain ink.
    var fg: Color {
        switch self {
        case .all:         return Theme.Palette.ink
        case .humans:      return Theme.Palette.accent
        case .privateBots: return Theme.Palette.plum
        case .publicBots:  return Theme.Palette.amber
        case .groups:      return Theme.Palette.ink
        }
    }
}

private struct FilterPillBar: View {
    @Binding var filter: FriendFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FriendFilter.allCases, id: \.self) { f in
                    FilterPill(
                        filter: f,
                        selected: filter == f,
                        // 全部 选中时,其它 pill 也以满色亮起表示"都在显示",
                        // 但只有被点中的那一颗带 selection 描边。
                        active: filter == f || filter == .all
                    ) {
                        filter = f
                        Haptics.tap()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

private struct FilterPill: View {
    let filter: FriendFilter
    /// True only for the pill the user picked — drives the stroke ring.
    let selected: Bool
    /// True when this pill should render in its full-saturation tag colour.
    /// Always true for the selected pill; also true for siblings when 全部
    /// is the active filter (so the colour bar visually says "all on").
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.label)
                .font(Theme.Fonts.system(size: 12, weight: .semibold))
                .foregroundStyle(filter.fg.opacity(active ? 1.0 : 0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tintFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        selected ? filter.fg.opacity(0.5) : Color.black.opacity(0.05),
                        lineWidth: selected ? 1.0 : 0.6
                    )
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tintFill: some View {
        switch filter {
        case .all:
            // White stays neutral — slightly more opaque when picked
            // so the selection still reads against the canvas.
            Capsule().fill(Color.white.opacity(selected ? 0.85 : 0.4))
        case .humans:
            Capsule().fill(Theme.Palette.accentBg.opacity(active ? 1.0 : 0.4))
        case .privateBots:
            Capsule().fill(Theme.Palette.plumBg.opacity(active ? 1.0 : 0.4))
        case .publicBots:
            Capsule().fill(Theme.Palette.amberBg.opacity(active ? 1.0 : 0.4))
        case .groups:
            // Tri-tone wash: the three tag-bg colours blended L→R, kept
            // intentionally pale so it reads as "all categories" without
            // shouting over the others.
            let base = active ? 0.55 : 0.28
            Capsule().fill(
                LinearGradient(
                    colors: [
                        Theme.Palette.accentBg.opacity(base),
                        Theme.Palette.amberBg.opacity(base),
                        Theme.Palette.plumBg.opacity(base),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

// MARK: - Add friend (handle only, with preview)

/// 加好友 — two-page push flow. Page 1 is a bare number input; tapping
/// 查找 pushes Page 2, which renders the looked-up profile (avatar +
/// nickname) plus the optional 验证信息 textbox and the 发送申请 button.
/// The scan path opens this sheet with `prefilledHandle` set, which skips
/// Page 1 entirely and lands the user on Page 2's preview straight away.
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void = {}
    /// When non-empty, opens the sheet directly on the preview page with
    /// the lookup already in flight. Used by the scan flow so the user
    /// never sees the number-input step.
    var prefilledHandle: String = ""

    enum Route: Hashable { case preview(handle: String) }

    @State private var handleValue: String = ""
    @State private var path: [Route] = []
    @State private var lookupError: String?

    private var trimmedHandle: String {
        handleValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canLookup: Bool { trimmedHandle.count >= 4 }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("号码 / 隐私号", text: $handleValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { pushPreview() }
                        Button("查找") { pushPreview() }
                            .disabled(!canLookup)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                if let lookupError {
                    Section {
                        Text(lookupError).foregroundStyle(.red).font(Theme.Fonts.footnote)
                    }
                }
            }
            .navigationTitle("加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .preview(let handle):
                    AddFriendPreviewPage(
                        handle: handle,
                        onAdded: onAdded,
                        onFinished: { dismiss() }
                    )
                }
            }
            .onAppear {
                // Scan flow: skip Page 1 entirely and push straight to
                // the preview so the user lands on avatar + nickname +
                // 验证信息 without ever seeing the number input.
                if !prefilledHandle.isEmpty, path.isEmpty {
                    path.append(.preview(handle: prefilledHandle))
                }
            }
        }
    }

    private func pushPreview() {
        let value = trimmedHandle
        guard value.count >= 4 else { return }
        lookupError = nil
        path.append(.preview(handle: value))
    }
}

// MARK: - Add friend preview page (Page 2)

/// Pushed page that runs the handle lookup, renders the resolved
/// profile (avatar + nickname), and lets the sender attach an optional
/// 验证信息 before tapping 发送申请. Owns its own lookup + submit state;
/// the parent sheet only owns the handle string and the dismiss action.
private struct AddFriendPreviewPage: View {
    let handle: String
    var onAdded: () -> Void
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismissPage

    enum Preview: Equatable {
        case loading
        case loaded(userId: String, displayName: String, avatarPath: String?, avatarSeed: String)
        case notFound(message: String)
    }

    @State private var preview: Preview = .loading
    @State private var verifyMessage: String = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var successHint: String?

    private var canSubmit: Bool {
        if submitting { return false }
        if case .loaded = preview { return true }
        return false
    }

    var body: some View {
        Form {
            Section("对方") {
                previewRow
            }
            Section("验证信息（可选）") {
                TextField("给对方留个话,会和申请一起送达", text: $verifyMessage, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
            }
            if let successHint {
                Section {
                    Text(successHint).foregroundStyle(Theme.Palette.accent).font(Theme.Fonts.footnote)
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                }
            }
        }
        .navigationTitle("加好友")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("发送申请") { Task { await submit() } }
                    .disabled(!canSubmit)
            }
        }
        .task { await runLookup(value: handle) }
    }

    @ViewBuilder
    private var previewRow: some View {
        switch preview {
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在查找…").foregroundStyle(.secondary).font(Theme.Fonts.footnote)
            }
        case .loaded(let userId, let displayName, let avatarPath, let avatarSeed):
            HStack(spacing: 12) {
                UserAvatar(seed: avatarSeed, attachmentId: avatarPath, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.isEmpty ? String(userId.prefix(8)) : displayName)
                        .font(Theme.Fonts.body)
                    Text("可以添加为好友").foregroundStyle(.secondary).font(Theme.Fonts.footnote)
                }
            }
            .padding(.vertical, 2)
        case .notFound(let message):
            Text(message).foregroundStyle(.red).font(Theme.Fonts.footnote)
        }
    }

    private func runLookup(value: String) async {
        do {
            var comps = URLComponents(
                url: HostedConfig.environment.workerURL
                    .appendingPathComponent("v1/friend-requests/lookup"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [URLQueryItem(name: "handleValue", value: value)]
            var req = URLRequest(url: comps.url!)
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if Task.isCancelled { return }
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                preview = .notFound(message: "号码无效或已撤销")
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let msg = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                preview = .notFound(message: msg)
                return
            }
            struct LookupResp: Decodable {
                let userId: String
                let displayName: String
                let avatarPath: String?
                let avatarSeed: String?
            }
            let r = try JSONDecoder().decode(LookupResp.self, from: data)
            preview = .loaded(
                userId: r.userId,
                displayName: r.displayName,
                avatarPath: r.avatarPath,
                avatarSeed: r.avatarSeed ?? r.userId
            )
        } catch is CancellationError {
            // Page went away — drop result silently.
        } catch {
            preview = .notFound(message: error.localizedDescription)
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        error = nil
        successHint = nil
        do {
            var body: [String: Any] = ["handleValue": handle]
            let trimmedMessage = verifyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedMessage.isEmpty { body["message"] = trimmedMessage }

            let url = HostedConfig.environment.workerURL.appendingPathComponent("v1/friend-requests")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let msg = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                error = msg
                return
            }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if (payload?["alreadyContacts"] as? Bool) == true {
                successHint = "你们已经是好友了"
            } else if (payload?["autoAccepted"] as? Bool) == true {
                successHint = "对方此前也加过你 — 已直接成为好友"
            } else {
                successHint = "发过去了 等对方同意"
            }
            Haptics.success()
            onAdded()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            onFinished()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add bot sheet
//
// "加机器人" affordance — the bot-side counterpart of AddFriendSheet.
// Counterpart, not extension: real-friend lookup goes through the worker's
// /v1/friend-requests/lookup endpoint (because pendingbot.users RLS is
// self-only and the worker uses service-role to fetch peer profiles), but
// bots have their own visibility-aware RLS on the `bots` table that already
// returns exactly the rows the caller is allowed to see. So the bot path
// can stay client-only: direct supabase query for lookup, direct insert
// into user_bot_contacts on add. The RLS INSERT policy on
// user_bot_contacts replays the same visibility check, so a private bot
// the user discovers by guessing the slug still 0-rows on lookup; if the
// user somehow gets past lookup (cached slug, race), the insert fails with
// 42501 and we surface a friendly message.
//
// UX flow:
//   1) Page 1 — slug input + 查找 button.
//   2) Page 2 — preview card (display_name + visibility tag + model id),
//      "添加到联系人" button.
//   3) On success — sheet dismisses, FriendsTabView reloads, and the new
//      bot's chat opens automatically (mirrors "accept friend request →
//      open chat" for humans).

struct AddBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Caller wants the picked BotPick so it can optimistically prepend
    /// to the list and route into the bot's chat without waiting for the
    /// reload to land.
    var onAdded: (FriendsTabView.BotPick) -> Void = { _ in }
    /// When non-empty, opens the sheet directly on the preview page with
    /// the lookup already in flight. Used by the scan / universal-link
    /// flows so the user never sees the slug-input step.
    var prefilledSlug: String = ""

    enum Route: Hashable { case preview(slug: String) }

    @State private var slugInput: String = ""
    @State private var path: [Route] = []
    @State private var lookupError: String?

    private var trimmedSlug: String {
        slugInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    /// Bot slugs are unique text labels (see `bots.slug` UNIQUE). They're
    /// usually short (≥3 chars) — gate the lookup so we don't fire on the
    /// first keystroke.
    private var canLookup: Bool { trimmedSlug.count >= 2 }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("机器人标识(slug)", text: $slugInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { pushPreview() }
                        Button("查找") { pushPreview() }
                            .disabled(!canLookup)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                } footer: {
                    Text("机器人的 slug 由创建者设定,公开机器人才能被任意人加入。")
                }
                if let lookupError {
                    Section {
                        Text(lookupError).foregroundStyle(.red).font(Theme.Fonts.footnote)
                    }
                }
            }
            .navigationTitle("加机器人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .preview(let slug):
                    AddBotPreviewPage(
                        slug: slug,
                        onAdded: onAdded,
                        onFinished: { dismiss() }
                    )
                }
            }
            .onAppear {
                // Scan / universal-link flow: skip the slug-input page and
                // push straight to the preview, mirroring AddFriendSheet.
                if !prefilledSlug.isEmpty, path.isEmpty {
                    path.append(.preview(slug: BotShareLink.slug(fromScanned: prefilledSlug)))
                }
            }
        }
    }

    private func pushPreview() {
        let value = trimmedSlug
        guard value.count >= 2 else { return }
        lookupError = nil
        path.append(.preview(slug: value))
    }
}

// MARK: - Add bot preview page (Page 2)

private struct AddBotPreviewPage: View {
    let slug: String
    var onAdded: (FriendsTabView.BotPick) -> Void
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismissPage

    /// Mirrors AddFriendPreviewPage.Preview: loading / loaded / notFound.
    enum Preview: Equatable {
        case loading
        case loaded(bot: FriendsTabView.BotPick, slug: String?)
        case notFound(message: String)
    }

    @State private var preview: Preview = .loading
    @State private var submitting = false
    @State private var error: String?

    private var canSubmit: Bool {
        if submitting { return false }
        if case .loaded = preview { return true }
        return false
    }

    var body: some View {
        Form {
            Section("机器人") {
                previewRow
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                }
            }
        }
        .navigationTitle("加机器人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加") { Task { await submit() } }
                    .disabled(!canSubmit)
            }
        }
        .task { await runLookup() }
    }

    @ViewBuilder
    private var previewRow: some View {
        switch preview {
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在查找…").foregroundStyle(.secondary).font(Theme.Fonts.footnote)
            }
        case .loaded(let bot, let foundSlug):
            HStack(spacing: 12) {
                // Bots use id as the avatar seed (same as FriendRow does
                // in the friends list).
                UserAvatar(seed: bot.id, attachmentId: nil, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.display_name.isEmpty
                         ? (foundSlug ?? bot.id.prefix(8).description)
                         : bot.display_name)
                        .font(Theme.Fonts.body)
                    HStack(spacing: 6) {
                        if let v = bot.visibility {
                            Text(visibilityLabel(v))
                                .font(Theme.Fonts.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let m = bot.model_id, !m.isEmpty {
                            Text(m).font(Theme.Fonts.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        case .notFound(let message):
            Text(message).foregroundStyle(.red).font(Theme.Fonts.footnote)
        }
    }

    private func visibilityLabel(_ v: String) -> String {
        switch v {
        case "public_invite": return "公有"
        case "private":       return "私有"
        default:              return v
        }
    }

    private func runLookup() async {
        // Direct supabase query — RLS on `bots` already enforces visibility,
        // so a private bot the user doesn't own returns 0 rows here. That
        // gives us "not found" for both "doesn't exist" and "not allowed",
        // which is the right privacy default.
        struct BotRow: Decodable {
            let id: String
            let slug: String?
            let display_name: String
            let model_id: String?
            let visibility: String?
            let creator_id: String?
            let voice_call_enabled: Bool?
        }
        do {
            let rows: [BotRow] = try await SupabaseStack.shared
                .from("bots")
                .select("id, slug, display_name, model_id, visibility, creator_id, voice_call_enabled")
                .eq("slug", value: slug)
                .eq("is_active", value: true)
                .limit(1)
                .execute()
                .value
            if Task.isCancelled { return }
            guard let r = rows.first else {
                preview = .notFound(message: "找不到这个机器人,或者它不允许你加入。")
                return
            }
            let pick = FriendsTabView.BotPick(
                id: r.id,
                display_name: r.display_name,
                model_id: r.model_id,
                visibility: r.visibility,
                creator_id: r.creator_id,
                voice_call_enabled: r.voice_call_enabled
            )
            preview = .loaded(bot: pick, slug: r.slug)
        } catch is CancellationError {
            // Page went away — drop result silently.
        } catch {
            preview = .notFound(message: error.localizedDescription)
        }
    }

    private func submit() async {
        guard case .loaded(let bot, _) = preview else { return }
        guard let userId = AccountStore.shared.current?.id else {
            error = "请先登录"
            return
        }
        submitting = true
        defer { submitting = false }
        error = nil

        struct ContactInsert: Encodable {
            let user_id: String
            let bot_id: String
            let added_via: String
        }
        do {
            try await SupabaseStack.shared
                .from("user_bot_contacts")
                .insert(ContactInsert(
                    user_id: userId,
                    bot_id: bot.id,
                    added_via: "manual"
                ))
                .execute()
            Haptics.success()
            onAdded(bot)
            onFinished()
        } catch {
            let msg = error.localizedDescription
            // 23505 == unique_violation, i.e. already in contacts.
            // Treat as success — the user's intent ("add this bot") is
            // already satisfied; just open the chat.
            if msg.contains("23505") || msg.lowercased().contains("duplicate") {
                Haptics.success()
                onAdded(bot)
                onFinished()
                return
            }
            // 42501 == insufficient_privilege, which is what the RLS
            // policy raises if the bot isn't visible (would only happen
            // if the bot's visibility flipped between lookup and insert).
            if msg.contains("42501") || msg.lowercased().contains("permission") {
                self.error = "这个机器人不允许加为联系人。"
            } else {
                self.error = msg
            }
            Haptics.error()
        }
    }
}

// MARK: - Contact alias edit sheet

/// 设置备注 — pulled from the friend row's long-press menu. Empty value
/// clears the alias (the row reverts to displaying the contact's own
/// display_name). Posts to PATCH /v1/contacts/:contactUserId so the
/// change is symmetric with the WeChat-style "alias is local to me"
/// model: only the caller sees this label.
struct ContactAliasSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contact: FriendsTabView.HumanPick
    var onSaved: () -> Void = {}

    @State private var alias: String = ""
    @State private var saving: Bool = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(contact.displayName.isEmpty ? "起个备注" : "默认显示「\(contact.displayName)」",
                              text: $alias)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled()
                } header: {
                    Text("备注")
                } footer: {
                    Text("只有你能看到这个备注。留空则恢复对方自己的昵称。")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote) }
                }
            }
            .navigationTitle("设置备注")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { alias = contact.alias ?? "" }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        error = nil
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/")
                .appendingPathComponent(contact.id)
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Send `null` to clear, otherwise the trimmed string. Server
            // also accepts an empty string and treats it as null.
            let body: [String: Any] = trimmed.isEmpty
                ? ["alias": NSNull()]
                : ["alias": trimmed]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let msg = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                self.error = msg
                return
            }
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - QR display sheet

/// Wraps `MyQRBusinessCard` in a sheet-friendly nav stack with an
/// explicit close button. The button is the only way out on Mac
/// Catalyst (no swipe-to-dismiss there); on iPhone it sits alongside
/// the drag indicator, both work.
struct MyQRSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    MyQRBusinessCard()
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Bot row owner actions

/// Adds a long-press "管理" entry to bot rows the current user created.
/// Preset bots and others' bots get no extra actions — the modifier
/// returns the row unchanged.
private struct BotRowOwnerActions: ViewModifier {
    let bot: FriendsTabView.BotPick
    let isMine: Bool
    let onManage: () -> Void

    func body(content: Content) -> some View {
        if isMine {
            content.contextMenu {
                Button {
                    onManage()
                    Haptics.tap()
                } label: {
                    Label("管理", systemImage: "slider.horizontal.3")
                }
            }
        } else {
            content
        }
    }
}
#endif
