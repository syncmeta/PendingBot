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
///
/// Plus an envelope (来信) layer — `envelope_runs` has no server-side read
/// marker, so we track read state locally: `currentEnvelopeIds` (in-memory
/// snapshot of what the Envelope tab is currently displaying) minus
/// `readEnvelopeIds` (persisted set of ids the user has opened) gives the
/// unread dot. To avoid flooding an established account with fake dots on
/// first launch, the first call to `setCurrentEnvelopes` seeds every
/// then-visible id into `readEnvelopeIds` (one-time per account, tracked
/// by `hasSeededEnvelopes`).
@MainActor
final class UnreadStore: ObservableObject {
    static let shared = UnreadStore()

    /// Conversation ids the user manually flagged unread (swipe action).
    @Published private(set) var unread: Set<String> = []

    /// Server-truth unread message counts, keyed by conversation id.
    @Published private(set) var serverCounts: [String: Int] = [:]

    /// Envelope ids the user has explicitly opened. Persisted per account.
    @Published private(set) var readEnvelopeIds: Set<String> = []

    /// Live set of envelope ids currently visible in the Envelope tab —
    /// the source of truth for "what could be unread right now". Not
    /// persisted; refilled on tab appearance + realtime upserts.
    @Published private(set) var currentEnvelopeIds: Set<String> = []

    /// Per-account flag: have we seeded `readEnvelopeIds` with the
    /// existing envelope backlog yet? Without this, a fresh install on
    /// an account that already has 50 envelopes would surface a dot
    /// the user can't make go away short of opening every letter.
    private var hasSeededEnvelopes: Bool = false

    private var accountId: String?
    private let userDefaults = UserDefaults.standard
    private func storageKey(for accountId: String) -> String {
        "pendingbot.unread.\(accountId).v1"
    }
    private func envelopeStorageKey(for accountId: String) -> String {
        "pendingbot.envelopeRead.\(accountId).v1"
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
        currentEnvelopeIds = []
        guard let accountId = account?.id else {
            unread = []
            readEnvelopeIds = []
            hasSeededEnvelopes = false
            syncAppIconBadge()
            return
        }
        unread = load(accountId: accountId)
        let env = loadEnvelopes(accountId: accountId)
        readEnvelopeIds = env.read
        hasSeededEnvelopes = env.seeded
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

    // ── Envelope (来信) read state ──────────────────────────────────────────

    /// Is there at least one envelope currently visible that the user
    /// hasn't opened? Drives the small red dot on the 来信 tab.
    var hasUnreadEnvelopes: Bool {
        !currentEnvelopeIds.subtracting(readEnvelopeIds).isEmpty
    }

    /// Replace the live snapshot of envelope ids the tab is showing.
    /// First call after `bind(account:)` also seeds the backlog into
    /// `readEnvelopeIds` so an established account doesn't start with
    /// a wall of fake dots.
    func setCurrentEnvelopes(_ ids: Set<String>) {
        if !hasSeededEnvelopes {
            hasSeededEnvelopes = true
            if !ids.isEmpty {
                readEnvelopeIds.formUnion(ids)
            }
            persistEnvelopes()
        }
        currentEnvelopeIds = ids
    }

    /// Add one envelope id to the live snapshot — called from the
    /// realtime upsert handler on the Envelope tab.
    func addCurrentEnvelope(_ id: String) {
        guard !currentEnvelopeIds.contains(id) else { return }
        // No backlog seeding here: a brand-new envelope arriving via
        // realtime is genuinely new, even if it's the first one this
        // account has ever seen.
        if !hasSeededEnvelopes {
            hasSeededEnvelopes = true
            persistEnvelopes()
        }
        currentEnvelopeIds.insert(id)
    }

    /// Drop an envelope id from the live snapshot — called when the
    /// row is removed (e.g. cancelled or deleted).
    func removeCurrentEnvelope(_ id: String) {
        currentEnvelopeIds.remove(id)
    }

    /// Mark an envelope as read — called when the user taps the row.
    func markEnvelopeRead(_ id: String) {
        guard !readEnvelopeIds.contains(id) else { return }
        readEnvelopeIds.insert(id)
        persistEnvelopes()
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

    // ── Envelope persistence ────────────────────────────────────────────────

    /// On-disk shape for the envelope read state. `seeded` distinguishes
    /// "fresh account, never observed the feed yet" from "account has been
    /// observed and just happens to have zero read entries".
    private struct EnvelopeReadBlob: Codable {
        var read: [String]
        var seeded: Bool
    }

    private func persistEnvelopes() {
        guard let accountId else { return }
        let blob = EnvelopeReadBlob(read: readEnvelopeIds.sorted(), seeded: hasSeededEnvelopes)
        if let data = try? JSONEncoder().encode(blob) {
            userDefaults.set(data, forKey: envelopeStorageKey(for: accountId))
        }
    }

    private func loadEnvelopes(accountId: String) -> (read: Set<String>, seeded: Bool) {
        guard let data = userDefaults.data(forKey: envelopeStorageKey(for: accountId)),
              let blob = try? JSONDecoder().decode(EnvelopeReadBlob.self, from: data) else {
            return ([], false)
        }
        return (Set(blob.read), blob.seeded)
    }
}
