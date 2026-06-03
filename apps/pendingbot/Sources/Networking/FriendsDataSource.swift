import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Cross-platform friends data source (T0.1 macOS 好友 tab)
//
// Minimal read surface for the 好友 tab on macOS PendingBot. iOS's friends
// fetch lives in the iOS-only `ContactsAPI` (returns `FriendsTabView.HumanPick`,
// a UIKit-coupled view type) + inline supabase queries in `FriendsTabView`, so
// this is a fresh gate-free service reusing the same endpoints / queries with
// light value models. 第一版: list only (人类好友 + 已加 bot);点击进会话 /
// 头像图片 / 加好友流程 / 排序菜单 留 follow-up(见 #212）。
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
}

enum FriendsDataSource {
    /// Human friends via the shared `ContactsFetch.fetch()` (`GET /v1/contacts`)
    /// — same request+decode as iOS's `ContactsAPI`, projected to the thin macOS
    /// contact (id / displayName / alias). No hand-copied request here anymore.
    static func listHumanContacts() async throws -> [HumanContact] {
        try await ContactsFetch.fetch().map {
            HumanContact(id: $0.userId, displayName: $0.displayName, alias: $0.alias,
                         avatarPath: $0.avatarPath, avatarSeed: $0.avatarSeed ?? $0.userId)
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
            .map { BotContact(id: $0.bot.id,
                              displayName: $0.bot.display_name.isEmpty ? "未命名机器人" : $0.bot.display_name,
                              visibility: $0.bot.visibility) }
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
}
