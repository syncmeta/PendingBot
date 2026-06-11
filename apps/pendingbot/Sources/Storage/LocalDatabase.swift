import Foundation
import GRDB
import OSLog

private let log = Logger.category("LocalDatabase")

private enum LocalDatabaseEncryptionError: LocalizedError {
    case sqlCipherUnavailable

    var errorDescription: String? {
        "SQLCipher is required but the active GRDB build is not linked against it."
    }
}

/// On-device SQLite cache for the current user's conversations + messages.
///
/// Per plan/04: mirrors the Supabase schema's hot tables so the app
/// renders the last-known state instantly on launch and stays usable
/// offline. Sync is one-way trust:
///   - server is the source of truth for `created_at` ordering
///   - local uses `client_message_id` as the dedup key for upserts
///     (matches the canonical row when Realtime / loadHistory delivers it)
///
/// Single-user-per-device — no per-account scoping in the file path; on
/// sign-out we wipe the DB.
///
/// ## Encryption (SQLCipher)
///
/// `DatabaseQueue` is opened with a `prepareDatabase` hook that issues
/// `PRAGMA key = '…'` against a 256-bit random passphrase stored in
/// Keychain (device-only, no iCloud sync). The app links a SQLCipher-enabled
/// GRDB SPM target, so the database file is encrypted at rest. The open path
/// also checks `PRAGMA cipher_version` and fails closed if GRDB ever resolves
/// back to plain SQLite.
///
/// `PRAGMA key` is the canonical SQLCipher setup call and must precede any
/// other operation on the connection. After it succeeds the DB file on disk is
/// encrypted; without the key the file decodes as random noise.
///
/// First-launch-after-flipping handling: when a pre-encryption plaintext
/// DB file already exists on disk, SQLCipher will fail to open it with
/// the key (file-format mismatch surfaces as a corrupt/IO error). The
/// existing two-tier recovery below catches that and recreates an
/// encrypted file from scratch. Acceptable for pre-launch where the
/// only data is the user's own testing — documented explicitly so the
/// behaviour isn't a surprise.
@MainActor
final class LocalDatabase {
    static let shared = LocalDatabase()

    /// `var` (not `let`) so `wipeForSignOut()` can tear the connection down
    /// and swap in a freshly-keyed one. No external code touches it directly
    /// — all access goes through the methods below — so mutating it is safe.
    private(set) var dbQueue: DatabaseQueue

    private init() {
        self.dbQueue = Self.openWithRecovery()
    }

    /// Open the on-disk encrypted DB, with the two-tier recovery cascade,
    /// falling back to in-memory if the disk is genuinely unusable. Mints a
    /// passphrase via `loadOrCreatePassphrase()` (reusing the Keychain one if
    /// present), so calling this after deleting the Keychain entry yields a
    /// brand-new key + file. Shared by `init` and `wipeForSignOut()`.
    private static func openWithRecovery() -> DatabaseQueue {
        let url = databaseURL()
        let key = loadOrCreatePassphrase()
        let config = makeConfiguration(passphrase: key)

        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try migrator.migrate(queue)
            protectDatabaseFile(at: url)
            return queue
        } catch LocalDatabaseEncryptionError.sqlCipherUnavailable {
            fatalError("LocalDatabase: SQLCipher is not active; refusing to open an unencrypted on-disk cache")
        } catch {
            // First-resort recovery: nuke a possibly-corrupt OR
            // wrong-format file (incl. WAL/SHM sidecars) and retry.
            // Triggers on the plaintext→encrypted flip too — a legacy
            // plaintext DB file fails to open when SQLCipher applies the
            // key, and we'd rather start fresh than crash.
            removeDatabaseFiles(at: url)
        }
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try migrator.migrate(queue)
            protectDatabaseFile(at: url)
            return queue
        } catch LocalDatabaseEncryptionError.sqlCipherUnavailable {
            fatalError("LocalDatabase: SQLCipher is not active; refusing to open an unencrypted on-disk cache")
        } catch {
            // Disk is genuinely broken (full disk, sandbox issue, etc.).
            // Fall back to an in-memory DB so the app still launches —
            // user loses offline cache + history persistence between
            // launches but everything else works.
            log.error("disk init failed twice — falling back to in-memory: \(error.localizedDescription, privacy: .public)")
        }
        // In-memory init has no I/O so the only error path here would be
        // an internal GRDB precondition; treat as unrecoverable.
        let memQueue = (try? DatabaseQueue(configuration: config)) ?? {
            fatalError("LocalDatabase: in-memory DatabaseQueue() failed — unrecoverable")
        }()
        try? migrator.migrate(memQueue)
        return memQueue
    }

    private static func databaseURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: dir.path
        )
        return dir.appendingPathComponent("pendingbot.sqlite")
    }

    private static func protectDatabaseFile(at url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
    }

    /// Delete the DB file AND its WAL/SHM sidecars. SQLCipher writes recent
    /// pages into the `-wal` journal before checkpointing into the main file,
    /// so removing only `pendingbot.sqlite` would leave un-checkpointed
    /// ciphertext behind in `-wal`. Decryptable by anyone holding the
    /// passphrase — hence we always nuke all three together.
    private static func removeDatabaseFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: url.path + suffix)
        }
    }

    // MARK: - Encryption passphrase

    /// Keychain account name for the local DB passphrase. The Keychain
    /// service is the app's bundle id (see Keychain.service); the
    /// account scopes within that. The value is device-only (no iCloud
    /// sync). `wipeForSignOut()` deletes this entry on sign-out and the
    /// reopen mints a fresh one, so each signed-in session runs under its
    /// own key — the prior user's key never carries over.
    ///
    /// Note iOS keeps Keychain entries across app *uninstall*, so an
    /// orphaned passphrase may linger after the app is deleted — harmless,
    /// because uninstall also wipes the app container (the DB file it would
    /// decrypt). A reinstall just mints over it on first launch.
    private static let dbPassphraseAccount = "local-db-passphrase-v1"

    private static func loadOrCreatePassphrase() -> String {
        if let existing = Keychain.get(account: dbPassphraseAccount),
           !existing.isEmpty {
            return existing
        }
        // 32 random bytes → hex string. 256 bits of entropy, well
        // above any practical brute-force threshold. Hex (rather than
        // base64) keeps the PRAGMA SQL escape-free.
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let pass: String
        if status == errSecSuccess {
            pass = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            // Vanishingly unlikely, but fall back to UUID-based key so
            // we never leave the DB un-keyed once SQLCipher is on.
            log.error("SecRandomCopyBytes failed (\(status, privacy: .public)) — falling back to UUID-based passphrase")
            pass = UUID().uuidString + UUID().uuidString
        }
        do {
            try Keychain.set(pass, account: dbPassphraseAccount)
        } catch {
            log.error("failed to persist DB passphrase to Keychain: \(error.localizedDescription, privacy: .public)")
            // Keep going with the in-memory passphrase — better than
            // crashing. Next launch will mint a new one and the cache
            // will be unreadable; we'll fall through to the recovery
            // path and start clean.
        }
        return pass
    }

    private static func makeConfiguration(passphrase: String) -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            // SQLCipher requires PRAGMA key BEFORE any other operation.
            // Quoted with single quotes; passphrase is hex so no escaping needed.
            try db.execute(sql: "PRAGMA key = '\(passphrase)'")
            guard let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version"),
                  !cipherVersion.isEmpty else {
                throw LocalDatabaseEncryptionError.sqlCipherUnavailable
            }
        }
        return config
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("bot_id", .text).indexed()
                t.column("user_id", .text)
                t.column("title", .text)
                t.column("conversation_type", .text)
                t.column("feature", .text)
                t.column("round_count", .integer).defaults(to: 0)
                // Seconds since epoch — matches the Conversation model the
                // view layer already uses; saves an ISO parse on every read.
                t.column("last_activity_at", .integer).indexed().defaults(to: 0)
            }
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("client_message_id", .text).unique()
                t.column("conversation_id", .text).indexed().notNull()
                t.column("user_id", .text)
                t.column("sender_bot_id", .text)
                t.column("role", .text).notNull()
                t.column("content", .text)
                t.column("status", .text)
                t.column("created_at", .integer).indexed().defaults(to: 0)
            }
        }
        // Cache the conv-row preview text + bot display name so the
        // first-paint hydrate doesn't fall through to the bare bot uuid
        // (was showing as a long green ID badge before the network
        // fetch resolved).
        m.registerMigration("v2_conv_preview_columns") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "bot_name", .text)
                t.add(column: "last_message_content", .text)
                t.add(column: "last_message_sender_type", .text)
            }
        }
        // Cache the friends list (bots + human contacts) so the friends
        // tab paints last-known state instantly on entry instead of
        // flashing empty until the network round-trip lands.
        m.registerMigration("v3_friends_cache") { db in
            try db.create(table: "bots") { t in
                t.column("id", .text).primaryKey()
                t.column("display_name", .text).notNull()
                t.column("model_id", .text)
                t.column("visibility", .text)
                t.column("creator_id", .text)
            }
            try db.create(table: "contacts") { t in
                t.column("id", .text).primaryKey()
                t.column("alias", .text)
                t.column("display_name", .text).notNull().defaults(to: "")
                t.column("avatar_path", .text)
            }
        }
        // Placeholder-emoji seed is now server-supplied (worker reads
        // users.custom_fields.avatar_seed) so it agrees across every
        // viewer; cache it alongside the rest of the contact row.
        m.registerMigration("v4_contacts_avatar_seed") { db in
            try db.alter(table: "contacts") { t in
                t.add(column: "avatar_seed", .text)
            }
        }
        m.registerMigration("v5_bots_voice_call_enabled") { db in
            try db.alter(table: "bots") { t in
                t.add(column: "voice_call_enabled", .boolean)
            }
        }
        // Cache resolved group state per conversation so opening a group
        // chat or its settings page paints last-known members instantly,
        // instead of flashing empty for the network round-trip it takes
        // to assemble participants + bot names + worker-side profiles.
        m.registerMigration("v6_group_cache") { db in
            try db.create(table: "group_members") { t in
                t.column("conversation_id", .text).notNull().indexed()
                t.column("participant_type", .text).notNull()
                t.column("participant_id", .text).notNull()
                t.column("nickname", .text)
                t.column("role", .text)
                t.column("display_name", .text).notNull().defaults(to: "")
                t.column("avatar_path", .text)
                t.column("avatar_seed", .text)
                t.column("frozen", .boolean).notNull().defaults(to: false)
                t.primaryKey(["conversation_id", "participant_type", "participant_id"])
            }
            try db.create(table: "group_meta") { t in
                t.column("conversation_id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("join_policy", .text).notNull().defaults(to: "")
                t.column("max_members", .integer).notNull().defaults(to: 0)
                t.column("number_handle", .text).notNull().defaults(to: "")
            }
        }
        // Friend-added time (epoch seconds) for bots + human contacts so the
        // "按加好友时间" sort is correct on the first cached paint, before the
        // network refresh lands. 0 for rows persisted before this migration.
        m.registerMigration("v7_friend_added_at") { db in
            try db.alter(table: "bots") { t in
                t.add(column: "added_at", .integer).defaults(to: 0)
            }
            try db.alter(table: "contacts") { t in
                t.add(column: "added_at", .integer).defaults(to: 0)
            }
        }
        // Cache the arena fields so a multi-answer turn paints as its
        // collapsed compare card on first hydrate, instead of flashing the
        // raw variant bubbles until the server round-trip regroups them.
        m.registerMigration("v8_message_arena_fields") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "parent_message_id", .text)
                t.add(column: "bubble_group_id", .text)
                t.add(column: "model_slug", .text)
            }
        }
        m.registerMigration("v9_message_seq") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "message_seq", .integer)
            }
            try db.create(index: "idx_messages_conversation_seq",
                          on: "messages",
                          columns: ["conversation_id", "message_seq"])
        }
        // The per-member freeze model (group_member_billing.overdrawn) was
        // retired server-side along with its table; the cached flag has no
        // writer or reader anymore.
        m.registerMigration("v10_drop_group_member_frozen") { db in
            try db.alter(table: "group_members") { t in
                t.drop(column: "frozen")
            }
        }
        return m
    }

    /// Hard-wipe the cache on sign-out. Stronger than a `DELETE FROM` sweep:
    /// a logical delete leaves the prior user's rows as recoverable ciphertext
    /// in the file's freelist / WAL, and the key that decrypts them keeps
    /// sitting in the Keychain. Instead we:
    ///   1. tear down the live connection (so the OS releases the file lock),
    ///   2. delete the DB file + WAL/SHM sidecars,
    ///   3. rotate the SQLCipher passphrase (delete the Keychain entry) so any
    ///      forensic copy of the old ciphertext is undecryptable even if its
    ///      key had been captured,
    ///   4. reopen a fresh, newly-keyed encrypted DB.
    /// After this the next user starts on a clean file under a new key.
    func wipeForSignOut() {
        let url = Self.databaseURL()
        // (1) Drop the on-disk queue. Pointing `dbQueue` at a throwaway
        // in-memory DB releases the last strong ref to the disk queue, whose
        // deinit closes the sqlite handle and frees the file/WAL lock — a
        // prerequisite for deleting the sidecars cleanly. The transient queue
        // is keyed with the still-present passphrase; its contents never
        // persist, so the key value is irrelevant.
        let transientConfig = Self.makeConfiguration(passphrase: Self.loadOrCreatePassphrase())
        if let mem = try? DatabaseQueue(configuration: transientConfig) {
            dbQueue = mem
        }
        // (2) Remove the encrypted file and its journal sidecars.
        Self.removeDatabaseFiles(at: url)
        // (3) Rotate the key: drop the Keychain passphrase so the reopen mints
        // a new one rather than reusing the key that decrypted the old data.
        Keychain.delete(account: Self.dbPassphraseAccount)
        // (4) Reopen fresh — openWithRecovery generates a new passphrase +
        // encrypted file via loadOrCreatePassphrase.
        dbQueue = Self.openWithRecovery()
    }

    // MARK: - Conversations

    struct ConversationRow: Codable, FetchableRecord, PersistableRecord {
        var id: String
        var bot_id: String?
        var user_id: String?
        var title: String?
        var conversation_type: String?
        var feature: String?
        var round_count: Int?
        var last_activity_at: Int
        var bot_name: String?
        var last_message_content: String?
        var last_message_sender_type: String?

        static let databaseTableName = "conversations"
    }

    func loadConversations() -> [ConversationRow] {
        (try? dbQueue.read { db in
            try ConversationRow
                .order(Column("last_activity_at").desc)
                .fetchAll(db)
        }) ?? []
    }

    func upsertConversations(_ rows: [ConversationRow]) {
        try? dbQueue.write { db in
            for r in rows { try r.save(db) }
        }
    }

    /// Patch just the conv-list preview fields (last message text + sender
    /// + activity time) for an existing cached conversation. Called at the
    /// end of a chat turn so the message-list's first paint on next launch
    /// isn't a turn behind. No-op when the row isn't cached yet (a brand
    /// new conv the list refresh hasn't persisted) — the next list load
    /// will create it. `last_activity_at` only moves forward so an
    /// out-of-order write can't shuffle the row backward.
    func touchConversationPreview(
        id: String,
        lastContent: String,
        lastSenderType: String,
        lastActivityAt: Int
    ) {
        try? dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                       SET last_message_content = ?,
                           last_message_sender_type = ?,
                           last_activity_at = MAX(last_activity_at, ?)
                     WHERE id = ?
                    """,
                arguments: [lastContent, lastSenderType, lastActivityAt, id]
            )
        }
    }

    func deleteConversation(id: String) {
        try? dbQueue.write { db in
            _ = try ConversationRow.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id = ?", arguments: [id])
        }
    }

    // MARK: - Messages

    struct MessageRow: Codable, FetchableRecord, PersistableRecord {
        var id: String
        var client_message_id: String?
        var conversation_id: String
        var user_id: String?
        var sender_bot_id: String?
        var role: String
        var content: String?
        var status: String?
        var created_at: Int
        var message_seq: Int? = nil
        var parent_message_id: String?
        var bubble_group_id: String?
        var model_slug: String?

        static let databaseTableName = "messages"
    }

    /// Latest `limit` rows for the conversation, returned in chronological
    /// (ascending) order. Fetches descending so a cache that has drifted
    /// past `limit` rows (realtime / prefetch upserts accumulate between
    /// loadHistory's wholesale replaces) hydrates the RECENT window, not
    /// the oldest — matching loadHistory's latest-200 server fetch.
    func loadMessages(conversationId: String, limit: Int = 200) -> [MessageRow] {
        let rows = (try? dbQueue.read { db in
            try MessageRow.fetchAll(
                db,
                sql: """
                    SELECT *
                      FROM messages
                     WHERE conversation_id = ?
                     ORDER BY COALESCE(message_seq, 9223372036854775807) DESC,
                              created_at DESC,
                              id DESC
                     LIMIT ?
                    """,
                arguments: [conversationId, limit]
            )
        }) ?? []
        return Array(rows.reversed())
    }

    /// Incremental upsert for the realtime / prefetch paths. `save()` keys
    /// on the primary key `id`, but a message's identity across the
    /// optimistic→canonical handoff is its `client_message_id`: the same
    /// logical row can arrive first under a `local-<uuid>` id and later
    /// under its server id, both carrying the same cmid. A naive `save()`
    /// of the canonical row would then INSERT (new id) and trip the
    /// UNIQUE(client_message_id) constraint — `try?` swallows the throw and
    /// the stale row lingers forever. So drop any same-cmid row under a
    /// different id first, in the same transaction.
    func upsertMessages(_ rows: [MessageRow]) {
        try? dbQueue.write { db in
            for r in rows {
                if let cmid = r.client_message_id, !cmid.isEmpty {
                    try db.execute(
                        sql: "DELETE FROM messages WHERE client_message_id = ? AND id <> ?",
                        arguments: [cmid, r.id]
                    )
                }
                try r.save(db)
            }
        }
    }

    /// Atomic "this is the full message set for the conversation" — delete
    /// every cached row for `conversationId`, then insert `rows`, in ONE
    /// transaction. Used by loadHistory after a successful authoritative
    /// fetch so the cache exactly mirrors the server view with no window
    /// where it's empty or partial, and no chance of leftover duplicates /
    /// stale rows (the old prune-then-upsert split ran as two separate
    /// transactions and keyed conflict resolution off `id` while the dedup
    /// contract is `client_message_id`). Matches the wholesale-replace
    /// pattern already used for bots / contacts / group_members.
    func replaceMessages(conversationId: String, _ rows: [MessageRow]) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE conversation_id = ?",
                arguments: [conversationId]
            )
            for r in rows { try r.save(db) }
        }
    }

    func deleteMessage(id: String) {
        try? dbQueue.write { db in
            _ = try MessageRow.deleteOne(db, key: id)
        }
    }

    // MARK: - Friends (bots + contacts)

    struct BotRow: Codable, FetchableRecord, PersistableRecord {
        var id: String
        var display_name: String
        var model_id: String?
        var visibility: String?
        var creator_id: String?
        /// Optional only because the column was added in v5; rows persisted
        /// before that migration will have null. nil reads as "off" at the
        /// call site.
        var voice_call_enabled: Bool?
        /// Friend-added time (epoch seconds). Optional only because the column
        /// was added in v7; older rows read as nil → treated as 0 by callers.
        var added_at: Int?

        static let databaseTableName = "bots"
    }

    struct ContactRow: Codable, FetchableRecord, PersistableRecord {
        var id: String
        var alias: String?
        var display_name: String
        var avatar_path: String?
        /// Stable per-account placeholder-emoji seed. Optional only because
        /// the column was added in a later GRDB migration; rows persisted
        /// before that migration will have null. Callers should fall back
        /// to `id` so legacy cached entries still render.
        var avatar_seed: String?
        /// Friend-added time (epoch seconds). Optional only because the column
        /// was added in v7; older rows read as nil → treated as 0 by callers.
        var added_at: Int?

        static let databaseTableName = "contacts"
    }

    func loadBots() -> [BotRow] {
        (try? dbQueue.read { db in
            try BotRow.fetchAll(db)
        }) ?? []
    }

    func loadContacts() -> [ContactRow] {
        (try? dbQueue.read { db in
            try ContactRow.fetchAll(db)
        }) ?? []
    }

    /// Wholesale replacement — server is the source of truth for which
    /// bots / contacts the user has, so a partial upsert would leave
    /// stale rows behind after deletions. Called only on a successful
    /// fetch; on network failure we keep the prior cache intact.
    func replaceBots(_ rows: [BotRow]) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM bots")
            for r in rows { try r.save(db) }
        }
    }

    func replaceContacts(_ rows: [ContactRow]) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM contacts")
            for r in rows { try r.save(db) }
        }
    }

    // MARK: - Group cache (members + meta)

    /// Cached snapshot of a single `conversation_participants` row enriched
    /// with the resolved display_name / avatar_path / avatar_seed. Both the
    /// chat timeline (GroupBubbleSender) and the settings page (Member)
    /// hydrate from this same shape — settings additionally reads role.
    struct GroupMemberRow: Codable, FetchableRecord, PersistableRecord {
        var conversation_id: String
        var participant_type: String
        var participant_id: String
        var nickname: String?
        var role: String?
        var display_name: String
        var avatar_path: String?
        var avatar_seed: String?

        static let databaseTableName = "group_members"
    }

    struct GroupMetaRow: Codable, FetchableRecord, PersistableRecord {
        var conversation_id: String
        var title: String
        var join_policy: String
        var max_members: Int
        var number_handle: String

        static let databaseTableName = "group_meta"
    }

    func loadGroupMembers(conversationId: String) -> [GroupMemberRow] {
        (try? dbQueue.read { db in
            try GroupMemberRow
                .filter(Column("conversation_id") == conversationId)
                .fetchAll(db)
        }) ?? []
    }

    func loadGroupMeta(conversationId: String) -> GroupMetaRow? {
        try? dbQueue.read { db in
            try GroupMetaRow.fetchOne(db, key: conversationId)
        }
    }

    /// Wholesale replace — server is authoritative for who's in the group,
    /// so a partial upsert would leave stale rows behind after a member
    /// leaves. Called only on a successful fetch; on network failure we
    /// keep the prior cache intact so the next open still paints.
    func replaceGroupMembers(conversationId: String, _ rows: [GroupMemberRow]) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM group_members WHERE conversation_id = ?",
                arguments: [conversationId]
            )
            for r in rows { try r.save(db) }
        }
    }

    func upsertGroupMeta(_ row: GroupMetaRow) {
        try? dbQueue.write { db in
            try row.save(db)
        }
    }
}
