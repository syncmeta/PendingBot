#if os(iOS)
import AVFoundation
import CallKit
import Foundation

/// CallKit integration — both outgoing 1:1 voice bot calls and incoming
/// group voice rings ride this provider. PushKit (see VoIPPushService)
/// delivers ring payloads to the app even from cold launch; this class
/// is what turns a payload into the system incoming-call surface and
/// then hands the accepted call off to GroupCallSession.
///
/// Outgoing (1:1 bot call):
///   1. CallSession.start() → startOutgoingCall(displayName, onSystemEnd)
///   2. CallKit fires `provider(_:perform:CXStartCallAction)`; fulfilled.
///   3. CallSession primes audio + waits for didActivate before ringback.
///   4. transportDidConnect → reportCallConnected(uuid).
///   5. In-app hang up → endCall(uuid). System hang up → onSystemEnd.
///
/// Incoming (group voice_ring via PushKit):
///   1. VoIPPushService.didReceiveIncomingPushWith → reportIncomingCall
///      runs SYNCHRONOUSLY before the PushKit completion(); iOS 13+
///      enforces this contract — skip it and Apple revokes our VoIP
///      push privileges app-wide.
///   2. CallKit surfaces the full-screen / lock-screen incoming UI.
///   3a. User taps Accept → CXAnswerCallAction → onIncomingAnswer
///       fires the conversation id; IncomingCallStore drives the app
///       into the conv + auto-opens GroupCallView.
///   3b. User taps Decline → CXEndCallAction (pre-answer) → onIncomingDecline
///       fires; the app POSTs /voice/cancel-invite so the inviter sees
///       the pending invite drop.
///   4. GroupCallSession.start() runs, connects, then calls
///      reportCallConnected so CallKit flips "answering" → "in call".
@MainActor
final class CallKitManager: NSObject {

    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private var activeCallUUID: UUID?
    /// Fires when the system (lock-screen end button, etc) requests
    /// hang-up. CallSession registers it so the same teardown path runs
    /// whether the user tapped the in-app or system control.
    private var onSystemEnd: (() -> Void)?
    /// Fires once CallKit hands us the audio session via
    /// `provider(_:didActivate:)`. CallSession uses it to start the
    /// ringback tone at the moment audio output is actually usable —
    /// kicking AVAudioEngine before this lands gets silently suppressed
    /// by the system, which is why an outgoing call had no ringback.
    private var onAudioActivated: (() -> Void)?
    /// True once CallKit has already delivered its `didActivate` for the
    /// current call. Lets a late-registered `onAudioActivated` (CallSession
    /// wires it after `startOutgoingCall` returns) still fire immediately
    /// instead of waiting for a callback that already happened.
    private var audioAlreadyActivated: Bool = false
    /// True once CallKit has actually picked up the outgoing call via
    /// `perform(:CXStartCallAction)`. Guards against the spurious
    /// `providerDidReset` CallKit posts to the main queue shortly after
    /// `setDelegate` — without this, the reset lands *after*
    /// `startOutgoingCall` has already wired `onSystemEnd` for a brand-new
    /// call and tears the call down before it even leaves the gate.
    private var callConfirmed: Bool = false

    // MARK: - Incoming-call state (PushKit-driven)

    /// Conversation id of the pending incoming call — set when
    /// reportIncomingCall succeeds, cleared on answer/decline. Read by
    /// GroupCallSession on connect so it can flip CallKit from
    /// "answering" to "in call" against the right UUID.
    private(set) var pendingIncomingConversationId: String?

    /// Fires on MainActor when the user taps Accept on the CallKit
    /// incoming UI. PendingBotApp wires this to IncomingCallStore so the
    /// app navigates to the conv and auto-opens GroupCallView.
    var onIncomingAnswer: ((_ conversationId: String) -> Void)?

    /// Fires on MainActor when the user taps Decline on incoming BEFORE
    /// the call is connected. The wired observer POSTs
    /// /voice/cancel-invite so the inviter's UI drops the pending entry.
    var onIncomingDecline: ((_ conversationId: String) -> Void)?

    private override init() {
        // `localizedName` is set at init on iOS 14+; the no-arg
        // initializer + property assignment was deprecated.
        let cfg = CXProviderConfiguration(localizedName: "PendingBot")
        // Voice-only — the UI never offers a camera button.
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        // CallKit uses CXHandle.value as the on-screen identity; bot
        // display names are free-form strings, so .generic is the right
        // handle type (not .phoneNumber or .emailAddress).
        cfg.supportedHandleTypes = [.generic]
        // Provider icon defaults to the app icon if no template is set,
        // which is the right fallback for a 1:1 bot call.
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Materialise the shared provider at launch. Just touching
    /// `CallKitManager.shared` is enough — bootstrap is a named hook so
    /// AppDelegate.didFinishLaunching reads as a deliberate "arm the
    /// CallKit provider before the first VoIP push arrives".
    func bootstrap() {}

    // MARK: - Outgoing call entry / exit

    /// Tell CallKit a new outgoing call is starting. Returns the UUID
    /// CallSession should treat as the call's identity for any further
    /// CallKit interaction. `displayName` is the bot's name and appears
    /// on the Control Center indicator and the system call-history row.
    ///
    /// `onSystemEnd` is invoked on MainActor if CallKit (lock-screen,
    /// Control Center) drives the hang-up instead of the in-app button.
    func startOutgoingCall(
        displayName: String,
        onSystemEnd: @escaping @MainActor () -> Void,
    ) -> UUID {
        // Only one active call at a time — if we somehow already have
        // one tracked, reset to keep CallKit's state coherent.
        if let prior = activeCallUUID {
            endCall(uuid: prior)
        }
        let uuid = UUID()
        activeCallUUID = uuid
        callConfirmed = false
        audioAlreadyActivated = false
        onAudioActivated = nil
        self.onSystemEnd = onSystemEnd

        let handle = CXHandle(type: .generic, value: displayName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.contactIdentifier = displayName
        // No video, no held flag — let the defaults stand.
        let txn = CXTransaction(action: action)
        controller.request(txn) { error in
            if let error {
                // CallKit rejected the start (e.g. the user has a real
                // phone call active). The in-app UI will still proceed;
                // we just won't have a system call surface for this one.
                print("[callkit] start request failed:", error)
            }
        }
        return uuid
    }

    /// Flip the system UI from "dialing" to "in call". Called from
    /// CallSession.transportDidConnect once the WebRTC link is live.
    func reportCallConnected(uuid: UUID) {
        guard uuid == activeCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Request that CallKit end this call. Mirrors the user tapping the
    /// in-app hang-up button.
    func endCall(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        controller.request(CXTransaction(action: action)) { _ in }
        if uuid == activeCallUUID {
            activeCallUUID = nil
            onSystemEnd = nil
            onAudioActivated = nil
            callConfirmed = false
            audioAlreadyActivated = false
        }
    }

    /// Register a closure that fires the moment CallKit hands us the
    /// audio session (`provider(_:didActivate:)`). If activation already
    /// happened for this call, the closure runs synchronously here so
    /// the caller doesn't miss the edge. Callers must register before
    /// the call ends; cleared along with `endCall`.
    func onAudioSessionActivated(_ uuid: UUID, run: @escaping @MainActor () -> Void) {
        guard uuid == activeCallUUID else { return }
        if audioAlreadyActivated {
            run()
            return
        }
        onAudioActivated = run
    }

    // MARK: - Incoming call entry (PushKit)

    /// Surface a CallKit incoming-call screen. Called from
    /// VoIPPushService when a `voice_ring` VoIP push lands. The handler
    /// MUST call `reportNewIncomingCall` before the PushKit completion
    /// fires, hence the synchronous-ish completion contract.
    ///
    /// Apple's incoming UI takes the caller name from
    /// `CXCallUpdate.localizedCallerName` (free-form string) and the
    /// CXHandle (used by the system call-history app). We stash the
    /// caller name as localizedCallerName and the group title as the
    /// handle value so the system surfaces both pieces of context.
    func reportIncomingCall(
        uuid: UUID,
        conversationId: String,
        callerDisplayName: String,
        groupTitle: String,
        completion: @escaping (Error?) -> Void,
    ) {
        // Reset outgoing-call cursors so a stale activeCallUUID doesn't
        // make a follow-up answer/decline target the wrong call. CallKit
        // already enforces maximumCallsPerCallGroup=1, so a fresh
        // incoming call de-facto supersedes anything that was open.
        activeCallUUID = uuid
        callConfirmed = false
        audioAlreadyActivated = false
        onAudioActivated = nil
        onSystemEnd = nil
        pendingIncomingConversationId = conversationId

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: groupTitle)
        update.localizedCallerName = callerDisplayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] err in
            if err != nil {
                // CallKit refused the report — most often because the
                // user has blocked the app under Settings > Phone, or
                // an active PSTN call collides. We can't surface the
                // ring; clear our cursors so subsequent state machines
                // don't think a call is in flight.
                Task { @MainActor [weak self] in
                    self?.pendingIncomingConversationId = nil
                    if self?.activeCallUUID == uuid { self?.activeCallUUID = nil }
                }
            }
            completion(err)
        }
    }

    /// GroupCallSession calls this when the group call reaches
    /// connected. Flips the CallKit UI from "answering" to "in call"
    /// against the incoming-pending UUID we surfaced earlier.
    /// `reportOutgoingCall(connectedAt:)` also works for an answered
    /// incoming call per Apple's CallKit docs (the API is named for
    /// outgoing but the system applies it to whichever call matches
    /// the UUID).
    func reportIncomingConnected(uuid: UUID) {
        guard uuid == activeCallUUID else { return }
        // For an answered incoming call CallKit will already have moved
        // the system UI past "answering" when CXAnswerCallAction was
        // fulfilled; this call is a no-op for that path. Kept for
        // symmetry with the outgoing reportCallConnected.
    }

    /// Consume the pending-incoming conversation id, returning the UUID
    /// for the call. GroupCallSession reads this on start so it can
    /// (a) decide it's the CallKit-driven join (no outgoing CXStartCall
    /// transaction needed) and (b) hold the UUID for later teardown.
    /// Returns nil if there is no pending incoming call for this conv.
    func claimIncoming(forConversation conversationId: String) -> UUID? {
        guard pendingIncomingConversationId == conversationId,
              let uuid = activeCallUUID
        else { return nil }
        pendingIncomingConversationId = nil
        return uuid
    }

    /// Set the closure that fires when CallKit (lock-screen end button,
    /// Control Center) drives the hang-up. `startOutgoingCall` wires
    /// this internally; the incoming-after-answer path uses this to
    /// install the same teardown hook against the claimed UUID.
    func setOnSystemEnd(_ uuid: UUID, run: @escaping @MainActor () -> Void) {
        guard uuid == activeCallUUID else { return }
        onSystemEnd = run
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    /// CallKit had to wipe its state — every call is gone. Tell the
    /// session layer to tear down whatever it has open.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Ignore the init-time reset CallKit posts after setDelegate —
            // until `perform(:CXStartCallAction)` confirms a real outgoing
            // call, there's nothing for the session layer to tear down.
            // (See `callConfirmed`.)
            guard self.callConfirmed else { return }
            self.onSystemEnd?()
            self.onSystemEnd = nil
            self.activeCallUUID = nil
            self.callConfirmed = false
        }
    }

    /// CallKit confirmed our outgoing-call request — fulfil so the
    /// transaction completes. CallSession's existing start sequence has
    /// already opened (or is opening) the audio session.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Stamp the "started connecting" timestamp here — without it
        // the lock-screen UI shows no duration during the dialing phase.
        provider.reportOutgoingCall(
            with: action.callUUID,
            startedConnectingAt: Date(),
        )
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Arm `providerDidReset` to actually fire `onSystemEnd` — from
            // here on, a reset means "real call in progress, tear it down".
            if self.activeCallUUID == action.callUUID {
                self.callConfirmed = true
            }
        }
    }

    /// User tapped Accept on the CallKit incoming UI. Fulfil
    /// immediately so the system flips its UI; the actual RTK join is
    /// kicked off via `onIncomingAnswer`, which navigates the app into
    /// the conv and lets GroupCallSession.start() do the network work.
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard action.callUUID == self.activeCallUUID,
                  let convId = self.pendingIncomingConversationId
            else { return }
            // Arm `providerDidReset` to actually fire — from here on,
            // a reset means a real in-progress call.
            self.callConfirmed = true
            // Don't nil pendingIncomingConversationId yet: GroupCallSession
            // claims it on start() via claimIncoming(forConversation:).
            self.onIncomingAnswer?(convId)
        }
    }

    /// The user pressed end from the system UI. Two cases:
    ///   • Pre-answer incoming → user declined. Fire onIncomingDecline
    ///     so the app can cancel the server-side invite.
    ///   • Connected call (outgoing or accepted incoming) → existing
    ///     onSystemEnd path runs the session teardown.
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard action.callUUID == self.activeCallUUID else { return }
            // Decline (incoming never answered) — there's a pending conv
            // id and no callConfirmed yet.
            if let convId = self.pendingIncomingConversationId, !self.callConfirmed {
                self.pendingIncomingConversationId = nil
                self.activeCallUUID = nil
                self.onIncomingDecline?(convId)
                return
            }
            // Connected call → reuse the outgoing teardown path.
            self.activeCallUUID = nil
            self.callConfirmed = false
            self.pendingIncomingConversationId = nil
            let cb = self.onSystemEnd
            self.onSystemEnd = nil
            cb?()
        }
    }

    // Audio-session config (category/mode) stays in CallSession + the
    // transport. CallKit still owns *activation* on outgoing calls,
    // though — AVAudioEngine output started before this callback gets
    // suppressed by the system, so CallSession waits on it before
    // kicking the ringback engine.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioAlreadyActivated = true
            let cb = self.onAudioActivated
            self.onAudioActivated = nil
            cb?()
        }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
#endif
