import SwiftUI
import Supabase

/// 好友 tab — contacts (bots + humans) and group-chat list.
///
/// Sections:
///   机器人朋友 — every active bot (preset roster + bots the user adds later)
///   真人朋友   — pendingbot.user_contacts where contact_type='user'
///   群聊       — conversations of type 'group' the user participates in
///
/// Top-right + opens the add-friend sheet (handle code or email).
/// Tap a contact → open the user_bot or user_user conversation
/// (creating one if it doesn't exist yet).
struct FriendsTabView: View {
    @EnvironmentObject private var store: AccountStore

    @State private var bots: [BotRow] = []
    @State private var humanContacts: [HumanRow] = []
    @State private var groupConvs: [Conversation] = []
    @State private var loading = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var managingHandles = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                List {
                    Section("机器人朋友") {
                        if bots.isEmpty {
                            Text("还没有机器人朋友").foregroundStyle(.secondary)
                        }
                        ForEach(bots) { bot in
                            BotContactRow(bot: bot)
                                .listRowBackground(Theme.Palette.surface)
                        }
                    }
                    Section("真人朋友") {
                        if humanContacts.isEmpty {
                            Text("还没有真人朋友 — 上方 + 加一个")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(humanContacts) { c in
                            HumanContactRow(contact: c)
                                .listRowBackground(Theme.Palette.surface)
                        }
                    }
                    Section("群聊") {
                        if groupConvs.isEmpty {
                            Text("还没有群聊").foregroundStyle(.secondary)
                        }
                        ForEach(groupConvs) { conv in
                            Text(conv.title ?? "未命名群")
                                .listRowBackground(Theme.Palette.surface)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            .navigationTitle("好友")
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
                    } label: { Image(systemName: "plus") }
                    .foregroundStyle(Theme.Palette.accent)
                }
            }
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
        }
        .task { await load() }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: - Data

    struct BotRow: Identifiable, Hashable {
        let id: String
        let display_name: String
        let model_id: String?
    }
    struct HumanRow: Identifiable, Hashable {
        let id: String
        let alias: String?
        let email: String?
    }
    private struct ContactDecodable: Decodable {
        let contact_user_id: String
        let alias: String?
    }
    private struct BotDecodable: Decodable {
        let id: String
        let display_name: String
        let model_id: String?
    }
    private struct ConvDecodable: Decodable {
        let id: String
        let title: String?
        let updated_at: String?
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
            async let contactRowsResp: [ContactDecodable] = SupabaseStack.shared.database
                .from("user_contacts")
                .select("contact_user_id, alias")
                .execute()
                .value
            async let groupRowsResp: [ConvDecodable] = SupabaseStack.shared.database
                .from("conversations")
                .select("id, title, updated_at")
                .eq("conversation_type", value: "group")
                .order("updated_at", ascending: false)
                .execute()
                .value

            let botRows = try await botRowsResp
            let contactRows = try await contactRowsResp
            let groupRows = try await groupRowsResp

            self.bots = botRows.map { BotRow(id: $0.id, display_name: $0.display_name, model_id: $0.model_id) }
            self.humanContacts = contactRows.map {
                HumanRow(id: $0.contact_user_id, alias: $0.alias, email: nil)
            }
            self.groupConvs = groupRows.map { row in
                let secs: Int = ISO8601DateFormatter().date(from: row.updated_at ?? "")
                    .map { Int($0.timeIntervalSince1970) } ?? 0
                return Conversation(
                    id: row.id, bot_id: "", user_id: store.current?.id ?? "",
                    title: row.title, feature_type: "group",
                    last_activity_at: secs, round_count: nil,
                    bot_name: nil, last_message_content: nil,
                    last_message_sender_type: nil, model_override: nil
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct BotContactRow: View {
    let bot: FriendsTabView.BotRow
    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(seed: bot.id, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.display_name)
                    .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                if let m = bot.model_id {
                    Text(shortSlug(m))
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct HumanContactRow: View {
    let contact: FriendsTabView.HumanRow
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.alias ?? contact.id.prefix(8).description)
                    .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
            }
            Spacer()
        }
        .padding(.vertical, 4)
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
                    Button("加") {
                        Task { await submit() }
                    }
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
        // 10-char base32 token. Easy to read aloud, avoids 0/O 1/L confusion.
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
