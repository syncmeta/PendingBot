#if os(iOS)
import Foundation

/// In-memory index of which group conversations currently have a live
/// voice call. Drives two surfaces:
///   * the in-conv "通话中" banner (icon + duration + headcount) on
///     `ConversationView`
///   * the row-level phone-icon badge on the message list
///
/// Sources of truth (best-effort, no missed-event replay):
///   1. `/v1/voice/active` — polled on message-tab focus + app
///      foreground. Authoritative snapshot.
///   2. `voice_call` realtime frames from the conv-hub socket the user is
///      subscribed to (only while they have that conversation open).
///      Drives the in-conv banner in real time.
///
/// The store deliberately doesn't try to keep a long-running realtime
/// view of *every* group the user is in. A row in the message list whose
/// conversation isn't currently subscribed will only update on the next
/// /v1/voice/active poll — fine for an icon.
@MainActor
@Observable
final class ActiveVoiceCallStore {
    static let shared = ActiveVoiceCallStore()
    private init() {}

    /// Snapshot of one active call, as exposed to the UI.
    struct Snapshot: Sendable, Equatable {
        let conversationId: String
        let startedAt: Date
        let participantCount: Int
        let initiatorId: String?
    }

    private(set) var calls: [String: Snapshot] = [:]

    private let api = VoiceCallAPI()

    /// Pull a fresh snapshot from /v1/voice/active. Call on message-tab
    /// appearance + app foreground.
    func refresh() async {
        do {
            let resp = try await api.getActiveVoiceCalls()
            // Preserve participant counts learned from realtime — the
            // listing endpoint only knows started_at + initiator.
            var next: [String: Snapshot] = [:]
            for entry in resp.active {
                let started = Self.parseTimestamp(entry.started_at) ?? Date()
                let existing = calls[entry.conversation_id]
                next[entry.conversation_id] = Snapshot(
                    conversationId: entry.conversation_id,
                    startedAt: existing?.startedAt ?? started,
                    participantCount: existing?.participantCount ?? 1,
                    initiatorId: entry.initiator_id,
                )
            }
            calls = next
        } catch {
            // Non-fatal — keep whatever is on screen rather than blanking.
        }
    }

    /// Apply a voice_call realtime frame — typically the user is in the
    /// conversation right now and watching the banner live update.
    func apply(_ frame: VoiceCallFrame) {
        switch frame.event {
        case .ended:
            calls.removeValue(forKey: frame.conversationId)
        case .reconnecting:
            // The server's media link dropped mid-call — the call is
            // still up (the DO is resyncing), so keep the existing
            // snapshot. The in-call UI shows its own "重连中…" banner.
            break
        case .state:
            let startedAt: Date = frame.startedAt.map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? calls[frame.conversationId]?.startedAt ?? Date()
            calls[frame.conversationId] = Snapshot(
                conversationId: frame.conversationId,
                startedAt: startedAt,
                participantCount: frame.participants.count,
                initiatorId: frame.initiatorId,
            )
        }
    }

    func clear() { calls.removeAll() }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
#endif
