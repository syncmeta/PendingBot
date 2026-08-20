import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform friends data source (macOS 好友 tab)
//
// Read + inbox-action surface for the 好友 tab on macOS PendingBot. iOS's
// friends fetch lives in the iOS-only `ContactsAPI` (returns
// `FriendsTabView.HumanPick`, a UIKit-coupled view type) + inline supabase /
// worker calls in `FriendsTabView`, so this is a gate-free service reusing the
// SAME endpoints / queries with light value models.
//
// Backend is shared, never re-implemented: bots/contacts go through the shared
// `BotContactsFetch` / `ContactsFetch`; friend-request + group-invitation
// list/respond mirror the exact iOS worker calls (same URLs, same JSON shapes)
// so the macOS friends IA (单列 + filter + sort + 申请/邀请分区) matches iOS.
//
// FK names + select columns are copied verbatim from the verified iOS
// `FriendsTabView` (`user_bot_contacts_bot_id_fkey`, RLS-scoped to auth.uid()).
// ─────────────────────────────────────────────────────────────────────

struct HumanContact: Identifiable, Equatable, Hashable {
    let id: String            // userId
    let displayName: String
    let alias: String?
    /// Worker upload path for the real avatar image (nil = use emoji placeholder).
    let avatarPath: String?
    /// Stable emoji-placeholder seed (defaults to userId).
    let avatarSeed: String
    /// Friend-added time (epoch seconds, `user_contacts.created_at`). 0 when the
    /// worker build predates the field. Drives the "按加好友时间" sort.
    var addedAt: Int = 0

    var shownName: String {
        if let alias, !alias.isEmpty { return alias }
        return displayName.isEmpty ? id : displayName
    }
}

struct BotContact: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    /// `private` | `public_invite` (nil on older rows).
    let visibility: String?
    /// Stored model slug (`bots.model_id`); resolved to a friendly name + price
    /// multiplier via `ModelCatalog` for the inline row tag. nil = no tag.
    var modelId: String? = nil
    /// Bot creator (`bots.creator_id`); nil for preset bots. Used to gate the
    /// "管理机器人" affordance to the creator.
    var creatorId: String? = nil
    /// When this bot was added (`user_bot_contacts.added_at`, epoch seconds).
    /// 0 when unknown. Drives the "按加好友时间" sort.
    var addedAt: Int = 0
}

/// One pending incoming friend request, trimmed to what the inline accept /
/// decline row needs. Mirrors iOS `FriendsTabView.PendingFriendRequest`.
struct FriendRequestContact: Identifiable, Equatable, Hashable {
    let id: String
    let peerUserId: String
    let peerDisplayName: String
    let message: String?
    /// Server-supplied placeholder-emoji seed; falls back to peerUserId.
    let peerAvatarSeed: String
}

/// One pending group invitation. Mirrors iOS `FriendsTabView.PendingGroupInvitation`.
struct GroupInvitationContact: Identifiable, Equatable, Hashable {
    let id: String
    let conversationId: String
    let groupTitle: String
    let inviterName: String
    let inviterAvatarSeed: String
    let inviterAvatarPath: String?
    let billingText: String
}

enum FriendsDataSource {
    /// Human friends via the shared `ContactsFetch.fetch()` (`GET /v1/contacts`)
    /// — same request+decode as iOS's `ContactsAPI`, projected to the thin macOS
    /// contact (id / displayName / alias). No hand-copied request here anymore.
    static func listHumanContacts() async throws -> [HumanContact] {
        try await ContactsFetch.fetch().map {
            HumanContact(id: $0.userId, displayName: $0.displayName, alias: $0.alias,
                         avatarPath: $0.avatarPath, avatarSeed: $0.avatarSeed ?? $0.userId,
                         addedAt: $0.addedAt ?? 0)
        }
    }

    /// Bot friends from `user_bot_contacts` (added bots only, RLS-scoped). Runs
    /// the SAME query as iOS's `FriendsTabView.load()` via the shared
    /// `BotContactsFetch.list()` — no hand-copied query — then keeps the columns
    /// the macOS list renders. Filters soft-deleted bots (is_active == false) and
    /// the self-bot to match iOS; reverses for newest-first (shared fetch is
    /// added_at ascending).
    static func listBotContacts() async throws -> [BotContact] {
        let rows = try await BotContactsFetch.list()
        return rows
            .filter { $0.bot.is_active != false }
            .filter { !($0.bot.slug?.hasPrefix("self-") ?? false) }
            .reversed()
            .map { row in
                BotContact(
                    id: row.bot.id,
                    displayName: row.bot.display_name.isEmpty ? "未命名机器人" : row.bot.display_name,
                    visibility: row.bot.visibility,
                    modelId: row.bot.model_id,
                    creatorId: row.bot.creator_id,
                    addedAt: row.added_at.map { ServerTimestamp.epochSeconds($0, default: 0) } ?? 0
                )
            }
    }

    /// The caller's existing 1:1 conversation with a bot, if any. RLS scopes
    /// `conversations` to the current user, so this returns *my* user_bot
    /// conversation for that bot. nil = no conversation yet (Mac 第一版不在此
    /// 处建会话,UI 提示去手机端先聊一次)。
    static func findBotConversation(botId: String) async throws -> String? {
        struct Row: Decodable { let id: String }
        let rows: [Row] = try await SupabaseStack.shared
            .from("conversations")
            .select("id")
            .eq("bot_id", value: botId)
            .eq("conversation_type", value: "user_bot")
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    // ── Friend requests (incoming inbox) ────────────────────────────────────
    //
    // Same worker calls as iOS `FriendsTabView.loadIncomingFriendRequests` /
    // `respondToRequest` — `GET /v1/friend-requests?direction=incoming` and
    // `POST /v1/friend-requests/<id>/(accept|decline)`. Bearer-authed plain
    // URLSession calls, no UIKit, so they live in the shared data source.

    static func listIncomingFriendRequests() async throws -> [FriendRequestContact] {
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/friend-requests")
            .appending(queryItems: [URLQueryItem(name: "direction", value: "incoming")])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return [] }
        struct Payload: Decodable {
            struct Row: Decodable {
                let id: String
                let status: String
                let message: String?
                let peerUserId: String
                let peerDisplayName: String
                let peerAvatarSeed: String?
            }
            let requests: [Row]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.requests
            .filter { $0.status == "pending" }
            .map { r in
                let name = r.peerDisplayName.isEmpty
                    ? String(r.peerUserId.prefix(8)) : r.peerDisplayName
                return FriendRequestContact(
                    id: r.id, peerUserId: r.peerUserId,
                    peerDisplayName: name, message: r.message,
                    peerAvatarSeed: r.peerAvatarSeed ?? r.peerUserId
                )
            }
    }

    /// Accept / decline a friend request. Throws on a non-2xx so the caller can
    /// surface the failure; the caller is expected to refresh the list after.
    static func respondToFriendRequest(id: String, accept: Bool) async throws {
        let action = accept ? "accept" : "decline"
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/friend-requests/\(id)/\(action)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }
    }

    // ── Group invitations (incoming) ────────────────────────────────────────
    //
    // Same worker calls as iOS `FriendsTabView.loadIncomingGroupInvitations` /
    // `respondToGroupInvitation` — `GET /v1/groups/invitations` and
    // `POST /v1/groups/invitations/<id>/decide`.

    static func listIncomingGroupInvitations() async throws -> [GroupInvitationContact] {
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/groups/invitations")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return [] }
        struct Payload: Decodable {
            struct Row: Decodable {
                struct Inviter: Decodable {
                    let display_name: String
                    let avatar_path: String?
                    let avatar_seed: String?
                }
                struct Billing: Decodable { let text: String? }
                let id: String
                let conversation_id: String
                let status: String
                let group_title: String
                let billing_snapshot: Billing?
                let inviter: Inviter
            }
            let invitations: [Row]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.invitations
            .filter { $0.status == "pending" }
            .map { row in
                GroupInvitationContact(
                    id: row.id,
                    conversationId: row.conversation_id,
                    groupTitle: row.group_title,
                    inviterName: row.inviter.display_name.isEmpty ? "群成员" : row.inviter.display_name,
                    inviterAvatarSeed: row.inviter.avatar_seed ?? row.conversation_id,
                    inviterAvatarPath: row.inviter.avatar_path,
                    billingText: row.billing_snapshot?.text ?? "接受后会按当前群设置参与机器人 Token 分摊。"
                )
            }
    }

    /// Accept (approve == true) / decline a group invitation. Throws on non-2xx.
    static func respondToGroupInvitation(id: String, accept: Bool) async throws {
        struct Body: Encodable { let approve: Bool }
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/groups/invitations/\(id)/decide")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(approve: accept))
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }
    }
}
