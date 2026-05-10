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
            AddFriendSheet(targetUserId: target.userId,
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.amber)
                Text("从超出之后的新消息你看不到,也无法在群里发消息。提高上限或充值后恢复。")
                    .font(.footnote)
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
                        .font(.footnote)
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
        } else if let uid = m.userId {
            UserAvatar(seed: uid, attachmentId: m.avatarPath, size: size)
        } else {
            BotAvatar(emojiSeed: m.id, colorSeed: conversationId, size: size)
        }
    }

    private func statusPill(text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
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
            last_message_sender_type: nil,
            model_override: nil,
            provider_override: nil,
        )
    }

    private var myUserId: String {
        AccountStore.shared.current?.id ?? ""
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
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
            async let userNamesResp: [UserNameDecodable] = userIds.isEmpty ? [] : SupabaseStack.shared
                .from("users")
                .select("id, display_name, avatar_path")
                .in("id", values: userIds)
                .execute()
                .value

            let botNames = Dictionary(uniqueKeysWithValues:
                (try await botNamesResp).map { ($0.id, $0.display_name) })
            let userInfo = Dictionary(uniqueKeysWithValues:
                (try await userNamesResp).map { ($0.id, ($0.display_name, $0.avatar_path)) })

            let me = parts.first(where: { $0.participant_type == "user" && $0.participant_id == myUserId })

            self.meta = metas.first.map {
                GroupMeta(title: $0.title ?? "", joinPolicy: $0.join_policy, maxMembers: $0.max_members)
            }
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
                let frozen = !isBot && (billingByUser[p.participant_id]?.overdrawn ?? false)
                return Member(
                    id: "\(p.participant_type):\(p.participant_id)",
                    isBot: isBot,
                    botId: isBot ? p.participant_id : nil,
                    userId: isBot ? nil : p.participant_id,
                    displayLabel: label,
                    avatarPath: avatarPath,
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
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
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

    private struct UserNameDecodable: Decodable {
        let id: String
        let display_name: String
        let avatar_path: String?
    }
}

// MARK: - Add-friend sheet

/// 弹出框 "加他好友？" — single-purpose sheet shown when a non-friend
/// member is tapped in the member list. Mirrors the title / placeholder
/// / button copy spelled out by product: 标题 "加他好友？", 文本框占位符
/// "备注", 按钮 "发送加好友请求".
private struct AddFriendSheet: View {
    let targetUserId: String
    let targetDisplayName: String
    let onClose: (_ sentSuccessfully: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var remark: String = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("备注", text: $remark)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("加他好友？")
                } footer: {
                    if !targetDisplayName.isEmpty {
                        Text("对方:\(targetDisplayName)").foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
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
            let remark: String?
        }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/friend-requests")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let trimmed = remark.trimmingCharacters(in: .whitespaces)
            req.httpBody = try JSONEncoder().encode(Body(
                peerUserId: targetUserId,
                remark: trimmed.isEmpty ? nil : trimmed,
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
