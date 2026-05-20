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
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    /// CallKit had to wipe its state — every call is gone. Tell the
    /// session layer to tear down whatever it has open.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.onSystemEnd?()
            self?.onSystemEnd = nil
            self?.activeCallUUID = nil
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
    }

    /// The user pressed end from the system UI. Notify CallSession so
    /// the rest of teardown runs (transport hang-up, summary upload).
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeCallUUID == action.callUUID {
                self.activeCallUUID = nil
                let cb = self.onSystemEnd
                self.onSystemEnd = nil
                cb?()
            }
        }
    }

    // We deliberately leave audio-session ownership to CallSession —
    // these two callbacks are required by the protocol but do nothing.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
