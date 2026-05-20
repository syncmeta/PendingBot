import AVFoundation
import CallKit
import Foundation

/// Outgoing-call CallKit integration — the bare minimum that gets a
/// PendingBot voice call onto iOS's system call surface (Control Center
/// "active call" indicator, lock-screen end button, system call-history
/// entry) without rebuilding the rest of the pipeline.
///
/// Scope: **outgoing 1:1 only**, no PushKit / VoIP push. Incoming group
/// `voice_ring` invites still use the existing in-app + APNs banner —
/// adding incoming CallKit requires a PushKit VoIP token and a
/// server-side push-channel change that we're deferring.
///
/// Lifecycle of one call:
///   1. CallSession.start() → CallKitManager.startOutgoingCall(uuid, name)
///   2. CallKit fires `provider(_:perform:CXStartCallAction)`. We fulfil
///      it; the transaction returns "call started".
///   3. CallSession does its existing audio-session + ringback +
///      transport setup. (We deliberately don't hand audio-session
///      ownership to CallKit — keeping it in CallSession means the
///      proximity / speaker / Bluetooth code paths don't have to change.)
///   4. transportDidConnect → CallKitManager.reportCallConnected(uuid)
///      flips the system UI from "dialing" to "in call" and starts the
///      lock-screen timer.
///   5. User taps the in-app hang up → CallKitManager.endCall(uuid)
///      requests CXEndCallAction; the provider fulfils it.
///   6. User taps the CallKit lock-screen end button → provider's
///      perform(:CXEndCallAction) fires the `onSystemEnd` callback so
///      CallSession can terminate the same way as an in-app hang up.
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

    /// The user pressed end from the system UI. Notify CallSession so
    /// the rest of teardown runs (transport hang-up, summary upload).
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeCallUUID == action.callUUID {
                self.activeCallUUID = nil
                self.callConfirmed = false
                let cb = self.onSystemEnd
                self.onSystemEnd = nil
                cb?()
            }
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
