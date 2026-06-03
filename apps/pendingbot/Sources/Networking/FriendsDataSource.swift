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
    /// `GET /v1/contacts` — human friends. Worker returns camelCase
    /// `{ contacts: [{ userId, displayName, alias? , ... }] }`.
    static func listHumanContacts() async throws -> [HumanContact] {
        struct Resp: Decodable {
            let contacts: [Row]
            struct Row: Decodable {
                let userId: String
                let alias: String?
                let displayName: String
            }
        }
        let r: Resp = try await APIClient().get("v1/contacts")
        return r.contacts.map { HumanContact(id: $0.userId, displayName: $0.displayName, alias: $0.alias) }
    }

    /// Bot friends from `user_bot_contacts` (added bots only, RLS-scoped). The
    /// `!inner` embed drops rows whose bot was deleted/deactivated.
    static func listBotContacts() async throws -> [BotContact] {
        struct Row: Decodable {
            let bot: BotEmbed?
            struct BotEmbed: Decodable {
                let id: String
                let display_name: String?
                let visibility: String?
            }
        }
        let rows: [Row] = try await SupabaseStack.shared
            .from("user_bot_contacts")
            .select("bot:bots!user_bot_contacts_bot_id_fkey!inner(id, display_name, visibility)")
            .order("added_at", ascending: false)
            .execute()
            .value
        return rows.compactMap { row in
            row.bot.map {
                BotContact(id: $0.id, displayName: $0.display_name ?? "未命名机器人", visibility: $0.visibility)
            }
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
}
