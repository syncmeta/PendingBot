#if os(iOS)
import Foundation

/// App-level owner of the currently-active voice / group call.
///
/// The call surfaces (`CallView`, `GroupCallView`) used to be presented
/// via `.fullScreenCover` directly on `ConversationView` with the
/// session stored as `@State` there. That meant navigating away from the
/// conversation tore the session down — there was no way to "minimize"
/// the call and keep talking while browsing other screens.
///
/// `CallCenter` lifts that ownership to the root scene:
///   * `voiceCall` / `groupCall` hold the live session across whatever
///     view the user is on; the underlying WebRTC peer, AVAudioSession,
///     CallKit registration, and conv-hub subscription all live inside
///     the session itself so they survive navigation for free.
///   * `isMinimized` drives whether the full-screen call surface is
///     showing. When true, `TabRoot` hides the cover and shows a
///     compact pill instead.
///   * Slots are cleared when the session reaches `.terminated`; the
///     cover binding flips false naturally and the pill disappears.
///
/// Only one call (voice or group) is allowed at a time. Starting a
/// second call while one is live is treated as "re-expand the existing
/// one" rather than spinning up a competing session.
@MainActor
@Observable
final class CallCenter {

    /// Shared instance — injected into the SwiftUI environment by
    /// PendingBotApp and read by the call surfaces, the floating pill,
    /// and the conversation-level start hooks.
    static let shared = CallCenter()

    /// Active 1:1 voice call, nil when no 1:1 call is in flight. The
    /// session retains the WebRTC transport + CallKit handle, so it
    /// keeps running even when no view is observing it.
    var voiceCall: CallSession?

    /// Active group voice call, nil when no group call is in flight.
    /// Mutually exclusive with `voiceCall` — see `hasActiveCall`.
    var groupCall: GroupCallSession?

    /// True while the user has tapped "minimize" on a call surface. The
    /// session is still live; only the full-screen UI is hidden. Flips
    /// back to false when the user taps the floating pill or starts a
    /// new call on the same conversation.
    var isMinimized: Bool = false

    /// Conversation id the active call belongs to. Lets the
    /// conversation-level start hook decide whether to re-expand the
    /// existing call (same conv) or no-op (different conv — UI can show
    /// "已有进行中的通话" if it wants to, the simplest thing is to just
    /// expand and let the user hang up first).
    var activeConversationId: String? {
        voiceCall?.conversationId ?? groupCall?.conversationId
    }

    /// True when either slot is occupied. Used to gate starting a new
    /// call from anywhere in the app.
    var hasActiveCall: Bool {
        voiceCall != nil || groupCall != nil
    }

    private init() {}

    // MARK: - Start

    /// Install a freshly-constructed 1:1 voice session. No-op (returns
    /// false) when another call is already in flight — callers should
    /// surface a "已有进行中的通话" hint or just expand the existing one.
    @discardableResult
    func startVoiceCall(_ session: CallSession) -> Bool {
        guard !hasActiveCall else { return false }
        voiceCall = session
        isMinimized = false
        return true
    }

    /// Install a freshly-constructed group voice session.
    @discardableResult
    func startGroupCall(_ session: GroupCallSession) -> Bool {
        guard !hasActiveCall else { return false }
        groupCall = session
        isMinimized = false
        return true
    }

    // MARK: - Window control

    /// Hide the full-screen surface but keep the session alive — the
    /// user navigates the rest of the app while the call continues in
    /// the background; a floating pill at the root remains tappable.
    func minimize() {
        isMinimized = true
    }

    /// Re-present the full-screen surface for whichever call is active.
    /// Called by the floating pill's tap handler.
    func expand() {
        isMinimized = false
    }

    // MARK: - Teardown

    /// Drop the voice slot. Called by the call surface's
    /// `.terminated` phase handler — once the session has reached its
    /// sink state the slot is finished and any view bound to
    /// `voiceCall != nil` collapses naturally.
    func clearVoiceCall() {
        voiceCall = nil
        if groupCall == nil { isMinimized = false }
    }

    /// Drop the group slot — same shape as `clearVoiceCall`.
    func clearGroupCall() {
        groupCall = nil
        if voiceCall == nil { isMinimized = false }
    }
}
#endif
