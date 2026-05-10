import Foundation
import Supabase
import Realtime

/// Centralized Supabase Realtime subscription manager.
///
/// Two channel layers per plan/03:
///   user-level (resident) — subscribes to `pendingbot.user_unread_counts`
///       filtered by user_id; powers the message list / badge UI. One per
///       signed-in user, opened on launch and closed on sign-out.
///   conv-level (lazy)     — subscribes to `pendingbot.messages` filtered
///       by conversation_id; opened when a conv view appears, closed when
///       it disappears. INSERT + UPDATE both bubble up so streaming bot
///       replies (UPDATE on content_partial) and review log entries
///       (INSERT role='log') flow through the same handler.
@MainActor
final class RealtimeManager {
    static let shared = RealtimeManager()
    private init() {}

    // MARK: - User-level channel

    private var userChannel: RealtimeChannelV2?
    private var userSubs: [RealtimeSubscription] = []

    /// Open the user-level channel for `userId`. Idempotent — calling twice
    /// with the same id is a no-op.
    func startUserChannel(userId: String,
                          onUnreadEvent: @escaping @Sendable (UnreadEvent) -> Void) async {
        if userChannel != nil { return }
        let ch = SupabaseStack.shared.realtimeV2.channel("user:\(userId)")

        userSubs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "user_unread_counts",
            filter: "user_id=eq.\(userId)"
        ) { action in
            onUnreadEvent(.init(record: action.record))
        })
        userSubs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "user_unread_counts",
            filter: "user_id=eq.\(userId)"
        ) { action in
            onUnreadEvent(.init(record: action.record))
        })
        do {
            try await ch.subscribeWithError()
        } catch {
            // Best-effort — observers fall back to polling if the socket is
            // unhealthy, keeping the public surface non-throwing.
        }
        userChannel = ch
    }

    func stopUserChannel() async {
        userSubs.forEach { $0.cancel() }
        userSubs.removeAll()
        if let ch = userChannel {
            // removeChannel — not just unsubscribe — so the SDK drops its
            // cached entry; next `channel(topic)` returns a fresh instance
            // instead of a stale one whose postgres_changes buffer is full.
            await SupabaseStack.shared.realtimeV2.removeChannel(ch)
            userChannel = nil
        }
    }

    // MARK: - Conv-level channels

    private var convChannels: [String: ConvChannelHandle] = [:]

    /// Open or reuse a conv-level channel. Multiple observers share one
    /// underlying socket subscription — each gets a token to drop later.
    /// One channel covers both `messages` (visible turns + log entries)
    /// and `bot_lookbacks` (invisible context-edit notes); callers
    /// register one closure per category.
    func startConvChannel(
        conversationId: String,
        onMessage: @escaping @Sendable (MessageEvent) -> Void,
        onLookback: @escaping @Sendable (LookbackEvent) -> Void = { _ in },
        onContinueRequest: @escaping @Sendable (ContinueRequestEvent) -> Void = { _ in },
        onParticipants: @escaping @Sendable (ParticipantsEvent) -> Void = { _ in }
    ) async -> ConvSubscriptionToken {
        let token = ConvSubscriptionToken(id: UUID(), conversationId: conversationId)

        if let handle = convChannels[conversationId] {
            handle.observers[token.id] = (onMessage, onLookback, onContinueRequest, onParticipants)
            return token
        }

        let ch = SupabaseStack.shared.realtimeV2.channel("conv:\(conversationId)")
        let handle = ConvChannelHandle(channel: ch)
        handle.observers[token.id] = (onMessage, onLookback, onContinueRequest, onParticipants)

        // Capture the handle weakly inside the callbacks so the channel can
        // be torn down without dangling observer references.
        let observersRef: () -> [UUID: ConvChannelHandle.Observers] = { [weak handle] in
            handle?.observers ?? [:]
        }

        handle.subs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "messages",
            filter: "conversation_id=eq.\(conversationId)"
        ) { action in
            let evt = MessageEvent(kind: .insert, record: action.record)
            for (_, obs) in observersRef() { obs.message(evt) }
        })
        handle.subs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "messages",
            filter: "conversation_id=eq.\(conversationId)"
        ) { action in
            let evt = MessageEvent(kind: .update, record: action.record)
            for (_, obs) in observersRef() { obs.message(evt) }
        })
        handle.subs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "bot_lookbacks",
            filter: "conversation_id=eq.\(conversationId)"
        ) { action in
            let evt = LookbackEvent(kind: .insert, record: action.record)
            for (_, obs) in observersRef() { obs.lookback(evt) }
        })
        handle.subs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "bot_lookbacks",
            filter: "conversation_id=eq.\(conversationId)"
        ) { action in
            let evt = LookbackEvent(kind: .update, record: action.record)
            for (_, obs) in observersRef() { obs.lookback(evt) }
        })
        // Group-only tables. Subscriptions fire on every conv channel
        // regardless of conv type — that's fine; non-group convs simply
        // never produce rows in these tables, so the closures are
        // never invoked. Each must be in `supabase_realtime` publication
        // — Realtime accepts the channel join when one isn't, but silently
        // drops events for *every* postgres_changes filter on the same
        // channel (incl. messages), surfacing as user_user real-time
        // delivery silently breaking. See migration 0060.
        handle.subs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "group_continue_requests",
            filter: "conversation_id=eq.\(conversationId)"
        ) { action in
            let evt = ContinueRequestEvent(kind: .insert, record: action.record)
            for (_, obs) in observersRef() { obs.continueReq(evt) }
        })
        handle.subs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "group_continue_requests",
            filter: "conversation_id=eq.\(conversationId)"
        ) { action in
            let evt = ContinueRequestEvent(kind: .update, record: action.record)
            for (_, obs) in observersRef() { obs.continueReq(evt) }
        })
        handle.subs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "conversation_participants",
            filter: "conversation_id=eq.\(conversationId)"
        ) { _ in
            for (_, obs) in observersRef() { obs.participants(ParticipantsEvent(kind: .insert)) }
        })
        handle.subs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "conversation_participants",
            filter: "conversation_id=eq.\(conversationId)"
        ) { _ in
            for (_, obs) in observersRef() { obs.participants(ParticipantsEvent(kind: .update)) }
        })
        handle.subs.append(ch.onPostgresChange(
            DeleteAction.self,
            schema: "pendingbot",
            table: "conversation_participants",
            filter: "conversation_id=eq.\(conversationId)"
        ) { _ in
            for (_, obs) in observersRef() { obs.participants(ParticipantsEvent(kind: .delete)) }
        })
        do {
            try await ch.subscribeWithError()
        } catch {
            // Best-effort subscribe — caller still gets a token; loss of
            // realtime degrades to refresh-on-foreground until reconnect.
        }
        convChannels[conversationId] = handle
        return token
    }

    /// Drop one observer. Last observer out closes the underlying channel.
    func stopConvChannel(_ token: ConvSubscriptionToken) async {
        guard let handle = convChannels[token.conversationId] else { return }
        handle.observers.removeValue(forKey: token.id)
        if handle.observers.isEmpty {
            handle.subs.forEach { $0.cancel() }
            // See `stopUserChannel`.
            await SupabaseStack.shared.realtimeV2.removeChannel(handle.channel)
            convChannels.removeValue(forKey: token.conversationId)
        }
    }

    /// Drop everything — call on sign-out.
    func stopAll() async {
        await stopUserChannel()
        for (_, handle) in convChannels {
            handle.subs.forEach { $0.cancel() }
            await SupabaseStack.shared.realtimeV2.removeChannel(handle.channel)
        }
        convChannels.removeAll()
    }
}

// MARK: - Public types

struct UnreadEvent: Sendable {
    /// Raw row JSON. Callers decode the columns they care about.
    let record: [String: AnyJSON]
}

struct MessageEvent: Sendable {
    enum Kind: Sendable { case insert, update }
    let kind: Kind
    let record: [String: AnyJSON]
}

struct LookbackEvent: Sendable {
    enum Kind: Sendable { case insert, update }
    let kind: Kind
    let record: [String: AnyJSON]
}

/// Group-only — fires on group_continue_requests INSERT/UPDATE for
/// the subscribed conv. Used to surface / dismiss the continue-vote
/// banner above the composer without the poll-on-open delay.
struct ContinueRequestEvent: Sendable {
    enum Kind: Sendable { case insert, update }
    let kind: Kind
    let record: [String: AnyJSON]
}

/// Group-only — fires on conversation_participants delta for the
/// subscribed conv. Carries no body; observer reloads the senders
/// map (small, infrequent).
struct ParticipantsEvent: Sendable {
    enum Kind: Sendable { case insert, update, delete }
    let kind: Kind
}

struct ConvSubscriptionToken: Hashable, Sendable {
    let id: UUID
    let conversationId: String
}

// MARK: - Internals

@MainActor
private final class ConvChannelHandle {
    typealias MessageHandler = @Sendable (MessageEvent) -> Void
    typealias LookbackHandler = @Sendable (LookbackEvent) -> Void
    typealias ContinueHandler = @Sendable (ContinueRequestEvent) -> Void
    typealias ParticipantsHandler = @Sendable (ParticipantsEvent) -> Void
    typealias Observers = (
        message: MessageHandler,
        lookback: LookbackHandler,
        continueReq: ContinueHandler,
        participants: ParticipantsHandler
    )
    let channel: RealtimeChannelV2
    var observers: [UUID: Observers] = [:]
    var subs: [RealtimeSubscription] = []
    init(channel: RealtimeChannelV2) { self.channel = channel }
}
