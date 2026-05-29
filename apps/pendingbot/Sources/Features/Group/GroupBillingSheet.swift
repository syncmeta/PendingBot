#if os(iOS)
import SwiftUI

/// Group billing sheet — owner/admin sets the cost-split mode + window;
/// every member sets their own per-group PND cap. Wired to the
/// /v1/groups/:id/billing and /v1/groups/:id/cap endpoints.
///
/// "custom" mode UI (per-user weight entry) is a future polish; this
/// shell ships the four canonical modes and the personal cap.
struct GroupBillingSheet: View {
    let conversationId: String
    let isAdmin: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var payerMode: PayerMode = .all
    @State private var members: [BillingMember] = []
    @State private var payerIds: Set<String> = []
    @State private var capCredits: String = ""
    @State private var capEnabled: Bool = false

    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if isAdmin {
                    Section {
                        Picker("模式", selection: $payerMode) {
                            Text("所有人 A").tag(PayerMode.all)
                            Text("部分人 A").tag(PayerMode.some)
                            Text("群主全包").tag(PayerMode.owner)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("分摊方式")
                    } footer: {
                        Text("底层统一按人头分摊；差别只是谁参与 A 这笔费用。")
                    }

                    if payerMode == .some {
                        Section("参与 A 的成员") {
                            ForEach(members) { member in
                                Toggle(member.name, isOn: Binding(
                                    get: { payerIds.contains(member.id) },
                                    set: { on in
                                        if on { payerIds.insert(member.id) }
                                        else { payerIds.remove(member.id) }
                                    }
                                ))
                            }
                        }
                    }
                }

                Section(header: Text("我在本群消耗 PND 的上限"),
                        footer: Text("超过上限后,本群产生的费用不会再从你账户扣,不影响你继续聊天。")) {
                    Toggle("启用上限", isOn: $capEnabled)
                    if capEnabled {
                        TextField("PND", text: $capCredits)
                            .keyboardType(.numberPad)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            HStack { ProgressView(); Text("保存中…") }
                        } else {
                            Text("保存").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(saving)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("谁为机器人的 Token 买单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .disabled(loading && error == nil)
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let meId = (try? await SupabaseStack.shared.auth.session.user.id.uuidString.lowercased()) ?? ""
            async let partResp: [ParticipantDecodable] = SupabaseStack.shared
                .from("conversation_participants")
                .select("participant_id, role, nickname")
                .eq("conversation_id", value: conversationId)
                .eq("participant_type", value: "user")
                .execute()
                .value
            async let mineResp: [MineDecodable] = SupabaseStack.shared
                .from("group_member_billing")
                .select("user_id, cap_credits, participates")
                .eq("conversation_id", value: conversationId)
                .eq("user_id", value: meId)
                .execute()
                .value
            async let billingResp: [MemberBillingDecodable] = SupabaseStack.shared
                .from("group_member_billing")
                .select("user_id, participates")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value
            let parts = try await partResp
            let billings = try await billingResp
            let profiles = await fetchMemberProfiles(userIds: parts.map(\.participant_id))
            members = parts.map { p in
                let nick = p.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                let profileName = profiles[p.participant_id] ?? ""
                let name = (nick?.isEmpty == false ? nick! : profileName)
                return BillingMember(
                    id: p.participant_id,
                    name: name.isEmpty ? String(p.participant_id.prefix(8)) : name,
                    role: p.role
                )
            }
            payerIds = Set(billings.filter { $0.participates }.map(\.user_id))
            let allIds = Set(members.map(\.id))
            let ownerIds = Set(members.filter { $0.role == "owner" }.map(\.id))
            if payerIds == ownerIds, !ownerIds.isEmpty {
                payerMode = .owner
            } else if payerIds != allIds {
                payerMode = .some
            } else {
                payerMode = .all
            }
            if let mine = (try await mineResp).first {
                if let cap = mine.cap_credits {
                    capEnabled = true
                    capCredits = String(cap)
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Save

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }

        if isAdmin {
            struct BillingBody: Encodable {
                let mode: String
                let windowSeconds: Int
                let customShares: [String]?
            }
            await postVoid(
                path: "v1/groups/\(conversationId)/billing",
                body: BillingBody(
                    mode: "per_head",
                    windowSeconds: 86_400,
                    customShares: nil,
                ),
            )
            if error != nil { return }

            let targetPayers: Set<String> = {
                switch payerMode {
                case .all: return Set(members.map(\.id))
                case .some: return payerIds
                case .owner: return Set(members.filter { $0.role == "owner" }.map(\.id))
                }
            }()
            if targetPayers.isEmpty {
                error = "至少要有一个成员参与 A"
                return
            }
            struct ParticipatesBody: Encodable {
                let userId: String
                let participates: Bool
            }
            for member in members {
                await postVoid(
                    path: "v1/groups/\(conversationId)/participates",
                    body: ParticipatesBody(
                        userId: member.id,
                        participates: targetPayers.contains(member.id),
                    ),
                )
                if error != nil { return }
            }
        }

        struct CapBody: Encodable { let capCredits: Int? }
        let capValue: Int? = capEnabled
            ? Int(capCredits.trimmingCharacters(in: .whitespaces))
            : nil
        await postVoid(
            path: "v1/groups/\(conversationId)/cap",
            body: CapBody(capCredits: capValue),
        )
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
                throw NSError(
                    domain: "GroupBilling",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Models

    enum PayerMode: Hashable {
        case all, some, owner
    }

    struct BillingMember: Identifiable, Hashable {
        let id: String
        let name: String
        let role: String
    }

    private struct MineDecodable: Decodable {
        let user_id: String
        let cap_credits: Int?
        let participates: Bool
    }

    private struct ParticipantDecodable: Decodable {
        let participant_id: String
        let role: String
        let nickname: String?
    }

    private struct MemberBillingDecodable: Decodable {
        let user_id: String
        let participates: Bool
    }

    private func fetchMemberProfiles(userIds: [String]) async -> [String: String] {
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
                }
                let profiles: [Row]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return Dictionary(uniqueKeysWithValues: payload.profiles.map {
                ($0.userId, $0.displayName)
            })
        } catch {
            return [:]
        }
    }
}
#endif
