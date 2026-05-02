import SwiftUI
import Supabase

/// 好友 tab — unified contact list (bots + humans), no section headers.
/// Each row shows the friend's name with an AI / 人类 tag; the row's
/// font matches the message-list row in MessageTabView so the two tabs
/// feel consistent.
///
/// Sort: most recent interaction desc, then name a-z. Filter chips at the
/// top let the user narrow to only humans or only bots; both off = full
/// list.
///
/// Tap behavior (per user spec):
///   - bot:   create a fresh user_bot conversation and push into it
///            (each tap is a new conv on purpose; existing convs stay
///            in 消息 list)
///   - human: find-or-create the singleton user_user conv with that
///            person and push into it
///
/// Group chats are NOT here — they live in the message list. Group
/// creation is the + button on the message tab.
struct FriendsTabView: View {
    @EnvironmentObject private var store: AccountStore

    @State private var friends: [Friend] = []
    @State private var loading = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var managingHandles = false
    @State private var humansOnly = false
    @State private var botsOnly = false
    @State private var path: [Conversation] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterBar
                    List {
                        ForEach(visibleFriends) { f in
                            FriendRow(friend: f)
                                .listRowBackground(Theme.Palette.surface)
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await openChat(f) } }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        managingHandles = true
                        Haptics.tap()
                    } label: { Image(systemName: "qrcode") }
                    .foregroundStyle(Theme.Palette.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingFriend = true
                        Haptics.tap()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar) // no "好友" title strip
            .sheet(isPresented: $addingFriend) {
                AddFriendSheet { Task { await load() } }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $managingHandles) {
                MyHandlesSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(for: Conversation.self) { conv in
                ConversationView(conversation: conv, bot: nil)
            }
        }
        .task { await load() }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: - Filter chips

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip(text: "仅人类", on: humansOnly) {
                humansOnly.toggle()
                if humansOnly { botsOnly = false }
            }
            FilterChip(text: "仅机器人", on: botsOnly) {
                botsOnly.toggle()
                if botsOnly { humansOnly = false }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 10)
        .background(Theme.Palette.canvas)
    }

    private var visibleFriends: [Friend] {
        friends.filter { f in
            if humansOnly { return f.kind == .human }
            if botsOnly { return f.kind == .bot }
            return true
        }
    }

    // MARK: - Data

    enum FriendKind: Equatable { case bot, human }

    struct Friend: Identifiable, Hashable {
        let id: String                  // bot id or contact user id
        let kind: FriendKind
        let name: String
        let subtitle: String?           // model tag for bots, email/handle note for humans
        let lastInteractedAt: Int       // epoch seconds (0 if never)
        let modelId: String?            // bots only
        static func == (a: Friend, b: Friend) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private struct BotDecodable: Decodable {
        let id: String
        let display_name: String
        let model_id: String?
    }
    private struct ConvDecodable: Decodable {
        let bot_id: String?
        let updated_at: String?
    }
    private struct ContactDecodable: Decodable {
        let contact_user_id: String
        let alias: String?
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            async let botRowsResp: [BotDecodable] = SupabaseStack.shared.database
                .from("bots")
                .select("id, display_name, model_id")
                .eq("is_active", value: true)
                .execute()
                .value
            // For "most recent interaction" — pull the user's user_bot
            // convs and pluck max(updated_at) per bot_id locally.
            async let convRowsResp: [ConvDecodable] = SupabaseStack.shared.database
                .from("conversations")
                .select("bot_id, updated_at")
                .eq("conversation_type", value: "user_bot")
                .execute()
                .value
            async let contactRowsResp: [ContactDecodable] = SupabaseStack.shared.database
                .from("user_contacts")
                .select("contact_user_id, alias")
                .execute()
                .value

            let botRows = try await botRowsResp
            let convRows = try await convRowsResp
            let contactRows = try await contactRowsResp

            let fmt = ISO8601DateFormatter()
            var lastByBot: [String: Int] = [:]
            for c in convRows {
                guard let bid = c.bot_id, let s = c.updated_at,
                      let d = fmt.date(from: s) else { continue }
                let secs = Int(d.timeIntervalSince1970)
                if secs > (lastByBot[bid] ?? 0) { lastByBot[bid] = secs }
            }

            let botFriends: [Friend] = botRows.map { b in
                Friend(
                    id: b.id, kind: .bot,
                    name: b.display_name,
                    subtitle: b.model_id.map(shortSlug),
                    lastInteractedAt: lastByBot[b.id] ?? 0,
                    modelId: b.model_id
                )
            }
            // No per-human "last interaction" yet — would need to look up
            // the user_user conv's updated_at. For MVP, sort humans by
            // alias only (lastInteractedAt = 0 → falls into name tiebreak).
            let humanFriends: [Friend] = contactRows.map { c in
                Friend(
                    id: c.contact_user_id, kind: .human,
                    name: c.alias ?? String(c.contact_user_id.prefix(8)),
                    subtitle: nil,
                    lastInteractedAt: 0,
                    modelId: nil
                )
            }

            self.friends = (botFriends + humanFriends).sorted { lhs, rhs in
                if lhs.lastInteractedAt != rhs.lastInteractedAt {
                    return lhs.lastInteractedAt > rhs.lastInteractedAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Open chat

    private func openChat(_ f: Friend) async {
        guard let userId = AccountStore.shared.current?.id else { return }
        do {
            switch f.kind {
            case .bot:
                let conv = try await createUserBotConv(botId: f.id, botName: f.name, userId: userId)
                path.append(conv)
            case .human:
                let convId = try await openOrCreateUserUserConv(contactUserId: f.id)
                let conv = Conversation(
                    id: convId, bot_id: "", user_id: userId,
                    title: f.name, feature_type: "message",
                    conversation_type: "user_user",
                    last_activity_at: Int(Date().timeIntervalSince1970),
                    round_count: nil, bot_name: nil,
                    last_message_content: nil, last_message_sender_type: nil,
                    model_override: nil
                )
                path.append(conv)
            }
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func createUserBotConv(botId: String, botName: String, userId: String) async throws -> Conversation {
        struct ConvInsert: Encodable {
            let conversation_type = "user_bot"
            let feature = "message"
            let user_id: String
            let bot_id: String
            let title: String
        }
        struct Inserted: Decodable { let id: String }
        let inserted: Inserted = try await SupabaseStack.shared.database
            .from("conversations")
            .insert(ConvInsert(user_id: userId, bot_id: botId, title: botName))
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
        try await SupabaseStack.shared.database
            .from("conversation_participants")
            .insert([
                Participant(conversation_id: inserted.id, participant_type: "user",
                            participant_id: userId, role: "owner"),
                Participant(conversation_id: inserted.id, participant_type: "bot",
                            participant_id: botId, role: "member"),
            ])
            .execute()
        return Conversation(
            id: inserted.id, bot_id: botId, user_id: userId,
            title: botName, feature_type: "message",
            conversation_type: "user_bot",
            last_activity_at: Int(Date().timeIntervalSince1970),
            round_count: 0, bot_name: botName,
            last_message_content: nil, last_message_sender_type: nil,
            model_override: nil
        )
    }

    /// Hits the Worker's find-or-create for the singleton user_user conv.
    /// Worker writes both participant rows under service_role.
    private func openOrCreateUserUserConv(contactUserId: String) async throws -> String {
        var req = URLRequest(url: HostedConfig.environment.workerURL
            .appendingPathComponent("v1/contacts/open-chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["contactUserId": contactUserId])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct R: Decodable { let conversationId: String }
        return try JSONDecoder().decode(R.self, from: data).conversationId
    }
}

// MARK: - Friend row (matches MessageTabView's row font)

private struct FriendRow: View {
    let friend: FriendsTabView.Friend
    var body: some View {
        HStack(spacing: 12) {
            switch friend.kind {
            case .bot:
                BotAvatar(seed: friend.id, size: 44)
            case .human:
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(friend.name)
                        .font(Theme.Fonts.rounded(size: 16, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    KindTag(kind: friend.kind)
                }
                if let sub = friend.subtitle {
                    Text(sub)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct KindTag: View {
    let kind: FriendsTabView.FriendKind
    var body: some View {
        let (text, fg, bg): (String, Color, Color) = kind == .bot
            ? ("AI", Color(hex: 0x1F4F8A), Color(hex: 0xE6EEF8))
            : ("人类", Color(hex: 0x6F4A1A), Color(hex: 0xF7ECDA))
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

private struct FilterChip: View {
    let text: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? .white : Theme.Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(on ? Theme.Palette.accent : Theme.Palette.surfaceMuted)
                )
        }
        .buttonStyle(.plain)
    }
}

private func shortSlug(_ slug: String) -> String {
    if let i = slug.lastIndex(of: "/") {
        return String(slug[slug.index(after: i)...])
    }
    return slug
}

// MARK: - Add friend

private struct AddFriendSheet: View {
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

// MARK: - My handles

private struct MyHandlesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var handles: [HandleRow] = []
    @State private var loading = false
    @State private var newLabel: String = ""
    @State private var error: String?

    struct HandleRow: Identifiable, Hashable {
        let id: String
        let value: String
        let label: String?
        let kind: String
        let is_active: Bool
        let created_at: String?
    }
    private struct Decoded: Decodable {
        let id: String
        let value: String
        let label: String?
        let kind: String
        let is_active: Bool
        let created_at: String?
    }

    var body: some View {
        NavigationStack {
            List {
                Section("生成新号码") {
                    HStack {
                        TextField("备注（如 'blog'）", text: $newLabel)
                        Button("生成") { Task { await mint() } }
                            .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("我的号码") {
                    if handles.isEmpty {
                        Text("还没生成过号码").foregroundStyle(.secondary)
                    }
                    ForEach(handles) { h in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(h.value)
                                    .font(Theme.Fonts.monoSmall)
                                    .textSelection(.enabled)
                                Spacer()
                                if h.is_active {
                                    Button("撤销") { Task { await revoke(h.id) } }
                                        .foregroundStyle(.red)
                                        .font(.footnote)
                                } else {
                                    Text("已撤销")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let label = h.label {
                                Text(label)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("我的号码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let rows: [Decoded] = try await SupabaseStack.shared.database
                .from("user_handles")
                .select("id, value, label, kind, is_active, created_at")
                .order("created_at", ascending: false)
                .execute()
                .value
            self.handles = rows.map {
                HandleRow(id: $0.id, value: $0.value, label: $0.label,
                          kind: $0.kind, is_active: $0.is_active,
                          created_at: $0.created_at)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mint() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        let token = String((0..<10).compactMap { _ in alphabet.randomElement() })
        struct Insert: Encodable {
            let user_id: String
            let value: String
            let label: String?
            let kind: String
        }
        do {
            try await SupabaseStack.shared.database
                .from("user_handles")
                .insert(Insert(user_id: userId, value: token, label: trimmed.isEmpty ? nil : trimmed, kind: "number"))
                .execute()
            newLabel = ""
            Haptics.success()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ id: String) async {
        do {
            try await SupabaseStack.shared.database
                .from("user_handles")
                .update(["is_active": false])
                .eq("id", value: id)
                .execute()
            Haptics.tap()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
