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
// Returns the iOS superset (8 bot columns + added_at + 两个 config 子键);
// macOS keeps only id / display_name / visibility. One query → 改一列两端一起改.
// ─────────────────────────────────────────────────────────────────────

/// 「这个 JSON 值是不是一个对象」—— 只取这一个 bit,不把内容解回来。
///
/// 用来判断 `bots.config.modelPool` 在不在,而**不需要把整个 config 拉到
/// 客户端**(那里面还有系统提示词之类跟列表毫无关系的东西)。PostgREST 的
/// `alias:config->key` 只回传那一个子键,这个类型只看它是不是对象。
struct JSONObjectPresence: Decodable, Equatable {
    let isObject: Bool

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }

    init(from decoder: Decoder) throws {
        // 对象 → 拿得到 keyed container;数字/字符串/数组 → 拿不到。
        // JSON null 走不到这里(合成的 decodeIfPresent 先把它变成 nil)。
        isObject = (try? decoder.container(keyedBy: AnyKey.self)) != nil
    }
}

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
        /// `config.modelPool` —— 配了就是聚合 bot(每轮从池子里抽)。
        let model_pool: JSONObjectPresence?
        /// `config.arena` —— modelPool 之前的历史键名。服务端的
        /// `modelPoolConfigFromBotConfig` 两个都认,这里跟着认,免得老 bot
        /// 被当成单一模型又挂上一个假标签。
        let model_pool_legacy: JSONObjectPresence?

        /// 是不是聚合 bot。跟 edge `modelPoolConfigFromBotConfig` 同一条判据:
        /// 两个键里任意一个是 JSON 对象就算有池。
        var hasModelPool: Bool {
            (model_pool?.isObject ?? false) || (model_pool_legacy?.isObject ?? false)
        }
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
            .select("added_at, bot:bots!user_bot_contacts_bot_id_fkey!inner(id, slug, display_name, model_id, visibility, creator_id, voice_call_enabled, is_active, model_pool:config->modelPool, model_pool_legacy:config->arena)")
            .order("added_at", ascending: true)
            .execute()
            .value
    }
}
