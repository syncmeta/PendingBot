import SwiftUI

/// Group settings — group-info section (title, group number, policy),
/// own-side knobs (nickname, mute), admin section (policy picker,
/// 谁为机器人的 Token 买单, join requests), member list with avatars +
/// status badges + tap-to-chat / add-friend, leave button.
///
/// The 'number' / 'qr' handles are auto-minted at group creation by
/// migration 0066 — the group number is shown as a fixed identifier
/// (mirroring the personal-account ID), the QR is rotatable by admin
/// inside `GroupQRCard`.
struct GroupSettingsView: View {
    let conversationId: String

    @State private var meta: GroupMeta?
    @State private var members: [Member] = []
    @State private var myNickname: String = ""
    @State private var myMuted: Bool = false
    @State private var loading = false
    @State private var error: String?
    @State private var savingNickname = false
    @State private var leaving = false
    @State private var leaveConfirm = false

    // Admin-only state.
    @State private var isAdmin: Bool = false
    @State private var savingPolicy: Bool = false
    @State private var showingBilling = false
    @State private var showingApprovals = false
    @State private var showingGroupQR = false

    // Group identifier ('number' handle, auto-minted at creation).
    @State private var numberHandle: String = ""
    @State private var copiedNumber = false

    // Cap/balance gate — own freeze state drives the banner; the per-
    // member overdrawn flags drive the badges in the member list.
    @State private var iAmFrozen: Bool = false

    // Friends lookup so member taps can route to the existing user_user
    // chat directly when a row is already a contact.
    @State private var friendUserIds: Set<String> = []

    // Member-tap modal state.
    @State private var openingPeer: PendingPeer?
    @State private var addFriendTarget: Member?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if iAmFrozen {
                frozenBanner
            }

            if let meta {
                Section("群信息") {
                    LabeledContent("群名", value: meta.title.isEmpty ? "未命名" : meta.title)
                    groupNumberRow
                    LabeledContent("加群方式", value: policyLabel(meta.joinPolicy))
                    LabeledContent("成员上限", value: "\(meta.maxMembers)")
                    Button {
                        showingGroupQR = true
                    } label: {
                        LabeledContent("群二维码", value: "扫此码加群")
                    }
                }
            }

            Section("我在本群的设置") {
                HStack {
                    Text("我的群昵称")
                    Spacer()
                    TextField("可选", text: $myNickname)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveNickname() } }
                }
                if savingNickname {
                    HStack { Spacer(); ProgressView() }
                }
                Toggle("免打扰", isOn: $myMuted)
                    .onChange(of: myMuted) { _, newValue in
                        Task { await saveMute(newValue) }
                    }
            }

            if isAdmin {
                adminSection
            }

            membersSection

            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Button(role: .destructive) {
                    leaveConfirm = true
                } label: {
                    if leaving {
                        HStack { ProgressView(); Text("退群中…") }
                    } else {
                        Text("退出群聊").frame(maxWidth: .infinity)
                    }
                }
                .disabled(leaving)
            }
        }
        .navigationTitle("群聊设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("确定退出?", isPresented: $leaveConfirm) {
            Button("退出", role: .destructive) { Task { await leave() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后历史消息仍保留,但你不会再收到新消息。")
        }
        .sheet(isPresented: $showingBilling) {
            GroupBillingSheet(conversationId: conversationId, isAdmin: isAdmin)
        }
        .navigationDestination(isPresented: $showingApprovals) {
            JoinRequestsInboxView(conversationId: conversationId)
        }
        .sheet(isPresented: $showingGroupQR) {
            NavigationStack {
                GroupQRCard(conversationId: conversationId,
                            groupTitle: meta?.title ?? "",
                            isAdmin: isAdmin)
                    .navigationTitle("群二维码")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showingGroupQR = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $openingPeer) { peer in
            NavigationStack {
                ConversationView(
                    conversation: pendingConversation(for: peer),
                    bot: nil,
                    pendingPeer: peer,
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { openingPeer = nil }
                    }
                }
            }
        }
        .sheet(item: $addFriendTarget) { target in
            // Sheet only opens for tappable human members, all of which
            // carry a non-nil userId — `??""` is a defensive fallback
            // that the edge will reject as "用户不存在".
            GroupAddFriendSheet(targetUserId: target.userId ?? "",
                                targetDisplayName: target.displayLabel) { ok in
                if ok { Task { await reloadFriends() } }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Frozen banner

    private var frozenBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("你已达到本群的 PND 上限")
                    .font(Theme.Fonts.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.amber)
                Text("从超出之后的新消息你看不到,也无法在群里发消息。提高上限或充值后恢复。")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Group number row (auto-minted, fixed identifier)

    @ViewBuilder
    private var groupNumberRow: some View {
        HStack(spacing: 8) {
            Text("群号")
            Spacer()
            Text(numberHandle.isEmpty ? "—" : numberHandle)
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if !numberHandle.isEmpty {
                Button {
                    UIPasteboard.general.string = numberHandle
                    Haptics.tap()
                    copiedNumber = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { copiedNumber = false }
                    }
                } label: {
                    Image(systemName: copiedNumber ? "checkmark" : "doc.on.doc")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(copiedNumber ? Theme.Palette.accent : Theme.Palette.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Admin section

    @ViewBuilder
    private var adminSection: some View {
        Section(header: Text("管理员设置")) {
            if let m = meta {
                Picker("加群方式", selection: Binding(
                    get: { m.joinPolicy },
                    set: { newValue in
                        guard newValue != m.joinPolicy else { return }
                        Task { await savePolicy(newValue) }
                    }
                )) {
                    Text("扫码即进").tag("scan_open")
                    Text("审批后进").tag("approval")
                    Text("不允许新成员").tag("closed")
                }
            }

            Button {
                showingBilling = true
            } label: {
                LabeledContent("谁为机器人的 Token 买单", value: "查看并修改")
            }

            Button {
                showingApprovals = true
            } label: {
                LabeledContent("加群请求", value: "查看待审批")
            }
        }
    }

    // MARK: - Member list

    @ViewBuilder
    private var membersSection: some View {
        Section("成员(\(members.count))") {
            if members.isEmpty {
                Text(loading ? "加载中…" : "无成员").foregroundStyle(.secondary)
            } else {
                ForEach(members) { m in
                    Button {
                        handleMemberTap(m)
                    } label: {
                        memberRow(m)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isMemberTappable(m))
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ m: Member) -> some View {
        HStack(spacing: 12) {
            memberAvatar(m, size: 36)
            Text(m.displayLabel)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Right side: status badge + role / bot tags. Stacked so a
            // 群主 + 机器人 + 已达上限 row still fits on one line by
            // truncating the name first.
            HStack(spacing: 6) {
                if m.frozen {
                    statusPill(text: "已达上限",
                               fg: Theme.Palette.amber,
                               bg: Theme.Palette.amberBg)
                }
                if m.isBot {
                    statusPill(text: "机器人",
                               fg: Theme.Palette.inkMuted,
                               bg: Theme.Palette.surfaceMuted)
                } else if m.isOwner {
                    statusPill(text: "群主",
                               fg: Theme.Palette.accent,
                               bg: Theme.Palette.accentBg)
                } else if m.role == "admin" {
                    statusPill(text: "管理员",
                               fg: Theme.Palette.accent,
                               bg: Theme.Palette.accentBg)
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func memberAvatar(_ m: Member, size: CGFloat) -> some View {
        if m.isBot {
            BotAvatar(emojiSeed: m.botId ?? m.id,
                      colorSeed: conversationId,
                      size: size)
        } else if m.userId != nil {
            UserAvatar(seed: m.avatarSeed, attachmentId: m.avatarPath, size: size)
        } else {
            BotAvatar(emojiSeed: m.id, colorSeed: conversationId, size: size)
        }
    }

    private func statusPill(text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(Theme.Fonts.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
            .lineLimit(1)
    }

    // MARK: - Member tap routing

    private func isMemberTappable(_ m: Member) -> Bool {
        // Bots: not tappable (no chat surface for picking up the same
        // bot from a group settings sheet — that's the friends tab).
        if m.isBot { return false }
        // Self: not tappable.
        if let uid = m.userId, uid == myUserId { return false }
        return true
    }

    private func handleMemberTap(_ m: Member) {
        guard !m.isBot, let uid = m.userId, uid != myUserId else { return }
        if friendUserIds.contains(uid) {
            // Already a contact — open the user_user chat directly.
            openingPeer = PendingPeer(
                kind: "user",
                peerId: uid,
                displayName: m.displayLabel,
            )
        } else {
            addFriendTarget = m
        }
        Haptics.tap()
    }

    private func pendingConversation(for peer: PendingPeer) -> Conversation {
        let userId = AccountStore.shared.current?.id ?? ""
        return Conversation(
            id: "",
            bot_id: "",
            user_id: userId,
            title: peer.displayName,
            feature_type: "message",
            conversation_type: "user_user",
            last_activity_at: Int(Date().timeIntervalSince1970),
            round_count: 0,
            bot_name: nil,
            last_message_content: nil,
            last_message_sender_type: nil
        )
    }

    private var myUserId: String {
        AccountStore.shared.current?.id ?? ""
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        // Hydrate from the local cache first so the meta block + member
        // rows paint instantly on entry. Same cache-then-refresh pattern
        // ConversationView uses for history and group senders — the
        // network branch below overwrites everything that came from the
        // cache once the authoritative reads land.
        if meta == nil && members.isEmpty {
            hydrateFromCache()
        }
        do {
            async let metaResp: [GroupMetaDecodable] = SupabaseStack.shared
                .from("conversation_group_meta")
                .select("conversation_id, title, join_policy, max_members")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value

            async let partResp: [ParticipantDecodable] = SupabaseStack.shared
                .from("conversation_participants")
                .select("participant_type, participant_id, role, nickname")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value

            // Read every member's billing row (RLS-policy-3 lets any
            // participant see the lot post-0066) so the list can paint
            // 已达上限 badges for anyone, not just the caller.
            async let billingResp: [BillingDecodable] = SupabaseStack.shared
                .from("group_member_billing")
                .select("user_id, muted, overdrawn, frozen_at")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value

            async let handlesResp: [HandleRow] = SupabaseStack.shared
                .from("group_join_handles")
                .select("handle_type, value")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value

            async let contactsTask = (try? await ContactsAPI.fetchContacts()) ?? []

            let metas = try await metaResp
            let parts = try await partResp
            let billings = try await billingResp
            let handles = try await handlesResp

            let billingByUser = Dictionary(uniqueKeysWithValues:
                billings.map { ($0.user_id, $0) })

            // Resolve display names + avatars: bots from `bots`, humans
            // from `users.display_name + avatar_path`. Two extra reads,
            // kept simple.
            let botIds = parts.filter { $0.participant_type == "bot" }.map(\.participant_id)
            let userIds = parts.filter { $0.participant_type == "user" }.map(\.participant_id)

            async let botNamesResp: [BotNameDecodable] = botIds.isEmpty ? [] : SupabaseStack.shared
                .from("bots")
                .select("id, display_name")
                .in("id", values: botIds)
                .execute()
                .value
            // pendingbot.users RLS is self-only — a direct supabase query
            // would return ONLY the caller's row and every other member
            // would silently fall back to id-prefix. Routing through the
            // worker (service-role) gives us display_name + avatar_path
            // + avatar_seed for everyone in the group.
            async let userInfoResp: [String: (String, String?, String)] =
                userIds.isEmpty
                    ? [:]
                    : fetchMemberProfiles(conversationId: conversationId, userIds: userIds)

            let botNames = Dictionary(uniqueKeysWithValues:
                (try await botNamesResp).map { ($0.id, $0.display_name) })
            let userInfo = await userInfoResp

            let me = parts.first(where: { $0.participant_type == "user" && $0.participant_id == myUserId })

            self.meta = metas.first.map {
                GroupMeta(title: $0.title ?? "", joinPolicy: $0.join_policy, maxMembers: $0.max_members)
            }
            var cacheRows: [LocalDatabase.GroupMemberRow] = []
            self.members = parts.map { p in
                let isBot = p.participant_type == "bot"
                let nick = (p.nickname?.isEmpty == false) ? p.nickname : nil
                let label: String = {
                    if let n = nick { return n }
                    if isBot { return botNames[p.participant_id] ?? "未知机器人" }
                    if let info = userInfo[p.participant_id], !info.0.isEmpty {
                        return info.0
                    }
                    return String(p.participant_id.prefix(8))
                }()
                let avatarPath = isBot ? nil : userInfo[p.participant_id]?.1 ?? nil
                let avatarSeed = isBot
                    ? p.participant_id
                    : (userInfo[p.participant_id]?.2 ?? p.participant_id)
                let frozen = !isBot && (billingByUser[p.participant_id]?.overdrawn ?? false)
                let resolvedName: String = {
                    if isBot { return botNames[p.participant_id] ?? "未知机器人" }
                    return userInfo[p.participant_id]?.0 ?? ""
                }()
                cacheRows.append(LocalDatabase.GroupMemberRow(
                    conversation_id: conversationId,
                    participant_type: p.participant_type,
                    participant_id: p.participant_id,
                    nickname: p.nickname,
                    role: p.role,
                    display_name: resolvedName,
                    avatar_path: avatarPath,
                    avatar_seed: avatarSeed,
                    frozen: frozen
                ))
                return Member(
                    id: "\(p.participant_type):\(p.participant_id)",
                    isBot: isBot,
                    botId: isBot ? p.participant_id : nil,
                    userId: isBot ? nil : p.participant_id,
                    displayLabel: label,
                    avatarPath: avatarPath,
                    avatarSeed: avatarSeed,
                    role: p.role,
                    isOwner: p.role == "owner",
                    frozen: frozen,
                )
            }
            self.myNickname = me?.nickname ?? ""
            self.isAdmin = (me?.role == "owner" || me?.role == "admin")
            self.myMuted = billingByUser[myUserId]?.muted ?? false
            self.iAmFrozen = billingByUser[myUserId]?.overdrawn ?? false

            self.numberHandle = handles.first(where: { $0.handle_type == "number" })?.value ?? ""

            let contacts = await contactsTask
            self.friendUserIds = Set(contacts.map(\.id))

            // Persist the resolved snapshot so the next entry into this
            // settings page (and the chat page) paints from cache before
            // the network round-trip lands.
            LocalDatabase.shared.replaceGroupMembers(
                conversationId: conversationId, cacheRows)
            if let m = self.meta {
                LocalDatabase.shared.upsertGroupMeta(
                    LocalDatabase.GroupMetaRow(
                        conversation_id: conversationId,
                        title: m.title,
                        join_policy: m.joinPolicy,
                        max_members: m.maxMembers,
                        number_handle: self.numberHandle
                    ))
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Read the most-recent cached snapshot of meta + members so the
    /// view paints last-known content while `load()` waits on the
    /// network. Frozen / muted / friend-membership state aren't cached
    /// here — the badges that depend on them paint in once the network
    /// load finishes, but the avatars + names + role hierarchy land
    /// instantly.
    private func hydrateFromCache() {
        if let cachedMeta = LocalDatabase.shared.loadGroupMeta(conversationId: conversationId) {
            self.meta = GroupMeta(
                title: cachedMeta.title,
                joinPolicy: cachedMeta.join_policy,
                maxMembers: cachedMeta.max_members,
            )
            self.numberHandle = cachedMeta.number_handle
        }
        let cachedMembers = LocalDatabase.shared.loadGroupMembers(conversationId: conversationId)
        guard !cachedMembers.isEmpty else { return }
        self.members = cachedMembers.map { r in
            let isBot = r.participant_type == "bot"
            let nick = r.nickname?.trimmingCharacters(in: .whitespaces)
            let label: String = {
                if let n = nick, !n.isEmpty { return n }
                if !r.display_name.isEmpty { return r.display_name }
                return String(r.participant_id.prefix(8))
            }()
            return Member(
                id: "\(r.participant_type):\(r.participant_id)",
                isBot: isBot,
                botId: isBot ? r.participant_id : nil,
                userId: isBot ? nil : r.participant_id,
                displayLabel: label,
                avatarPath: r.avatar_path,
                avatarSeed: r.avatar_seed ?? r.participant_id,
                role: r.role ?? "",
                isOwner: r.role == "owner",
                frozen: r.frozen,
            )
        }
        let myRole = cachedMembers.first(where: {
            $0.participant_type == "user" && $0.participant_id == myUserId
        })?.role
        self.isAdmin = (myRole == "owner" || myRole == "admin")
        self.myNickname = cachedMembers.first(where: {
            $0.participant_type == "user" && $0.participant_id == myUserId
        })?.nickname ?? ""
    }

    private func reloadFriends() async {
        let contacts = (try? await ContactsAPI.fetchContacts()) ?? []
        await MainActor.run { self.friendUserIds = Set(contacts.map(\.id)) }
    }

    private func savePolicy(_ policy: String) async {
        savingPolicy = true
        defer { savingPolicy = false }
        struct Body: Encodable { let policy: String }
        await postVoid(path: "v1/groups/\(conversationId)/policy",
                       body: Body(policy: policy))
        if error == nil, let m = meta {
            meta = GroupMeta(title: m.title, joinPolicy: policy, maxMembers: m.maxMembers)
        }
    }

    // MARK: - Actions (POST helpers)

    private func saveNickname() async {
        savingNickname = true
        defer { savingNickname = false }
        struct Body: Encodable { let nickname: String? }
        let val = myNickname.trimmingCharacters(in: .whitespaces)
        await postVoid(path: "v1/groups/\(conversationId)/nickname",
                       body: Body(nickname: val.isEmpty ? nil : val))
    }

    private func saveMute(_ muted: Bool) async {
        struct Body: Encodable { let muted: Bool }
        await postVoid(path: "v1/groups/\(conversationId)/mute", body: Body(muted: muted))
    }

    private func leave() async {
        leaving = true
        defer { leaving = false }
        struct Empty: Encodable {}
        await postVoid(path: "v1/groups/\(conversationId)/leave", body: Empty())
        if error == nil { dismiss() }
    }

    private func postVoid<B: Encodable>(path: String, body: B) async {
        do {
            let url = HostedConfig.environment.workerURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(domain: "GroupSettings", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Format helpers

    private func policyLabel(_ p: String) -> String {
        switch p {
        case "scan_open": return "扫码即进"
        case "approval":  return "审批后进"
        case "closed":    return "不允许新成员"
        default: return p
        }
    }

    // MARK: - Models

    struct GroupMeta {
        let title: String
        let joinPolicy: String
        let maxMembers: Int
    }

    struct Member: Identifiable, Hashable {
        let id: String
        let isBot: Bool
        let botId: String?
        let userId: String?
        let displayLabel: String
        let avatarPath: String?
        /// Server-supplied placeholder-emoji seed (users.custom_fields
        /// .avatar_seed). Always the same value for a given user across
        /// every viewer's device, so the same person renders the same
        /// emoji everywhere.
        let avatarSeed: String
        let role: String
        let isOwner: Bool
        let frozen: Bool
    }

    private struct GroupMetaDecodable: Decodable {
        let conversation_id: String
        let title: String?
        let join_policy: String
        let max_members: Int
    }

    private struct ParticipantDecodable: Decodable {
        let participant_type: String
        let participant_id: String
        let role: String
        let nickname: String?
    }

    private struct BillingDecodable: Decodable {
        let user_id: String
        let muted: Bool
        let overdrawn: Bool
        let frozen_at: String?
    }

    private struct HandleRow: Decodable {
        let handle_type: String
        let value: String
    }

    private struct BotNameDecodable: Decodable {
        let id: String
        let display_name: String
    }

    /// Bulk-fetch member profile data through the worker. The worker
    /// gates on shared-conversation membership and reads via service-role
    /// so it can return rows for users other than the caller (which a
    /// direct supabase query can't, since pendingbot.users RLS is
    /// self-only). Returns map: user_id → (display_name, avatar_path,
    /// avatar_seed). On failure returns empty so the caller falls back
    /// to id-prefix rendering.
    private func fetchMemberProfiles(
        conversationId: String,
        userIds: [String]
    ) async -> [String: (String, String?, String)] {
        guard !userIds.isEmpty else { return [:] }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/profiles")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "conversationId": conversationId,
                "userIds": userIds,
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            struct Payload: Decodable {
                struct Row: Decodable {
                    let userId: String
                    let displayName: String
                    let avatarPath: String?
                    let avatarSeed: String?
                }
                let profiles: [Row]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return Dictionary(uniqueKeysWithValues: payload.profiles.map {
                ($0.userId, ($0.displayName, $0.avatarPath, $0.avatarSeed ?? $0.userId))
            })
        } catch {
            return [:]
        }
    }
}

// MARK: - Add-friend sheet

/// 弹出框 "加他好友？" — single-purpose sheet shown when a non-friend
/// member is tapped in the member list. Mirrors the title / placeholder
/// / button copy spelled out by product: 标题 "加他好友？", 文本框占位符
/// "备注", 按钮 "发送加好友请求".
private struct GroupAddFriendSheet: View {
    let targetUserId: String
    let targetDisplayName: String
    let onClose: (_ sentSuccessfully: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var verifyMessage: String = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("验证信息（可选）", text: $verifyMessage, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(1...3)
                } header: {
                    Text("加他好友？")
                } footer: {
                    if !targetDisplayName.isEmpty {
                        Text("对方:\(targetDisplayName)").foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                    }
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            HStack { ProgressView(); Text("发送中…") }
                        } else {
                            Text("发送加好友请求").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(sending)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        onClose(false)
                        dismiss()
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true; defer { sending = false }
        // We have the peer's user id, not their handle, so this skips the
        // /v1/friend-requests `handleValue` flow and posts directly with
        // a `peerUserId` key. Edge needs to accept that shape — see the
        // /v1/friend-requests POST handler in apps/edge/src/routes/.
        struct Body: Encodable {
            let peerUserId: String
            let message: String?
        }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/friend-requests")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let trimmed = verifyMessage.trimmingCharacters(in: .whitespaces)
            req.httpBody = try JSONEncoder().encode(Body(
                peerUserId: targetUserId,
                message: trimmed.isEmpty ? nil : trimmed,
            ))
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                self.error = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                return
            }
            Haptics.success()
            onClose(true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// PendingPeer is Identifiable so `.sheet(item:)` can drive the friend-
// chat presentation in this view. The struct has no `id` of its own
// because most call sites pass it as a Hashable navigation value.
extension PendingPeer: Identifiable {
    var id: String { "\(kind):\(peerId)" }
}
