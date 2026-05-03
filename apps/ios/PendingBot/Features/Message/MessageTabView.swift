import SwiftUI
import Supabase
import OSLog

private let log = Logger.category("conv-list")

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
    @EnvironmentObject private var unread: UnreadStore
    @State private var conversations: [Conversation] = []
    @State private var bots: [Bot] = []
    @State private var loading = false
    @State private var error: String?
    @State private var creatingForBot: Bot?
    @State private var creatingGroup = false
    @State private var addingFriend = false
    @State private var scanning = false
    // Path-based nav for compact: keyed to .toolbar(.hidden, for: .tabBar)
    // so the bottom tab bar slides out alongside the push transition (rather
    // than snapping back in *after* the back transition finishes, which is
    // what we'd get if the modifier lived on the destination view).
    @State private var path: [Conversation] = []
    // Selection-driven detail for regular size class.
    @State private var selected: Conversation?

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
        .alert("出错了", isPresented: .constant(error != nil), actions: {
            Button("好") { error = nil }
        }, message: { Text(error ?? "") })
        .sheet(isPresented: $creatingGroup) {
            CreateGroupSheet { _ in Task { await load() } }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $addingFriend) {
            AddFriendSheet { Task { await load() } }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $scanning) {
            ScanQRSheet { Task { await load() } }
        }
    }

    // ── Compact (iPhone) ────────────────────────────────────────────────────

    private var compactBody: some View {
        NavigationStack(path: $path) {
            sidebarBody
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Conversation.self) { conv in
                    ConversationView(conversation: conv, bot: bot(for: conv)) {
                        reload()
                    }
                    .onAppear { unread.markRead(conv.id) }
                }
        }
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
    }

    // ── Regular (iPad landscape, Mac Catalyst) ──────────────────────────────

    private var regularBody: some View {
        NavigationSplitView {
            sidebarBody
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sidebarColumnWidth()
        } detail: {
            if let conv = selected {
                ConversationView(conversation: conv, bot: bot(for: conv)) {
                    reload()
                }
                // .id forces a fresh ConversationView (and a fresh WS) when
                // the user picks a different row — without it the existing
                // view would just rebind, leaking the prior chat's state.
                .id(conv.id)
                .onAppear { unread.markRead(conv.id) }
            } else {
                EmptyDetailHint(text: "选一条对话开始", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    // ── Sidebar (shared) ────────────────────────────────────────────────────

    private var sidebarBody: some View {
        VStack(spacing: 0) {
            TabHeaderBar(title: "消息") {
                Menu {
                    Button { addingFriend = true; Haptics.tap() } label: {
                        Label("加好友", systemImage: "person.badge.plus")
                    }
                    Button { creatingGroup = true; Haptics.tap() } label: {
                        Label("拉群", systemImage: "person.3")
                    }
                    Button { scanning = true; Haptics.tap() } label: {
                        Label("扫码", systemImage: "qrcode.viewfinder")
                    }
                } label: {
                    CirclePlusButton()
                }
            }
            Group {
                if loading && conversations.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversations.isEmpty {
                    EmptyHint(text: "和 AI 聊天")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(conversations) { conv in
                                SwipeRevealRow(actions: [
                                    SwipeRevealAction(
                                        systemImage: "envelope.badge",
                                        tint: Color(red: 0.42, green: 0.62, blue: 0.92)
                                    ) {
                                        unread.markUnread(conv.id)
                                    },
                                    SwipeRevealAction(
                                        systemImage: "trash",
                                        tint: Color(red: 0.93, green: 0.50, blue: 0.50)
                                    ) {
                                        Task { await delete(conv) }
                                    },
                                ]) {
                                    rowTap(conv)
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
                    .refreshable { await load() }
                }
            }
        }
    }

    @ViewBuilder
    private func rowTap(_ conv: Conversation) -> some View {
        let row = ConversationListRow(
            conv: conv,
            bot: bot(for: conv),
            isUnread: unread.isUnread(conv.id),
            isSelected: sidebarLayout && selected?.id == conv.id
        )
        if sidebarLayout {
            Button {
                selected = conv
                Haptics.tap()
            } label: { row }
            .buttonStyle(StaticButtonStyle())
        } else {
            NavigationLink(value: conv) { row }
                .buttonStyle(StaticButtonStyle())
        }
    }

    private func bot(for conv: Conversation) -> Bot? {
        bots.first { $0.id == conv.bot_id }
    }

    private func reload() { Task { await load() } }

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
                    last_message_sender_type: row.last_message_sender_type,
                    model_override: nil
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
                .select("id, display_name, model_id, visibility, creator_id")
                .eq("is_active", value: true)
                .execute()
                .value
            // user_unread_counts has a row per (user, conv) only after the
            // conv received its first message. Joining it INNER is the
            // empty-conv filter (item: 如果会话内消息是空的就不要出现).
            async let convRows: [ConvRow] = SupabaseStack.shared
                .from("conversations")
                .select("""
                    id, bot_id, user_id, title, conversation_type, feature, round_count, updated_at,
                    bot:bots(display_name, model_id, visibility, creator_id),
                    unread:user_unread_counts(last_message_at, last_message_preview, unread_count)
                """)
                .order("updated_at", ascending: false)
                // Tie-break: ascending id so the order is deterministic when
                // multiple convs share an updated_at timestamp (e.g. all
                // bootstrapped at the same instant for a fresh user).
                .order("id", ascending: true)
                .execute()
                .value

            self.bots = try await botRows.map(\.asBot)
            // Sort client-side too — the local cache hydrate above and any
            // future Realtime patch can interleave; keep the visible order
            // (newest first, then ascending id on ties) consistent.
            let fresh = try await convRows.map(\.asConversation).sorted { l, r in
                if l.last_activity_at != r.last_activity_at {
                    return l.last_activity_at > r.last_activity_at
                }
                return l.id < r.id
            }
            self.conversations = fresh
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
        } catch is CancellationError {
            // navigation / refreshable cancellation — silent
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled {
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
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
        var asBot: Bot {
            Bot(
                id: id, display_name: display_name,
                access_mode: nil, model: model_id,
                default_model: model_id, user_model: nil,
                visibility: visibility, creator_id: creator_id
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
        struct BotJoin: Decodable {
            let display_name: String?
            let model_id: String?
            let visibility: String?
            let creator_id: String?
        }
        struct UnreadJoin: Decodable {
            let last_message_at: String?
            let last_message_preview: String?
            let unread_count: Int?
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
                model_override: nil
            )
        }
    }

    private func createConversation(with bot: Bot) async {
        guard let userId = AccountStore.shared.current?.id else { return }
        do {
            // Schema requires user as participant for RLS to grant subsequent
            // reads of the conversation row, so we INSERT both the conv and
            // the participant set in sequence with the service-side default
            // schema (pendingbot).
            struct ConvInsert: Encodable {
                let conversation_type = "user_bot"
                let feature = "message"
                let user_id: String
                let bot_id: String
                let title: String?
            }
            struct ConvOut: Decodable { let id: String }
            let inserted: ConvOut = try await SupabaseStack.shared
                .from("conversations")
                .insert(ConvInsert(user_id: userId, bot_id: bot.id, title: nil))
                .select("id")
                .single()
                .execute()
                .value

            struct Participant: Encodable {
                let conversation_id: String
                let participant_type: String
                let participant_id: String
                let role: String
            }
            try await SupabaseStack.shared
                .from("conversation_participants")
                .insert([
                    Participant(conversation_id: inserted.id,
                                participant_type: "user",
                                participant_id: userId,
                                role: "owner"),
                    Participant(conversation_id: inserted.id,
                                participant_type: "bot",
                                participant_id: bot.id,
                                role: "member"),
                ])
                .execute()

            // Optimistic local insert; next pull-to-refresh re-reads canonically.
            conversations.insert(Conversation(
                id: inserted.id,
                bot_id: bot.id,
                user_id: userId,
                title: nil,
                feature_type: "message",
                conversation_type: "user_bot",
                last_activity_at: Int(Date().timeIntervalSince1970),
                round_count: 0,
                bot_name: bot.display_name,
                last_message_content: nil,
                last_message_sender_type: nil,
                model_override: nil
            ), at: 0)
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
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

private struct ConversationListRow: View {
    let conv: Conversation
    let bot: Bot?
    let isUnread: Bool
    /// True only in the regular-size sidebar layout when this row's
    /// conversation is the one currently shown in the detail pane.
    /// Drives a tinted background so the user can see what's selected
    /// (compact mode pushes a new screen, so it never needs this).
    var isSelected: Bool = false

    // Bot name pill. Falls back to the joined `bot_name` from the
    // conversation row if we haven't loaded the live bot record yet.
    private var primaryName: String {
        // Never fall through to the raw uuid. Until the bot list lands or
        // the cache hydrate carries a name, just show the conv title (or
        // an em-dash placeholder) — the long green ID badge was an
        // eyesore on first paint.
        if let n = bot?.display_name, !n.isEmpty { return n }
        if let n = conv.bot_name, !n.isEmpty { return n }
        if let t = conv.title, !t.isEmpty { return t }
        return "—"
    }
    private var isHumanConv: Bool { conv.conversation_type == "user_user" }

    /// Pill colors for the name tag carry the bot type now that the
    /// dedicated 公/私 tag is gone: green = human, plum = private bot,
    /// amber = public bot.
    private var nameTagColors: (fg: Color, bg: Color) {
        if isHumanConv { return (Theme.Palette.accent, Theme.Palette.accentBg) }
        if bot?.visibility == "private" { return (Theme.Palette.plum, Theme.Palette.plumBg) }
        return (Theme.Palette.amber, Theme.Palette.amberBg)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Emoji stays per-bot so the same bot looks recognisable
            // across all your chats with it; tint varies per conv.
            BotAvatar(
                emojiSeed: conv.bot_id.isEmpty ? conv.id : conv.bot_id,
                colorSeed: conv.id,
                size: 36
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isUnread {
                        Circle().fill(Theme.Palette.accent).frame(width: 7, height: 7)
                    }
                    Text(conv.title?.isEmpty == false ? conv.title! : "新对话")
                        .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                        .foregroundStyle(
                            conv.title?.isEmpty == false
                            ? Theme.Palette.ink
                            : Theme.Palette.inkMuted
                        )
                        .lineLimit(1)
                    if let badge = ConvTypeBadge(forType: conv.conversation_type) {
                        badge
                    }
                    Spacer(minLength: 8)
                    if conv.last_activity_at > 0 {
                        Text(Date(timeIntervalSince1970: TimeInterval(conv.last_activity_at)),
                             format: .relative(presentation: .numeric))
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
                    Text(primaryName)
                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                        .foregroundStyle(nameTagColors.fg)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(nameTagColors.bg))
                        .lineLimit(1)
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
}

// MARK: - Conv-type badge

/// Compact pill rendered next to a list-row title to call out non-1:1
/// conversation types. Returns nil for `user_bot` since that's the
/// default and doesn't need a label.
private struct ConvTypeBadge: View {
    let text: String
    let fg: Color
    let bg: Color
    init?(forType type: String?) {
        switch type {
        case "group":
            self.text = "群"
            self.fg = Color(hex: 0x1F4F8A)
            self.bg = Color(hex: 0xE6EEF8)
        case "user_user":
            self.text = "私聊"
            self.fg = Color(hex: 0x2E5C3D)
            self.bg = Color(hex: 0xE3EEEA)
        default:
            return nil
        }
    }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

// MARK: - 扫码 sheet (real camera scanner)

/// Camera-backed QR scanner. First valid QR detection fires
/// /v1/contacts/add with handleValue=<scanned> and dismisses.
private struct ScanQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void = {}

    @State private var scannedValue: String?
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if scannedValue == nil {
                    QRScannerView { value in
                        scannedValue = value
                        Haptics.tap()
                        Task { await submit(value: value) }
                    } onError: { err in
                        error = err.localizedDescription
                    }
                    .ignoresSafeArea()
                    VStack {
                        Spacer()
                        Text("把对方的二维码对准相机")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .padding(.bottom, 40)
                    }
                } else if submitting {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).controlSize(.large)
                        Text("加好友中...")
                            .foregroundStyle(.white)
                    }
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
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
    }

    private func submit(value: String) async {
        submitting = true
        defer { submitting = false }
        do {
            let url = HostedConfig.environment.workerURL.appendingPathComponent("v1/contacts/add")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["handleValue": value])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                error = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
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

// MARK: - Create group sheet

/// Group chat creation. Caller picks 0..N bots + 0..N human friends and a
/// title, plus is automatically added as owner. Mixed bot+human groups
/// are allowed.
private struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void

    struct BotPick: Identifiable, Hashable {
        let id: String
        let name: String
        let model_id: String?
    }
    struct HumanPick: Identifiable, Hashable {
        let id: String
        let name: String
    }
    private struct BotDecodable: Decodable { let id: String; let display_name: String; let model_id: String? }
    private struct ContactDecodable: Decodable { let contact_user_id: String; let alias: String? }

    @State private var title = ""
    @State private var bots: [BotPick] = []
    @State private var humans: [HumanPick] = []
    @State private var selectedBots = Set<String>()
    @State private var selectedHumans = Set<String>()
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("群名") {
                    TextField("起个名字", text: $title)
                }
                Section("机器人成员") {
                    if bots.isEmpty {
                        Text("没有可选机器人").foregroundStyle(.secondary)
                    }
                    ForEach(bots) { b in
                        memberRow(name: b.name,
                                  subtitle: b.model_id,
                                  selected: selectedBots.contains(b.id)) {
                            toggle(set: &selectedBots, id: b.id)
                        }
                    }
                }
                Section("真人成员") {
                    if humans.isEmpty {
                        Text("还没有真人朋友").foregroundStyle(.secondary)
                    }
                    ForEach(humans) { h in
                        memberRow(name: h.name,
                                  subtitle: nil,
                                  selected: selectedHumans.contains(h.id)) {
                            toggle(set: &selectedHumans, id: h.id)
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("发起群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") { Task { await create() } }
                        .disabled(creating || title.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (selectedBots.isEmpty && selectedHumans.isEmpty))
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func memberRow(name: String, subtitle: String?, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.inkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(Theme.Palette.ink)
                    if let s = subtitle {
                        Text(s).font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func toggle(set: inout Set<String>, id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        Haptics.tap()
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            async let botRowsResp: [BotDecodable] = SupabaseStack.shared
                .from("bots")
                .select("id, display_name, model_id")
                .eq("is_active", value: true)
                .execute()
                .value
            async let contactRowsResp: [ContactDecodable] = SupabaseStack.shared
                .from("user_contacts")
                .select("contact_user_id, alias")
                .execute()
                .value
            let botRows = try await botRowsResp
            let humanRows = try await contactRowsResp
            self.bots = botRows.map { BotPick(id: $0.id, name: $0.display_name, model_id: $0.model_id) }
            self.humans = humanRows.map { HumanPick(id: $0.contact_user_id, name: $0.alias ?? String($0.contact_user_id.prefix(8))) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        creating = true; defer { creating = false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        do {
            struct ConvInsert: Encodable {
                let conversation_type = "group"
                let feature = "message"
                let user_id: String
                let title: String
            }
            struct Inserted: Decodable { let id: String }
            let inserted: Inserted = try await SupabaseStack.shared
                .from("conversations")
                .insert(ConvInsert(user_id: userId, title: trimmedTitle))
                .select("id")
                .single()
                .execute()
                .value

            struct Participant: Encodable {
                let conversation_id: String
                let participant_type: String
                let participant_id: String
                let role: String
            }
            var rows: [Participant] = [
                Participant(conversation_id: inserted.id,
                            participant_type: "user",
                            participant_id: userId,
                            role: "owner"),
            ]
            for bid in selectedBots {
                rows.append(Participant(conversation_id: inserted.id,
                                        participant_type: "bot",
                                        participant_id: bid,
                                        role: "member"))
            }
            for uid in selectedHumans {
                rows.append(Participant(conversation_id: inserted.id,
                                        participant_type: "user",
                                        participant_id: uid,
                                        role: "member"))
            }
            try await SupabaseStack.shared
                .from("conversation_participants")
                .insert(rows)
                .execute()
            Haptics.success()
            onCreated(inserted.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
