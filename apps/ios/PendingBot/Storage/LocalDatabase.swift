import Foundation
import GRDB

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
        var queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path)
            try Self.migrator.migrate(queue)
        } catch {
            // First-resort recovery: nuke a corrupt file and try once. If
            // that also fails we crash — better to surface the bug than
            // silently lose persistence.
            try? FileManager.default.removeItem(at: url)
            queue = try! DatabaseQueue(path: url.path)
            try! Self.migrator.migrate(queue)
        }
        self.dbQueue = queue
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
        return m
    }

    /// Wipe the cache — call from sign-out.
    func clear() {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM conversations")
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
}
