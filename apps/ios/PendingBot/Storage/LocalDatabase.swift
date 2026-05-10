import Foundation
import GRDB
import OSLog

private let log = Logger.category("LocalDatabase")

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
@MainActor
final class LocalDatabase {
    static let shared = LocalDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let url = Self.databaseURL()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Self.migrator.migrate(queue)
            self.dbQueue = queue
            return
        } catch {
            // First-resort recovery: nuke a possibly-corrupt file and retry.
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Self.migrator.migrate(queue)
            self.dbQueue = queue
            return
        } catch {
            // Disk is genuinely broken (full disk, sandbox issue, etc.).
            // Fall back to an in-memory DB so the app still launches —
            // user loses offline cache + history persistence between
            // launches but everything else works.
            log.error("disk init failed twice — falling back to in-memory: \(error.localizedDescription, privacy: .public)")
        }
        // In-memory init has no I/O so the only error path here would be
        // an internal GRDB precondition; treat as unrecoverable.
        let memQueue = (try? DatabaseQueue()) ?? {
            fatalError("LocalDatabase: in-memory DatabaseQueue() failed — unrecoverable")
        }()
        try? Self.migrator.migrate(memQueue)
        self.dbQueue = memQueue
    }

    private static func databaseURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pendingbot.sqlite")
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
        return m
    }

    /// Wipe the cache — call from sign-out.
    func clear() {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM conversations")
            try db.execute(sql: "DELETE FROM bots")
            try db.execute(sql: "DELETE FROM contacts")
        }
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

        static let databaseTableName = "messages"
    }

    func loadMessages(conversationId: String, limit: Int = 200) -> [MessageRow] {
        (try? dbQueue.read { db in
            try MessageRow
                .filter(Column("conversation_id") == conversationId)
                .order(Column("created_at").asc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func upsertMessages(_ rows: [MessageRow]) {
        try? dbQueue.write { db in
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

        static let databaseTableName = "bots"
    }

    struct ContactRow: Codable, FetchableRecord, PersistableRecord {
        var id: String
        var alias: String?
        var display_name: String
        var avatar_path: String?

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
}
