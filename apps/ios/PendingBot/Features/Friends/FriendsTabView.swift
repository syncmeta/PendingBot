import SwiftUI
import Supabase
import CoreImage.CIFilterBuiltins

/// 好友 tab — sectioned contact list (机器人朋友 / 真人朋友), no nav title.
/// Filter chips above the list narrow to one section; each row carries
/// an AI / 人类 tag on the far right.
///
/// Toolbar:
///   left  qrcode → live QR sheet (mint + refresh)
///   right +      → add-friend sheet (handle code or email)
///
/// Tap behavior:
///   bot   → INSERT a fresh user_bot conv and push into it
///   human → POST /v1/contacts/open-chat (find-or-create singleton) and push
struct FriendsTabView: View {
    @EnvironmentObject private var store: AccountStore

    @State private var bots: [BotPick] = []
    @State private var humans: [HumanPick] = []
    @State private var loading = false
    @State private var error: String?
    @State private var addingFriend = false
    @State private var showingQR = false
    @State private var humansOnly = false
    @State private var botsOnly = false
    @State private var path: [Conversation] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                List {
                    Section {
                        HStack {
                            Spacer()
                            FilterChip(text: "仅人类", on: humansOnly) {
                                humansOnly.toggle()
                                if humansOnly { botsOnly = false }
                            }
                            FilterChip(text: "仅机器人", on: botsOnly) {
                                botsOnly.toggle()
                                if botsOnly { humansOnly = false }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }

                    if !botsOnly {
                        // Humans
                        if !humansOnly {
                            Section("机器人朋友") {
                                if bots.isEmpty {
                                    Text("还没有机器人朋友").foregroundStyle(.secondary)
                                }
                                ForEach(bots) { bot in
                                    FriendRow(kind: .bot,
                                              avatarSeed: bot.id,
                                              name: bot.display_name,
                                              modelTag: bot.modelTag)
                                        .listRowBackground(Theme.Palette.surface)
                                        .contentShape(Rectangle())
                                        .onTapGesture { Task { await tapBot(bot) } }
                                }
                            }
                        } else {
                            EmptyView()
                        }
                    }
                    if !botsOnly {
                        Section("真人朋友") {
                            if humans.isEmpty {
                                Text("还没有真人朋友 — 上方 + 加一个")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(humans) { c in
                                FriendRow(kind: .human,
                                          avatarSeed: c.id,
                                          name: c.alias ?? String(c.id.prefix(8)),
                                          modelTag: nil)
                                    .listRowBackground(Theme.Palette.surface)
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await tapHuman(c) } }
                            }
                        }
                    } else {
                        // botsOnly: only show bots section without title
                        Section {
                            ForEach(bots) { bot in
                                FriendRow(kind: .bot,
                                          avatarSeed: bot.id,
                                          name: bot.display_name,
                                          modelTag: bot.modelTag)
                                    .listRowBackground(Theme.Palette.surface)
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await tapBot(bot) } }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingQR = true
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
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingFriend) {
                AddFriendSheet { Task { await load() } }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingQR) {
                MyQRSheet()
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

    // MARK: - Data

    struct BotPick: Identifiable, Hashable {
        let id: String
        let display_name: String
        let model_id: String?
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
                .order("created_at", ascending: true)
                .execute()
                .value
            async let contactRowsResp: [ContactDecodable] = SupabaseStack.shared.database
                .from("user_contacts")
                .select("contact_user_id, alias")
                .order("created_at", ascending: true)
                .execute()
                .value

            let botRows = try await botRowsResp
            let contactRows = try await contactRowsResp

            self.bots = botRows.map { BotPick(id: $0.id, display_name: $0.display_name, model_id: $0.model_id) }
            self.humans = contactRows.map { HumanPick(id: $0.contact_user_id, alias: $0.alias) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Tap handlers

    private func tapBot(_ bot: BotPick) async {
        guard let userId = AccountStore.shared.current?.id else { return }
        do {
            let conv = try await createUserBotConv(botId: bot.id,
                                                   botName: bot.display_name,
                                                   userId: userId)
            path.append(conv)
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func tapHuman(_ c: HumanPick) async {
        guard let userId = AccountStore.shared.current?.id else { return }
        do {
            let convId = try await openOrCreateUserUserConv(contactUserId: c.id)
            let conv = Conversation(
                id: convId, bot_id: "", user_id: userId,
                title: c.alias ?? String(c.id.prefix(8)),
                feature_type: "message",
                conversation_type: "user_user",
                last_activity_at: Int(Date().timeIntervalSince1970),
                round_count: nil, bot_name: nil,
                last_message_content: nil, last_message_sender_type: nil,
                model_override: nil
            )
            path.append(conv)
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

// MARK: - Friend row

private struct FriendRow: View {
    enum Kind { case bot, human }
    let kind: Kind
    let avatarSeed: String
    let name: String
    let modelTag: String?

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
                    Text(tag)
                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Palette.accentBg))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // AI / 人类 tag at the far right.
            KindTag(kind: kind)
        }
        .padding(.vertical, 4)
    }
}

private struct KindTag: View {
    let kind: FriendRow.Kind
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? .white : Theme.Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(on ? Theme.Palette.accent : Theme.Palette.surfaceMuted)
                )
        }
        .buttonStyle(.plain)
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

/// Shows a single live QR encoding the user's currently-active QR-kind
/// handle. Refresh button: revoke the displayed handle and mint a new
/// one. Each refresh invalidates whatever is currently floating around
/// — perfect when you've shared your QR somewhere semi-public.
private struct MyQRSheet: View {
    @State private var currentValue: String?
    @State private var loading = false
    @State private var error: String?

    private let context = CIContext()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                VStack(spacing: 18) {
                    if loading {
                        ProgressView().controlSize(.large)
                    } else if let value = currentValue, let img = qrImage(for: value) {
                        Image(uiImage: img)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(20)
                            .background(Theme.Palette.surface)
                            .cornerRadius(16)
                        Text(value)
                            .font(Theme.Fonts.monoSmall)
                            .textSelection(.enabled)
                            .foregroundStyle(Theme.Palette.inkMuted)
                        Text("用对方手机扫码、或让对方在「加好友 → 号码」里输入这串字。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else {
                        Text("生成二维码失败")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("刷新（旧码作废）", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Theme.Palette.accent))
                    }
                    .buttonStyle(.plain)

                    if let error {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
                .padding(.top, 24)
            }
            .navigationTitle("我的二维码")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Open with whatever active QR-kind handle exists; if none, mint one.
            await ensureActive()
        }
    }

    private func ensureActive() async {
        loading = true; defer { loading = false }
        struct Row: Decodable { let id: String; let value: String }
        do {
            let rows: [Row] = try await SupabaseStack.shared.database
                .from("user_handles")
                .select("id, value")
                .eq("kind", value: "qr")
                .eq("is_active", value: true)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                self.currentValue = row.value
            } else {
                try await mintNew()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        loading = true; defer { loading = false }
        do {
            // Revoke ALL active QR-kind handles so only the freshly-minted
            // one stays valid afterwards.
            try await SupabaseStack.shared.database
                .from("user_handles")
                .update(["is_active": false])
                .eq("kind", value: "qr")
                .eq("is_active", value: true)
                .execute()
            try await mintNew()
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mintNew() async throws {
        guard let userId = AccountStore.shared.current?.id else { return }
        let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        let token = String((0..<10).compactMap { _ in alphabet.randomElement() })
        struct Insert: Encodable {
            let user_id: String
            let value: String
            let kind: String
            let label: String?
        }
        try await SupabaseStack.shared.database
            .from("user_handles")
            .insert(Insert(user_id: userId, value: token, kind: "qr", label: "QR"))
            .execute()
        self.currentValue = token
    }

    private func qrImage(for s: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
