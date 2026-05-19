import Foundation
import Combine
import UserNotifications

/// Unread state for the message list.
///
/// Two layers:
///   • `serverCounts` — the real per-conversation unread message count,
///     sourced from `user_unread_counts` on every conversation-list fetch
///     and refreshed by the user-level Realtime channel. Drives the numeric
///     badge on each row and the app icon badge total.
///   • `unread` — conversation ids the user *manually* flagged unread via
///     the swipe action. Local-only (the server has no "mark unread"),
///     persisted to UserDefaults keyed by account.id so switching accounts
///     surfaces the right dots.
@MainActor
final class UnreadStore: ObservableObject {
    static let shared = UnreadStore()

    /// Conversation ids the user manually flagged unread (swipe action).
    @Published private(set) var unread: Set<String> = []

    /// Server-truth unread message counts, keyed by conversation id.
    @Published private(set) var serverCounts: [String: Int] = [:]

    private var accountId: String?
    private let userDefaults = UserDefaults.standard
    private func storageKey(for accountId: String) -> String {
        "pendingbot.unread.\(accountId).v1"
    }

    private init() {}

    /// Total unread messages across every conversation — the app icon
    /// badge number.
    var totalUnreadCount: Int {
        serverCounts.values.reduce(0, +)
    }

    /// Server unread count for one conversation (0 when none).
    func unreadCount(_ conversationId: String) -> Int {
        serverCounts[conversationId] ?? 0
    }

    func isUnread(_ conversationId: String) -> Bool {
        unread.contains(conversationId)
    }

    // ── Account binding ─────────────────────────────────────────────────────

    /// Switch the store to a different account — flush the current set to
    /// disk, then load whatever's saved for the new account. Server counts
    /// are not persisted; they refill on the next conversation-list fetch.
    func bind(account: Account?) {
        if let accountId, !unread.isEmpty {
            persist(accountId: accountId, set: unread)
        }
        accountId = account?.id
        serverCounts = [:]
        guard let accountId = account?.id else {
            unread = []
            syncAppIconBadge()
            return
        }
        unread = load(accountId: accountId)
        syncAppIconBadge()
    }

    // ── Server counts ───────────────────────────────────────────────────────

    /// Replace the server unread snapshot — called after every
    /// conversation-list fetch. Refreshes the app icon badge.
    func setServerCounts(_ counts: [String: Int]) {
        serverCounts = counts
        syncAppIconBadge()
    }

    // ── Mutations ───────────────────────────────────────────────────────────

    /// Mark a conversation as unread. No-op if it's already in the set.
    func markUnread(_ conversationId: String) {
        guard !unread.contains(conversationId) else { return }
        unread.insert(conversationId)
        flush()
    }

    /// Mark a conversation as read — clears the local flag and zeroes the
    /// server unread count (optimistically, plus a persisted Supabase
    /// UPDATE so other devices and the next fetch agree). Called when the
    /// user opens a conversation, or when they delete it.
    func markRead(_ conversationId: String) {
        if unread.contains(conversationId) {
            unread.remove(conversationId)
            flush()
        }
        clearServerCount(conversationId)
    }

    private func clearServerCount(_ conversationId: String) {
        guard (serverCounts[conversationId] ?? 0) > 0 else { return }
        serverCounts[conversationId] = 0
        syncAppIconBadge()
        // RLS on user_unread_counts scopes UPDATE to user_id = auth.uid(),
        // so matching conversation_id alone hits exactly this user's row.
        Task {
            try? await SupabaseStack.shared
                .from("user_unread_counts")
                .update(["unread_count": 0])
                .eq("conversation_id", value: conversationId)
                .execute()
        }
    }

    // ── App icon badge ──────────────────────────────────────────────────────

    private func syncAppIconBadge() {
        UNUserNotificationCenter.current().setBadgeCount(totalUnreadCount)
    }

    // ── Persistence ─────────────────────────────────────────────────────────

    private func flush() {
        guard let accountId else { return }
        persist(accountId: accountId, set: unread)
    }

    private func persist(accountId: String, set: Set<String>) {
        let array = Array(set).sorted()
        if let data = try? JSONEncoder().encode(array) {
            userDefaults.set(data, forKey: storageKey(for: accountId))
        }
    }

    private func load(accountId: String) -> Set<String> {
        guard let data = userDefaults.data(forKey: storageKey(for: accountId)),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }
}
