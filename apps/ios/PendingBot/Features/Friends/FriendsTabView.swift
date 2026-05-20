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
    @State private var loading = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var creatingBot = false
    @State private var managingBot: BotPick?
    @State private var aliasEditTarget: HumanPick?
    @State private var showingQR = false
    @State private var filter: FriendFilter = .all
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
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $addingFriend) {
            AddFriendSheet { Task { await load() } }
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
                PlusActionPopover(items: [
                    PlusActionItem(title: "加好友", systemImage: "person.badge.plus") {
                        addingFriend = true
                    },
                    PlusActionItem(title: "新建机器人", systemImage: "sparkles") {
                        creatingBot = true
                    },
                ])
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

    // MARK: - Data

    struct BotPick: Identifiable, Hashable {
        let id: String
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
        let voice_call_enabled: Bool?
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
    }

    private struct BotDecodable: Decodable {
        let id: String
        let slug: String?
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
        let voice_call_enabled: Bool?
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
                            voice_call_enabled: $0.voice_call_enabled)
                }
            }
            if !cachedContacts.isEmpty {
                self.humans = cachedContacts.map {
                    HumanPick(id: $0.id, alias: $0.alias,
                              displayName: $0.display_name,
                              avatarPath: $0.avatar_path,
                              avatarSeed: $0.avatar_seed ?? $0.id)
                }
            }
        }
        loading = true; defer { loading = false }
        do {
            async let botRowsResp: [BotDecodable] = SupabaseStack.shared
                .from("bots")
                .select("id, slug, display_name, model_id, visibility, creator_id, voice_call_enabled")
                .eq("is_active", value: true)
                .order("created_at", ascending: true)
                .execute()
                .value
            async let contactsResp: [HumanPick] = loadContactsWithProfiles()
            async let incomingFR: [PendingFriendRequest] = loadIncomingFriendRequests()

            let botRows = try await botRowsResp

            // Drop the per-user self-bot from the regular bot list — its
            // entry is the SelfRow pinned at the top of the friends tab,
            // and chatting with it via the bot path would skip the
            // self-chat materialiser (open_self_conv RPC) and the
            // user-memory swap in bot-reply.
            self.bots = botRows
                .filter { !($0.slug?.hasPrefix("self-") ?? false) }
                .map {
                    BotPick(id: $0.id, display_name: $0.display_name,
                            model_id: $0.model_id, visibility: $0.visibility,
                            creator_id: $0.creator_id,
                            voice_call_enabled: $0.voice_call_enabled)
                }
            // Persist bots wholesale on success — server is the source of
            // truth for which ones are still active / visible to us.
            LocalDatabase.shared.replaceBots(self.bots.map {
                LocalDatabase.BotRow(
                    id: $0.id, display_name: $0.display_name,
                    model_id: $0.model_id, visibility: $0.visibility,
                    creator_id: $0.creator_id,
                    voice_call_enabled: $0.voice_call_enabled
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
                        avatar_seed: $0.avatarSeed
                    )
                })
            } else {
                self.humans = []
            }
            self.pendingFriendRequests = (try? await incomingFR) ?? []
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
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw URLError(.badServerResponse) }
            Haptics.success()
        } catch {
            self.error = "处理好友申请失败: \(error.localizedDescription)"
            Haptics.error()
        }
        // Always refresh — accept also adds a row to user_contacts which
        // the friends list needs to pick up.
        await load()
    }

    // MARK: - Filtering

    /// Merged + alphabetically-sorted friend list for the current filter.
    /// Bots and humans share one section so the sort can interleave them;
    /// `localizedStandardCompare` handles pinyin for Chinese names and is
    /// case-insensitive for ASCII.
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
        return items.sorted {
            $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending
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
            last_message_sender_type: nil,
            model_override: nil,
            provider_override: nil
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
                    .font(.system(size: 18, weight: .regular))
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Palette.surfaceMuted))
                }
                .buttonStyle(.plain)
                Button(action: onAccept) {
                    Text("同意")
                        .font(.system(size: 13, weight: .semibold))
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
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.Palette.accentBg))
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
                .font(.system(size: 12, weight: .semibold))
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

/// 加好友 page — handle-only entry. The user types a number, hits the
/// 查找 button, and we look up the matching profile (avatar + nickname
/// only — by design, no email or other PII surfaces here). After the
/// preview confirms it's the right person, the sender can attach an
/// optional 验证信息 that the recipient sees alongside the request
/// (WeChat-style); the alias for *the sender's own contact list* is
/// set separately from the friend row after acceptance.
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void = {}
    /// When non-empty, the sheet opens with the field pre-filled and
    /// kicks off the preview lookup immediately. Used by the scan flow
    /// to land on the same review page (avatar + nickname + 验证信息)
    /// without making the user re-type the handle.
    var prefilledHandle: String = ""

    /// Preview state for the looked-up profile. `idle` is the initial /
    /// post-edit state (user changed input → preview cleared, must tap
    /// 查找 again). `loading` shows the spinner during the round-trip.
    enum Preview: Equatable {
        case idle
        case loading
        case loaded(userId: String, displayName: String, avatarPath: String?, avatarSeed: String)
        case notFound(message: String)
    }

    @State private var handleValue: String = ""
    @State private var verifyMessage: String = ""
    @State private var preview: Preview = .idle
    @State private var lookupTask: Task<Void, Never>?
    @State private var lastLookupAt: Date = .distantPast
    @State private var submitting = false
    @State private var error: String?
    @State private var successHint: String?

    private var trimmedHandle: String {
        handleValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canLookup: Bool {
        if case .loading = preview { return false }
        return trimmedHandle.count >= 4
    }

    /// Send is only meaningful once we have a confirmed match. Disables
    /// the button on partial input, lookup-in-flight, and not-found, so
    /// the user can't fire a request that the worker would just reject.
    private var canSubmit: Bool {
        if submitting { return false }
        if case .loaded = preview { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("号码 / 隐私号", text: $handleValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            // Clear stale preview whenever the user edits
                            // the field — they must tap 查找 again to re-
                            // confirm. Keeps "submit" disabled until the
                            // preview matches what's in the text field.
                            .onChange(of: handleValue) { _, _ in
                                if case .loading = preview { return }
                                if case .idle = preview { return }
                                preview = .idle
                            }
                            .onSubmit { Task { await runLookupTapped() } }
                        Button("查找") { Task { await runLookupTapped() } }
                            .disabled(!canLookup)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                } footer: {
                    Text("只能用号码（ID/隐私号）添加,不支持邮箱。输入后点「查找」确认对方。")
                }

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
                        Text(successHint).foregroundStyle(Theme.Palette.accent).font(.footnote)
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发送申请") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
            .onAppear {
                // Scan-then-preview: caller hands the decoded handle in
                // and we kick off the lookup automatically so the user
                // lands on the avatar+nickname review page right away.
                if !prefilledHandle.isEmpty, handleValue.isEmpty {
                    handleValue = prefilledHandle
                    Task { await runLookupTapped() }
                }
            }
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        switch preview {
        case .idle:
            Text("输入号码后会显示对方的头像和昵称")
                .foregroundStyle(.secondary)
                .font(.footnote)
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在查找…").foregroundStyle(.secondary).font(.footnote)
            }
        case .loaded(let userId, let displayName, let avatarPath, let avatarSeed):
            HStack(spacing: 12) {
                UserAvatar(seed: avatarSeed, attachmentId: avatarPath, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.isEmpty ? String(userId.prefix(8)) : displayName)
                        .font(.body)
                    Text("可以添加为好友").foregroundStyle(.secondary).font(.footnote)
                }
            }
            .padding(.vertical, 2)
        case .notFound(let message):
            Text(message).foregroundStyle(.red).font(.footnote)
        }
    }

    /// Explicit lookup fired by the 查找 button / keyboard submit. Trips
    /// a soft client-side rate limit (1.5s between calls) so a wrist-spasm
    /// double-tap doesn't double-fire; further server-side throttling lives
    /// behind the auth gate.
    private func runLookupTapped() async {
        let value = trimmedHandle
        guard value.count >= 4 else { return }
        let now = Date()
        if now.timeIntervalSince(lastLookupAt) < 1.5 { return }
        lastLookupAt = now
        lookupTask?.cancel()
        preview = .loading
        let task = Task { await runLookup(value: value) }
        lookupTask = task
        await task.value
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
            // User kept typing — drop the result silently.
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
            var body: [String: Any] = ["handleValue": trimmedHandle]
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
            dismiss()
        } catch {
            self.error = error.localizedDescription
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
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
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
