import SwiftUI

/// Group settings — member list, own nickname / mute, leave button.
/// Owner/admin-only knobs (invite, remove, role, handle, policy, billing
/// config) come in later milestones; this view exists now so M2 demos
/// "create group → tap settings → see who's in it → change my name".
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let meta {
                Section("群信息") {
                    LabeledContent("群名", value: meta.title.isEmpty ? "未命名" : meta.title)
                    LabeledContent("加群方式", value: policyLabel(meta.joinPolicy))
                    LabeledContent("成员上限", value: "\(meta.maxMembers)")
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

            Section("成员(\(members.count))") {
                if members.isEmpty {
                    Text(loading ? "加载中…" : "无成员").foregroundStyle(.secondary)
                } else {
                    ForEach(members) { m in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayLabel)
                                Text(roleBadge(m.role) + (m.isBot ? " · 机器人" : ""))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.isOwner { Text("群主").font(.caption2).foregroundStyle(.tint) }
                        }
                    }
                }
            }

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
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Three reads in parallel: meta, participants (with nickname),
            // and my own group_member_billing row for the mute flag.
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

            let meId = (try? await SupabaseStack.shared.auth.session.user.id.uuidString.lowercased()) ?? ""

            async let billingResp: [BillingDecodable] = SupabaseStack.shared
                .from("group_member_billing")
                .select("user_id, muted")
                .eq("conversation_id", value: conversationId)
                .eq("user_id", value: meId)
                .execute()
                .value

            let metas = try await metaResp
            let parts = try await partResp
            let billings = try await billingResp

            // Resolve display names: bots from `bots`, humans from
            // `users.display_name`. Two extra reads, kept simple.
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
                .select("id, display_name")
                .in("id", values: userIds)
                .execute()
                .value

            let botNames = Dictionary(uniqueKeysWithValues:
                (try await botNamesResp).map { ($0.id, $0.display_name) })
            let userNames = Dictionary(uniqueKeysWithValues:
                (try await userNamesResp).map { ($0.id, $0.display_name) })

            self.meta = metas.first.map {
                GroupMeta(title: $0.title ?? "", joinPolicy: $0.join_policy, maxMembers: $0.max_members)
            }
            self.members = parts.map { p in
                let name: String = {
                    if let nick = p.nickname, !nick.isEmpty { return nick }
                    if p.participant_type == "bot" { return botNames[p.participant_id] ?? "未知机器人" }
                    return userNames[p.participant_id] ?? String(p.participant_id.prefix(8))
                }()
                return Member(
                    id: "\(p.participant_type):\(p.participant_id)",
                    isBot: p.participant_type == "bot",
                    displayLabel: name,
                    role: p.role,
                    isOwner: p.role == "owner"
                )
            }
            if let me = parts.first(where: { $0.participant_type == "user" && $0.participant_id == meId }) {
                self.myNickname = me.nickname ?? ""
            }
            self.myMuted = billings.first?.muted ?? false
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
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

    private func roleBadge(_ r: String) -> String {
        switch r {
        case "owner":  return "群主"
        case "admin":  return "管理员"
        case "member": return "成员"
        default: return r
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
        let displayLabel: String
        let role: String
        let isOwner: Bool
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
    }

    private struct BotNameDecodable: Decodable {
        let id: String
        let display_name: String
    }

    private struct UserNameDecodable: Decodable {
        let id: String
        let display_name: String
    }
}
