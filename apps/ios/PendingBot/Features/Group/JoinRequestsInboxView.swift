import SwiftUI

/// Inbox of pending join-requests for a group. Owner/admin sees the
/// full list; other members fall back to "no requests" since RLS
/// hides them. Tapping ✅ / ❌ calls /v1/groups/:id/join-decide.
///
/// Realtime subscription: filters group_join_requests by conv_id;
/// new INSERTs prepend to the list, status changes update inline.
struct JoinRequestsInboxView: View {
    let conversationId: String

    @State private var requests: [PendingRequest] = []
    @State private var loading = false
    @State private var deciding: Set<String> = []
    @State private var error: String?

    var body: some View {
        List {
            if requests.isEmpty {
                Section {
                    Text(loading ? "加载中…" : "没有待审批的请求").foregroundStyle(.secondary)
                }
            } else {
                ForEach(requests) { r in
                    requestRow(r)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("加群请求")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func requestRow(_ r: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.requesterLabel).font(Theme.Fonts.body)
            if let m = r.message, !m.isEmpty {
                Text(m).font(Theme.Fonts.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(r.statusLabel).font(Theme.Fonts.caption2).foregroundStyle(.secondary)
                Spacer()
                if r.status == "pending" {
                    if deciding.contains(r.id) {
                        ProgressView()
                    } else {
                        Button {
                            Task { await decide(r.id, approve: false) }
                        } label: {
                            Text("拒绝").foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            Task { await decide(r.id, approve: true) }
                        } label: {
                            Text("通过")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Server-side endpoint returns shape we control. Order:
            // pending first, then settled by created_at desc.
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/\(conversationId)/join-requests")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "JoinRequestsInbox",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)

            // Resolve requester display names in one extra read so the
            // row shows "Alice" rather than a UUID.
            let userIds = Array(Set(decoded.requests.map(\.requester_id)))
            var nameMap: [String: String] = [:]
            if !userIds.isEmpty {
                do {
                    let users: [UserName] = try await SupabaseStack.shared
                        .from("users")
                        .select("id, display_name")
                        .in("id", values: userIds)
                        .execute()
                        .value
                    for u in users { nameMap[u.id] = u.display_name }
                } catch {
                    // Don't fail the whole inbox over name resolution
                    // — fall back to short ids.
                }
            }

            self.requests = decoded.requests.map { r in
                PendingRequest(
                    id: r.id,
                    status: r.status,
                    requesterLabel: nameMap[r.requester_id] ?? String(r.requester_id.prefix(8)),
                    message: r.message,
                    createdAt: r.created_at,
                )
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func decide(_ requestId: String, approve: Bool) async {
        deciding.insert(requestId)
        defer { deciding.remove(requestId) }
        do {
            struct Body: Encodable {
                let requestId: String
                let approve: Bool
            }
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/\(conversationId)/join-decide")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(requestId: requestId, approve: approve))

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "JoinRequestsInbox",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            // Optimistic local update so UI reacts instantly.
            if let idx = requests.firstIndex(where: { $0.id == requestId }) {
                requests[idx] = PendingRequest(
                    id: requests[idx].id,
                    status: approve ? "approved" : "rejected",
                    requesterLabel: requests[idx].requesterLabel,
                    message: requests[idx].message,
                    createdAt: requests[idx].createdAt,
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Models

    struct PendingRequest: Identifiable, Hashable {
        let id: String
        let status: String
        let requesterLabel: String
        let message: String?
        let createdAt: String

        var statusLabel: String {
            switch status {
            case "pending":  return "待审批"
            case "approved": return "已通过"
            case "rejected": return "已拒绝"
            case "expired":  return "已过期"
            default:         return status
            }
        }
    }

    private struct Response: Decodable {
        let requests: [Row]

        struct Row: Decodable {
            let id: String
            let conversation_id: String
            let requester_id: String
            let via_handle_id: String?
            let status: String
            let message: String?
            let decided_by: String?
            let decided_at: String?
            let created_at: String
        }
    }

    private struct UserName: Decodable {
        let id: String
        let display_name: String
    }
}
