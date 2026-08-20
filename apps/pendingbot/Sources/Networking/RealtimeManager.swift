import Foundation
import Supabase

/// Centralized realtime subscription manager. Cross-platform — pure Foundation +
/// the `RealtimeSocket` WebSocket (RealtimeHubDO), no UIKit. iOS + macOS share it.

/// Centralized realtime subscription manager.
///
/// Realtime delivery runs over Cloudflare — each layer is a WebSocket to
/// a RealtimeHubDO topic (see RealtimeSocket), not a Supabase Realtime
/// channel. The edge fans DB row changes into the hubs via webhooks.
///
/// Two channel layers:
///   user-level (resident) — one socket to `/v1/realtime-hub/user`,
///       carrying `user_unread_counts` changes for the message list /
///       badge UI. One per signed-in user, opened on launch, closed on
///       sign-out. (The same user topic also carries `envelope_runs`;
///       EnvelopeAPI opens its own socket for that — see EnvelopeAPI.swift.)
///   conv-level (lazy)     — one socket per conversation to
///       `/v1/realtime-hub/conv/<id>`, carrying `messages`,
///       `bot_lookbacks`, `group_continue_requests` and
///       `conversation_participants` changes. Opened when a conv view
///       appears, closed when it disappears.
@MainActor
final class RealtimeManager: ObservableObject {
    static let shared = RealtimeManager()
    private init() {}

    // MARK: - Connection diagnostics

    /// Lifecycle of the resident user-level socket. `.retrying` carries the
    /// consecutive-failure count + last error, so UI / diagnostics can show
    /// "realtime down" instead of silently degrading to poll-on-open.
    @Published private(set) var userChannelState: RealtimeConnectionState = .idle
    /// Per-conversation socket lifecycle, keyed by conversation id. Entries
    /// exist only while a conv channel is open.
    @Published private(set) var convChannelStates: [String: RealtimeConnectionState] = [:]

    // MARK: - User-level channel

    private var userSocket: RealtimeSocket?

    /// Open the user-level socket for `userId`. Idempotent — calling
    /// twice is a no-op. (`userId` is implied by the JWT the socket
    /// authenticates with; the parameter is kept for call-site clarity
    /// and idempotency bookkeeping.)
    func startUserChannel(userId: String,
                          onUnreadEvent: @escaping @Sendable (UnreadEvent) -> Void) async {
        if userSocket != nil { return }
        let socket = RealtimeSocket(path: "v1/realtime-hub/user") { change in
            // The user topic also carries envelope_runs; only unread
            // changes belong to this consumer.
            guard change.table == "user_unread_counts" else { return }
            onUnreadEvent(UnreadEvent(record: change.record))
        }
        socket.onStateChange = { [weak self] state in
            self?.userChannelState = state
        }
        socket.start()
        userSocket = socket
    }

    func stopUserChannel() async {
        userSocket?.stop()
        userSocket = nil
        userChannelState = .idle
    }

    // MARK: - Conv-level channels

    private var convChannels: [String: ConvChannelHandle] = [:]

    /// Open or reuse a conv-level socket. Multiple observers share one
    /// underlying socket — each gets a token to drop later. One socket
    /// covers `messages`, `bot_lookbacks`, `group_continue_requests` and
    /// `conversation_participants` (row-change frames) plus group voice
    /// call lifecycle (voice_call frames); callers register one closure
    /// per category.
    ///
    /// Note: the conv topic also carries `crew_announcements` /
    /// `crew_sessions` row changes from the edge fan-out, but the iOS
    /// crew surface was removed — those frames are now ignored here.
    func startConvChannel(
        conversationId: String,
        onMessage: @escaping @Sendable (MessageEvent) -> Void,
        onLookback: @escaping @Sendable (LookbackEvent) -> Void = { _ in },
        onContinueRequest: @escaping @Sendable (ContinueRequestEvent) -> Void = { _ in },
        onParticipants: @escaping @Sendable (ParticipantsEvent) -> Void = { _ in },
        onVoiceCall: @escaping @Sendable (VoiceCallFrame) -> Void = { _ in },
        onVoiceCost: @escaping @Sendable (VoiceCostFrame) -> Void = { _ in }
    ) async -> ConvSubscriptionToken {
        let token = ConvSubscriptionToken(id: UUID(), conversationId: conversationId)

        if let handle = convChannels[conversationId] {
            handle.observers[token.id] = (
                onMessage, onLookback, onContinueRequest, onParticipants,
                onVoiceCall, onVoiceCost,
            )
            return token
        }

        let handle = ConvChannelHandle()
        handle.observers[token.id] = (
            onMessage, onLookback, onContinueRequest, onParticipants,
            onVoiceCall, onVoiceCost,
        )

        let socket = RealtimeSocket(
            path: "v1/realtime-hub/conv/\(conversationId)"
        ) { [weak handle] frame in
            guard let handle else { return }
            switch frame {
            case .change(let change):
                Self.dispatchChange(change, to: handle)
            case .voiceCall(let v):
                for (_, obs) in handle.observers { obs.voiceCall(v) }
            case .voiceCost(let c):
                for (_, obs) in handle.observers { obs.voiceCost(c) }
            }
        }
        handle.socket = socket
        socket.onStateChange = { [weak self] state in
            self?.convChannelStates[conversationId] = state
        }
        socket.start()
        convChannels[conversationId] = handle
        return token
    }

    private static func dispatchChange(_ change: HubChange, to handle: ConvChannelHandle) {
        switch change.table {
        case "messages":
            // The conv topic only ever emits message INSERT/UPDATE
            // (rows are soft-deleted via a status UPDATE, never a
            // row DELETE) — ignore any stray delete.
            guard change.op != .delete else { return }
            let evt = MessageEvent(kind: change.op == .insert ? .insert : .update,
                                   record: change.record)
            for (_, obs) in handle.observers { obs.message(evt) }
        case "bot_lookbacks":
            guard change.op != .delete else { return }
            let evt = LookbackEvent(kind: change.op == .insert ? .insert : .update,
                                    record: change.record)
            for (_, obs) in handle.observers { obs.lookback(evt) }
        case "group_continue_requests":
            guard change.op != .delete else { return }
            let evt = ContinueRequestEvent(kind: change.op == .insert ? .insert : .update,
                                           record: change.record)
            for (_, obs) in handle.observers { obs.continueReq(evt) }
        case "conversation_participants":
            let kind: ParticipantsEvent.Kind = switch change.op {
            case .insert: .insert
            case .update: .update
            case .delete: .delete
            }
            for (_, obs) in handle.observers { obs.participants(ParticipantsEvent(kind: kind)) }
        default:
            break
        }
    }

    /// Drop one observer. Last observer out closes the underlying socket.
    func stopConvChannel(_ token: ConvSubscriptionToken) async {
        guard let handle = convChannels[token.conversationId] else { return }
        handle.observers.removeValue(forKey: token.id)
        if handle.observers.isEmpty {
            handle.socket?.stop()
            convChannels.removeValue(forKey: token.conversationId)
            convChannelStates.removeValue(forKey: token.conversationId)
        }
    }

    /// Drop everything — call on sign-out.
    func stopAll() async {
        await stopUserChannel()
        for (_, handle) in convChannels {
            handle.socket?.stop()
        }
        convChannels.removeAll()
        convChannelStates.removeAll()
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

/// Group-only — fires on group_continue_requests INSERT/UPDATE for the
/// subscribed conv. Used to surface / dismiss the continue-vote banner
/// above the composer without the poll-on-open delay.
struct ContinueRequestEvent: Sendable {
    enum Kind: Sendable { case insert, update }
    let kind: Kind
    let record: [String: AnyJSON]
}

/// Group-only — fires on conversation_participants delta for the
/// subscribed conv. Carries no body; observer reloads the senders map
/// (small, infrequent).
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
    typealias VoiceCallHandler = @Sendable (VoiceCallFrame) -> Void
    typealias VoiceCostHandler = @Sendable (VoiceCostFrame) -> Void
    typealias Observers = (
        message: MessageHandler,
        lookback: LookbackHandler,
        continueReq: ContinueHandler,
        participants: ParticipantsHandler,
        voiceCall: VoiceCallHandler,
        voiceCost: VoiceCostHandler
    )
    var socket: RealtimeSocket?
    var observers: [UUID: Observers] = [:]
}
