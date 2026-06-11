import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - CacheRepository — cross-platform write-back façade (T2.0 / §10)
//
// The single seam every view (iOS + iPad shared `Features/`, macOS `Mac/`)
// goes through to mutate or read the shared `LocalDatabase` GRDB cache for the
// entities NOT already covered by `ChatDataSource` (conversations + messages
// live there). Covers **bots / contacts / group members / group meta**.
//
// Why this exists (spec §10): the conv/message write-back was already collapsed
// into the shared `ChatDataSource`, so Mac inherited those caches for free. But
// bots/contacts/groupMembers/groupMeta write-back was still scattered across
// iOS-only `Features/` views calling `LocalDatabase.shared.replace*/upsert*`
// directly — and `Mac/` never wrote them back at all. GRDB is per-device
// (each platform install has its own file, they don't cross-fill), so a
// Mac-only install left those caches permanently empty = the "Mac 没缓存" gap.
//
// The fix is to funnel every cache mutation for these entities through here.
// Views keep building the canonical `LocalDatabase.*Row` shapes they already
// build (this façade intentionally takes those row types rather than
// re-deriving them from view-model types — that would duplicate the verified
// view-side resolution logic and risk regressing it); they just call this
// instead of `LocalDatabase` directly. Once both platforms drive the same
// façade, the entity's cache fills on whichever platform did the fetch.
//
// All methods are `@MainActor` to match `LocalDatabase`'s actor isolation;
// no `#if os(...)` — one implementation, both platforms.
//
// T2.1+ note: the L1→L2→L3 read ladder + delta-sync (CF edge projection) will
// hang off this same façade so all three platforms inherit it from one place,
// rather than wiring the read path per-platform three times.
// ─────────────────────────────────────────────────────────────────────

enum CacheRepository {
    // MARK: - Bots

    /// Cache-first bot list — last-known `bots` rows out of the shared GRDB
    /// cache for an instant first paint, before any network round-trip. The
    /// caller (friends tab) projects these into its own row model and applies
    /// its self-bot / sort filters. Mirrors the cache-first read `ChatDataSource`
    /// exposes for conversations.
    @MainActor
    static func cachedBots() -> [LocalDatabase.BotRow] {
        LocalDatabase.shared.loadBots()
    }

    /// Wholesale replace the cached bot list after a successful fetch — server
    /// is the source of truth for which bots are still active / visible, so a
    /// partial upsert would leave stale rows behind. Same contract as
    /// `LocalDatabase.replaceBots`; callers pass the canonical rows they already
    /// build from the fetch result. No-op the call from a failed fetch (keep the
    /// prior cache) by simply not calling this — identical to the prior inline
    /// guard in the views.
    @MainActor
    static func persistBots(_ rows: [LocalDatabase.BotRow]) {
        LocalDatabase.shared.replaceBots(rows)
    }

    // MARK: - Contacts

    /// Cache-first human-contacts list — last-known `contacts` rows for an
    /// instant first paint. Caller projects into its own contact model.
    @MainActor
    static func cachedContacts() -> [LocalDatabase.ContactRow] {
        LocalDatabase.shared.loadContacts()
    }

    /// Wholesale replace the cached contacts list after a successful fetch.
    /// Same source-of-truth / stale-row reasoning as `persistBots`.
    @MainActor
    static func persistContacts(_ rows: [LocalDatabase.ContactRow]) {
        LocalDatabase.shared.replaceContacts(rows)
    }

    // MARK: - Group members (roster)

    /// Cache-first group roster — last-known resolved members for the group,
    /// so opening a group chat or its settings paints names + avatars + role
    /// hierarchy instantly before the network round-trip that re-resolves them.
    @MainActor
    static func cachedGroupMembers(conversationId: String) -> [LocalDatabase.GroupMemberRow] {
        LocalDatabase.shared.loadGroupMembers(conversationId: conversationId)
    }

    /// Wholesale replace the cached roster for one conversation after a
    /// successful resolve. Server is authoritative for who's in the group, so
    /// this delete-then-insert (in one txn, via `LocalDatabase`) avoids stale
    /// rows after a member leaves. Callers pass the canonical rows they build
    /// alongside their view-model members.
    @MainActor
    static func persistGroupMembers(
        conversationId: String, _ rows: [LocalDatabase.GroupMemberRow]
    ) {
        LocalDatabase.shared.replaceGroupMembers(conversationId: conversationId, rows)
    }

    // MARK: - Group meta

    /// Cache-first group meta (title / join policy / max members / number
    /// handle) for one conversation, or nil when nothing cached yet.
    @MainActor
    static func cachedGroupMeta(conversationId: String) -> LocalDatabase.GroupMetaRow? {
        LocalDatabase.shared.loadGroupMeta(conversationId: conversationId)
    }

    /// Upsert the cached group meta row (primary-keyed on conversation_id, so
    /// this is a single-row save, not a wholesale replace). Same contract as
    /// `LocalDatabase.upsertGroupMeta`.
    @MainActor
    static func persistGroupMeta(_ row: LocalDatabase.GroupMetaRow) {
        LocalDatabase.shared.upsertGroupMeta(row)
    }
}
