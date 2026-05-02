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
    @State private var path: [PendingPeer] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Background applied at the VStack level (not just inside
                // the lower ZStack) so the TabHeaderBar at the top sits
                // on canvas instead of the default white safe-area fill.
                TabHeaderBar(title: "好友") {
                    HStack(spacing: 14) {
                        Button {
                            showingQR = true
                            Haptics.tap()
                        } label: {
                            Image(systemName: "qrcode")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        Button {
                            addingFriend = true
                            Haptics.tap()
                        } label: {
                            CirclePlusButton()
                        }
                    }
                }
                ZStack {
                    Theme.Palette.canvas.ignoresSafeArea()
                    List {
                    Section {
                        HStack {
                            Spacer()
                            FilterChip(text: "人类", on: humansOnly) {
                                humansOnly.toggle()
                                if humansOnly { botsOnly = false }
                            }
                            FilterChip(text: "机器人", on: botsOnly) {
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
                            Section {
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
                        Section {
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
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
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
            .navigationDestination(for: PendingPeer.self) { peer in
                ConversationView(
                    conversation: pendingConversation(for: peer),
                    bot: nil,
                    pendingPeer: peer
                )
            }
        }
        // Once a friend tap pushes us into a conversation, drop the tab
        // bar so the chat fills the full height — same behaviour the
        // message tab uses on its own conv push.
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
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
    //
    // Lazy: navigate with a synthetic empty Conversation + a PendingPeer.
    // ConversationView materialises the conv row on first send, so tapping
    // a friend and backing out without sending leaves no DB trace.

    private func tapBot(_ bot: BotPick) async {
        path.append(PendingPeer(kind: "bot",
                                peerId: bot.id,
                                displayName: bot.display_name))
        Haptics.tap()
    }

    private func tapHuman(_ c: HumanPick) async {
        path.append(PendingPeer(kind: "user",
                                peerId: c.id,
                                displayName: c.alias ?? String(c.id.prefix(8))))
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
            model_override: nil
        )
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

            // AI / 人类 tag at the far right.
            KindTag(kind: kind)
        }
        .padding(.vertical, 4)
    }
}

private struct KindTag: View {
    let kind: FriendRow.Kind
    var body: some View {
        // Mirror the message-list "primary name" capsule colors:
        //   AI    → accent green fg + accentBg
        //   人类   → dark purple fg + light purple bg
        let (text, fg, bg): (String, Color, Color) = kind == .bot
            ? ("AI", Theme.Palette.accent, Theme.Palette.accentBg)
            : ("人类", Color(hex: 0x5B3D8A), Color(hex: 0xECE3F7))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? .white : Theme.Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    // Off state: white pill with a hairline border, per
                    // user spec ("白底灰边"). On state stays the accent
                    // fill so the active selection still stands out.
                    Capsule().fill(on ? Theme.Palette.accent : Color.white)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            on ? Color.clear : Theme.Palette.hairline,
                            lineWidth: 0.5
                        )
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
                ScrollView {
                    VStack(spacing: 18) {
                        nameCard
                        if let error {
                            Text(error).foregroundStyle(.red).font(.footnote)
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
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("我的名片")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await ensureActive()
        }
    }

    /// Vertical "business card": avatar + name on top, QR centred, handle
    /// + footer hint at the bottom. The whole thing sits inside a single
    /// rounded panel so it visually reads as a card you can hand over.
    @ViewBuilder
    private var nameCard: some View {
        let store = AccountStore.shared
        let avatarSeed = store.avatarSeed ?? store.current?.id ?? "?"
        let displayName = store.profileDisplayName ?? store.current?.displayName ?? "你"
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                BotAvatar(seed: avatarSeed, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Text("PendingBot 名片")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                Spacer(minLength: 0)
            }

            Divider().background(Theme.Palette.hairline)

            if loading {
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 220, height: 220)
            } else if let value = currentValue, let img = qrImage(for: value) {
                VStack(spacing: 12) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                    Text(value)
                        .font(Theme.Fonts.monoSmall)
                        .textSelection(.enabled)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            } else {
                Text("生成二维码失败")
                    .foregroundStyle(.secondary)
                    .frame(width: 220, height: 220)
            }

            Text("扫一扫，把我加为好友。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
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
