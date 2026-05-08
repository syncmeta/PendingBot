import SwiftUI

/// Create-a-group flow. User enters a title (optional), picks initial human
/// members from their contacts, and initial bots from the ones they have
/// conversations with. POSTs /v1/groups; on success, navigates into the
/// new group conversation.
///
/// File is intentionally self-contained (no shared API layer) — mirrors
/// FriendsTabView's inline pattern for adding contacts. Once we add more
/// group endpoints from iOS, factor out a `GroupsAPI` helper.
struct GroupCreationView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the new conversation_id once creation succeeds. Caller
    /// uses this to push the chat view onto the nav stack.
    let onCreated: (String) -> Void

    @State private var title: String = ""

    /// Pre-loaded picker data — humans + bots the user already knows.
    @State private var humans: [HumanPick] = []
    @State private var bots: [BotPick] = []

    @State private var selectedHumanIds: Set<String> = []
    @State private var selectedBotIds: Set<String> = []

    @State private var loading = false
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("群名(可选)") {
                    TextField("例如:产品讨论组", text: $title)
                        .textInputAutocapitalization(.never)
                }

                Section(header: Text("拉哪些人(\(selectedHumanIds.count))")) {
                    if humans.isEmpty {
                        Text(loading ? "加载中…" : "你还没有联系人")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(humans) { h in
                            HStack {
                                Text(h.alias?.isEmpty == false ? h.alias! : h.id.prefix(8) + "…")
                                Spacer()
                                if selectedHumanIds.contains(h.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggleHuman(h.id) }
                        }
                    }
                }

                Section(header: Text("拉哪些机器人(\(selectedBotIds.count))")) {
                    let invitable = bots.filter { $0.visibility != "private" }
                    if invitable.isEmpty {
                        Text(loading ? "加载中…" : "暂无可邀机器人(私有 bot 不能进群)")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(invitable) { b in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.display_name)
                                    if let v = b.visibility {
                                        Text(v == "public_invite" ? "邀请制" : "公开")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedBotIds.contains(b.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggleBot(b.id) }
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if submitting {
                            HStack { ProgressView(); Text("创建中…") }
                        } else {
                            Text("创建群聊").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(submitting || (selectedHumanIds.isEmpty && selectedBotIds.isEmpty))
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let botResp: [BotDecodable] = SupabaseStack.shared
                .from("bots")
                .select("id, display_name, visibility")
                .eq("is_active", value: true)
                .order("created_at", ascending: true)
                .execute()
                .value
            async let contactResp: [ContactDecodable] = SupabaseStack.shared
                .from("user_contacts")
                .select("contact_user_id, alias")
                .order("created_at", ascending: true)
                .execute()
                .value

            self.bots = try await botResp.map {
                BotPick(id: $0.id, display_name: $0.display_name, visibility: $0.visibility)
            }
            self.humans = try await contactResp.map {
                HumanPick(id: $0.contact_user_id, alias: $0.alias)
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Selection

    private func toggleHuman(_ id: String) {
        if selectedHumanIds.contains(id) {
            selectedHumanIds.remove(id)
        } else {
            // 100-member cap is enforced server-side too; clamp here for
            // a kind UX (creator + selected ≤ 100).
            if selectedHumanIds.count + selectedBotIds.count >= 99 { return }
            selectedHumanIds.insert(id)
        }
    }

    private func toggleBot(_ id: String) {
        if selectedBotIds.contains(id) {
            selectedBotIds.remove(id)
        } else {
            if selectedHumanIds.count + selectedBotIds.count >= 99 { return }
            selectedBotIds.insert(id)
        }
    }

    // MARK: - Submit

    private func create() async {
        submitting = true
        error = nil
        defer { submitting = false }

        do {
            let url = HostedConfig.environment.workerURL.appendingPathComponent("v1/groups")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let body = CreateBody(
                title: title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title,
                memberUserIds: Array(selectedHumanIds),
                memberBotIds: Array(selectedBotIds)
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(domain: "GroupCreate", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            let decoded = try JSONDecoder().decode(CreateResponse.self, from: data)
            onCreated(decoded.conversationId)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Models

    struct HumanPick: Identifiable, Hashable {
        let id: String
        let alias: String?
    }

    struct BotPick: Identifiable, Hashable {
        let id: String
        let display_name: String
        let visibility: String?
    }

    private struct ContactDecodable: Decodable {
        let contact_user_id: String
        let alias: String?
    }

    private struct BotDecodable: Decodable {
        let id: String
        let display_name: String
        let visibility: String?
    }

    private struct CreateBody: Encodable {
        let title: String?
        let memberUserIds: [String]
        let memberBotIds: [String]
    }

    private struct CreateResponse: Decodable {
        let conversationId: String
    }
}
