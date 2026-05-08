import SwiftUI
import Supabase

/// 好友 tab — sectioned contact list (机器人朋友 / 真人朋友), no nav title.
/// Filter chips above the list narrow to one section; each row carries
/// an AI / 人类 tag on the far right.
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
    @State private var loading = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var creatingBot = false
    @State private var managingBot: BotPick?
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
                .presentationDetents([.medium])
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
                .presentationDetents([.medium, .large])
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
                        bot: nil,
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
                    bot: nil,
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
                Menu {
                    Button {
                        addingFriend = true
                        Haptics.tap()
                    } label: {
                        Label("加好友", systemImage: "person.badge.plus")
                    }
                    Button {
                        creatingBot = true
                        Haptics.tap()
                    } label: {
                        Label("新建机器人", systemImage: "sparkles")
                    }
                } label: {
                    CirclePlusButton()
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

                    if !botsForFilter.isEmpty {
                        Section {
                            ForEach(botsForFilter) { bot in
                                let selected = sidebarLayout && isSelected(kind: "bot", id: bot.id)
                                FriendRow(kind: .bot,
                                          avatarSeed: bot.id,
                                          name: bot.display_name,
                                          modelTag: bot.modelTag,
                                          botVisibility: bot.visibility)
                                    .listRowBackground(selected ? Theme.Palette.accentBg : Theme.Palette.surface)
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await tapBot(bot) } }
                                    .modifier(BotRowOwnerActions(
                                        bot: bot,
                                        isMine: ownsBot(bot),
                                        onManage: { managingBot = bot }
                                    ))
                            }
                        }
                    }
                    if !humansForFilter.isEmpty {
                        Section {
                            ForEach(humansForFilter) { c in
                                let selected = sidebarLayout && isSelected(kind: "user", id: c.id)
                                FriendRow(kind: .human,
                                          avatarSeed: c.id,
                                          name: c.alias ?? String(c.id.prefix(8)),
                                          modelTag: nil,
                                          botVisibility: nil)
                                    .listRowBackground(selected ? Theme.Palette.accentBg : Theme.Palette.surface)
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await tapHuman(c) } }
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
        var modelTag: String? {
            guard let m = model_id, let i = m.lastIndex(of: "/") else { return model_id }
            return String(m[m.index(after: i)...])
        }
    }
    struct HumanPick: Identifiable, Hashable {
        let id: String
        let alias: String?
    }

    private struct BotDecodable: Decodable {
        let id: String
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
    }
    private struct ContactDecodable: Decodable {
        let contact_user_id: String
        let alias: String?
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            async let botRowsResp: [BotDecodable] = SupabaseStack.shared
                .from("bots")
                .select("id, display_name, model_id, visibility, creator_id")
                .eq("is_active", value: true)
                .order("created_at", ascending: true)
                .execute()
                .value
            async let contactRowsResp: [ContactDecodable] = SupabaseStack.shared
                .from("user_contacts")
                .select("contact_user_id, alias")
                .order("created_at", ascending: true)
                .execute()
                .value

            let botRows = try await botRowsResp
            let contactRows = try await contactRowsResp

            self.bots = botRows.map {
                BotPick(id: $0.id, display_name: $0.display_name,
                        model_id: $0.model_id, visibility: $0.visibility,
                        creator_id: $0.creator_id)
            }
            self.humans = contactRows.map { HumanPick(id: $0.contact_user_id, alias: $0.alias) }
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

    // MARK: - Filtering

    private var botsForFilter: [BotPick] {
        switch filter {
        case .all:         return bots
        case .privateBots: return bots.filter { $0.visibility == "private" }
        case .publicBots:  return bots.filter { $0.visibility != "private" }
        case .humans, .groups: return []
        }
    }

    private var humansForFilter: [HumanPick] {
        switch filter {
        case .all, .humans: return humans
        case .privateBots, .publicBots, .groups: return []
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
            return humans.isEmpty ? "还没有人类朋友" : nil
        case .privateBots:
            return botsForFilter.isEmpty ? "还没有私有机器人" : nil
        case .publicBots:
            return botsForFilter.isEmpty ? "还没有公有机器人" : nil
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
        open(PendingPeer(kind: "bot",
                         peerId: bot.id,
                         displayName: bot.display_name))
    }

    /// Push a "chat with self" conv. Materialises server-side via the
    /// dedicated open_self_conv RPC (see migration 0018) which seeds
    /// the user's bio as the bot's persona.
    private func tapSelf() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let displayName = AccountStore.shared.profileDisplayName
            ?? AccountStore.shared.current?.displayName ?? "你"
        open(PendingPeer(kind: "self",
                         peerId: userId,
                         displayName: displayName))
    }

    private func tapHuman(_ c: HumanPick) async {
        open(PendingPeer(kind: "user",
                         peerId: c.id,
                         displayName: c.alias ?? String(c.id.prefix(8))))
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
    let name: String
    let modelTag: String?
    /// Drives the right-side tag pill for bots. `nil` for humans
    /// (which render a `人类` pill instead).
    let botVisibility: String?

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .bot:
                BotAvatar(seed: avatarSeed, size: 36)
            case .human:
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                    .frame(width: 36, height: 36)
            }

            // Name + (bot) inline model tag — same pill style as the
            // message list's model badge.
            HStack(spacing: 6) {
                Text(name)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if kind == .bot, let tag = modelTag {
                    // Match message-list model tag: muted ink fg + surface
                    // muted bg, not the accent green.
                    Text(tag)
                        .font(Theme.Fonts.rounded(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.Palette.surfaceMuted))
                        .lineLimit(1)
                        .truncationMode(.middle)
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

// MARK: - Add friend (handle / email)

struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void = {}

    enum Mode: String, CaseIterable, Identifiable {
        case handle = "号码"
        case email = "邮箱"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .handle
    @State private var handleValue: String = ""
    @State private var email: String = ""
    @State private var alias: String = ""
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("方式", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)

                Section {
                    if mode == .handle {
                        TextField("号码 / QR 解码后的串", text: $handleValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField("对方的注册邮箱", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                    }
                    TextField("备注名（可选）", text: $alias)
                }

                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("加") { Task { await submit() } }
                        .disabled(submitting || (mode == .handle ? handleValue.isEmpty : email.isEmpty))
                }
            }
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        error = nil
        do {
            var body: [String: Any] = [:]
            if mode == .handle { body["handleValue"] = handleValue.trimmingCharacters(in: .whitespaces) }
            else { body["email"] = email.trimmingCharacters(in: .whitespaces) }
            let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
            if !trimmedAlias.isEmpty { body["alias"] = trimmedAlias }

            let url = HostedConfig.environment.workerURL.appendingPathComponent("v1/contacts/add")
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
            Haptics.success()
            onAdded()
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
                        .padding(.vertical, 28)
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

