import Foundation
import Supabase
import Realtime

// 奏折/Scroll networking layer — REST writes go through APIClient
// (POST /v1/scroll/...), reads pull from Supabase directly the same way
// FriendsTab queries `bots`. Realtime is a feed-level channel filtered
// by user_id so the article list updates without polling.

/// One row from `pendingbot.scroll_runs`. Covers every status — UI uses
/// `status` to decide between shimmer / article / hide. `body_md` is
/// only present once status flips to "done"; `summary` may be set
/// earlier but the runner won't write it until the article is final.
struct ScrollRun: Codable, Identifiable, Hashable {
    let id: String
    let bot_id: String
    let conversation_id: String
    let status: String
    let title: String?
    let summary: String?
    let body_md: String?
    let progress: AnyJSON?
    let created_at: String
    let started_at: String?
    let finished_at: String?

    var isDone: Bool { status == "done" && body_md != nil }
    var isRunning: Bool { status == "running" }
}

extension APIClient {
    /// Kicks off a new scroll run for the given bot conversation. Returns
    /// the scroll_runs id immediately; the runner streams progress via
    /// Realtime. Caller subscribes to the feed channel to watch it.
    func scrollTrigger(conversationId: String) async throws -> String {
        struct Body: Encodable { let conversationId: String }
        struct Resp: Decodable { let scrollRunId: String }
        let resp: Resp = try await post(
            "v1/scroll/trigger",
            body: Body(conversationId: conversationId)
        )
        return resp.scrollRunId
    }

    /// Marks a running scroll as cancelled. The runner notices on its
    /// next turn and exits cleanly.
    func scrollCancel(id: String) async throws {
        try await postVoid("v1/scroll/\(id)/cancel")
    }
}

// ── Realtime feed channel ────────────────────────────────────────────────
//
// One channel per signed-in user, opened when the Scroll tab appears,
// closed when it disappears. The channel watches scroll_runs filtered
// by user_id; iOS callers receive INSERT / UPDATE / DELETE events as
// raw records and decode them locally.

/// Token returned by `startScrollFeedChannel`; pass it back to
/// `stopScrollFeedChannel` to detach.
struct ScrollFeedToken: Hashable, Sendable {
    let id: UUID
    let userId: String
}

@MainActor
final class ScrollFeedChannel {
    static let shared = ScrollFeedChannel()
    private init() {}

    private var channel: RealtimeChannelV2?
    private var subs: [RealtimeSubscription] = []
    private var observers: [UUID: ObserverFns] = [:]
    private var currentUserId: String?

    typealias UpsertHandler = @Sendable ([String: AnyJSON]) -> Void
    typealias DeleteHandler = @Sendable ([String: AnyJSON]) -> Void
    private struct ObserverFns {
        let upsert: UpsertHandler
        let delete: DeleteHandler
    }

    func start(
        userId: String,
        onUpsert: @escaping UpsertHandler,
        onDelete: @escaping DeleteHandler
    ) async -> ScrollFeedToken {
        let token = ScrollFeedToken(id: UUID(), userId: userId)
        observers[token.id] = ObserverFns(upsert: onUpsert, delete: onDelete)

        // Already subscribed for this user — just hook in the new observers.
        if channel != nil, currentUserId == userId {
            return token
        }
        // Different user (sign-out + sign-in flow) — drop the old socket.
        if channel != nil { await tearDown() }

        currentUserId = userId
        let ch = SupabaseStack.shared.realtimeV2.channel("scroll-feed:\(userId)")
        let observersRef: () -> [UUID: ObserverFns] = { [weak self] in
            self?.observers ?? [:]
        }
        subs.append(ch.onPostgresChange(
            InsertAction.self,
            schema: "pendingbot",
            table: "scroll_runs",
            filter: "user_id=eq.\(userId)"
        ) { action in
            for (_, obs) in observersRef() { obs.upsert(action.record) }
        })
        subs.append(ch.onPostgresChange(
            UpdateAction.self,
            schema: "pendingbot",
            table: "scroll_runs",
            filter: "user_id=eq.\(userId)"
        ) { action in
            for (_, obs) in observersRef() { obs.upsert(action.record) }
        })
        subs.append(ch.onPostgresChange(
            DeleteAction.self,
            schema: "pendingbot",
            table: "scroll_runs",
            filter: "user_id=eq.\(userId)"
        ) { action in
            // DELETE only carries the primary key by default; that's fine
            // for the UI — the row id is what feed state keys off.
            for (_, obs) in observersRef() { obs.delete(action.oldRecord) }
        })
        await ch.subscribe()
        channel = ch
        return token
    }

    func stop(_ token: ScrollFeedToken) async {
        observers.removeValue(forKey: token.id)
        if observers.isEmpty {
            await tearDown()
        }
    }

    private func tearDown() async {
        subs.forEach { $0.cancel() }
        subs.removeAll()
        if let ch = channel {
            await ch.unsubscribe()
            channel = nil
        }
        currentUserId = nil
    }
}

// ── Decoding helpers ─────────────────────────────────────────────────────

enum ScrollRunDecoder {
    /// Decode a Realtime record (`[String: AnyJSON]`) into a ScrollRun.
    /// Returns nil if the row is missing required fields — defensive in
    /// case the publication shape changes upstream.
    static func decode(_ record: [String: AnyJSON]) -> ScrollRun? {
        guard
            let id = record["id"]?.stringValue,
            let bot = record["bot_id"]?.stringValue,
            let conv = record["conversation_id"]?.stringValue,
            let status = record["status"]?.stringValue,
            let createdAt = record["created_at"]?.stringValue
        else {
            return nil
        }
        return ScrollRun(
            id: id,
            bot_id: bot,
            conversation_id: conv,
            status: status,
            title: record["title"]?.stringValue,
            summary: record["summary"]?.stringValue,
            body_md: record["body_md"]?.stringValue,
            progress: record["progress"],
            created_at: createdAt,
            started_at: record["started_at"]?.stringValue,
            finished_at: record["finished_at"]?.stringValue
        )
    }
}

