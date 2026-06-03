import Foundation
import Supabase

// ─────────────────────────────────────────────────────────────────────
// MARK: - Shared bot-contacts fetch (iOS + macOS one implementation)
//
// The canonical `user_bot_contacts` query for the friends tab's bot list. iOS
// (`FriendsTabView.load()`, which adds a GRDB cache + self-bot/is_active filters
// + sort) and macOS (`FriendsDataSource.listBotContacts`, a thin projection) run
// the SAME query — same embed FK, same columns, same RLS scope — instead of two
// hand-copied variants that could drift.
//
// Returns the iOS superset (8 bot columns + added_at); macOS keeps only id /
// display_name / visibility. One query → 改一列两端一起改.
// ─────────────────────────────────────────────────────────────────────

/// One `user_bot_contacts` row with its embedded bot. `added_at` is the ISO 8601
/// contact-row timestamp driving the "按加好友时间" sort.
struct BotContactRow: Decodable {
    let added_at: String?
    let bot: Bot

    struct Bot: Decodable {
        let id: String
        let slug: String?
        let display_name: String
        let model_id: String?
        let visibility: String?
        let creator_id: String?
        let voice_call_enabled: Bool?
        let is_active: Bool?
    }
}

enum BotContactsFetch {
    /// Added bots (RLS-scoped to auth.uid()). The `!inner` embed drops rows whose
    /// bot was hard-deleted; soft-deleted (`is_active == false`) rows still come
    /// back and are filtered client-side. Ordered `added_at` ascending — iOS
    /// re-sorts client-side per the user's chosen FriendSort, macOS reverses for
    /// newest-first.
    static func list() async throws -> [BotContactRow] {
        try await SupabaseStack.shared
            .from("user_bot_contacts")
            .select("added_at, bot:bots!user_bot_contacts_bot_id_fkey!inner(id, slug, display_name, model_id, visibility, creator_id, voice_call_enabled, is_active)")
            .order("added_at", ascending: true)
            .execute()
            .value
    }
}
