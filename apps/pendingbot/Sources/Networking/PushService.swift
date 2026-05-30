#if os(iOS)
import Foundation
import UIKit
import UserNotifications
import PushKit
import OSLog

private let log = Logger.category("push")

/// APNS device-token lifecycle. The flow:
///   1. User signs in (AccountStore.current becomes non-nil)
///   2. Worker side has a valid Supabase session → we can call /v1/devices/register
///   3. Ask UNUserNotificationCenter for permission
///   4. Register for remote notifications with UIApplication
///   5. AppDelegate's didRegisterForRemoteNotifications hands us a Data blob
///   6. Hex-encode + POST /v1/devices/register with platform=ios + apnsEnv
///
/// apnsEnv detection: parses the `aps-environment` entitlement from the
/// embedded mobileprovision file (TestFlight + Debug = "development"; App
/// Store strips the profile and we fall back to "prod"). Worker uses this
/// to route to api.sandbox.push.apple.com vs api.push.apple.com.
@MainActor
final class PushService {
    static let shared = PushService()
    private init() {}

    private var lastRegisteredToken: String?
    /// Last PushKit/VoIP token registered with the worker. Held alongside
    /// `lastRegisteredToken` so a one-time upload of either path is
    /// idempotent — we deliberately don't share a single field since the
    /// two tokens are unrelated hex blobs from independent Apple
    /// registries.
    private var lastRegisteredVoipToken: String?
    /// VoIP token fetched from PushKit before sign-in completed. iOS may
    /// hand us the token any time after `PKPushRegistry.register(forType:)`
    /// regardless of auth state, so we stash it and flush on sign-in.
    private var pendingVoipTokenHex: String?

    /// The conversation currently on screen, if any. Set by ConversationView
    /// while it's visible; willPresent suppresses the foreground banner for a
    /// push targeting this conv (the open view shows the message live).
    var activeConversationId: String?

    // MARK: - Public lifecycle hooks

    /// Called from PendingBotApp when AccountStore.current goes from nil → set.
    /// Idempotent; safe to call multiple times.
    func onSignedIn() async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
        // Flush any VoIP token PushKit already handed us pre-sign-in.
        // PushKit registration happens at app launch (see VoIPPushService),
        // so the token typically arrives before this; on first launch /
        // sign-in it may arrive after, which the VoIPPushService delegate
        // handles directly.
        if let pending = pendingVoipTokenHex {
            pendingVoipTokenHex = nil
            await registerVoipTokenIfNeeded(hex: pending)
        }
    }

    /// Called from AppDelegate after the system hands us the token blob.
    func handleDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard hex != lastRegisteredToken else { return }
        lastRegisteredToken = hex
        Task { await registerWithBackend(hex: hex, kind: "apns") }
    }

    /// Called from VoIPPushService when PushKit hands us a token. Stashes
    /// until sign-in if we don't yet have a session, otherwise uploads
    /// immediately. Idempotent on the hex string.
    func handleVoIPToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard hex != lastRegisteredVoipToken else { return }
        if AccountStore.shared.current == nil {
            // No auth yet — stash and flush on onSignedIn().
            pendingVoipTokenHex = hex
            return
        }
        Task { await registerVoipTokenIfNeeded(hex: hex) }
    }

    /// VoIP token invalidated by iOS (PushKit pushRegistry didInvalidate).
    /// Drop our cached copy so the next valid token triggers a fresh
    /// upload; we don't proactively notify the worker — Apple's APNs will
    /// 410 the dead token on the next push attempt and `push.ts` will
    /// retire it via the BadDeviceToken path.
    func handleVoIPTokenInvalidation() {
        lastRegisteredVoipToken = nil
        pendingVoipTokenHex = nil
    }

    private func registerVoipTokenIfNeeded(hex: String) async {
        guard hex != lastRegisteredVoipToken else { return }
        lastRegisteredVoipToken = hex
        await registerWithBackend(hex: hex, kind: "voip")
    }

    /// Called from AppDelegate when registration fails. We don't retry —
    /// most failures are entitlement/provisioning issues that won't resolve
    /// without a rebuild. Logged for diagnostics.
    func handleRegistrationFailure(_ error: Error) {
        log.error("APNS registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Private

    private func requestPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    private func registerWithBackend(hex: String, kind: String) async {
        do {
            let body: [String: Any] = [
                "platform": "ios",
                "token": hex,
                "apnsEnv": Self.detectApnsEnv(),
                "kind": kind,
            ]
            var req = URLRequest(url: HostedConfig.environment.workerURL
                .appendingPathComponent("v1/devices/register"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("register HTTP \(http.statusCode, privacy: .public)")
            }
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read the `aps-environment` entitlement from the embedded provisioning
    /// profile. Falls back gracefully for builds without one (App Store).
    private static func detectApnsEnv() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // App Store builds strip the embedded profile — those are always
            // production. Simulator / unit test runs land here too; the
            // server only routes 'prod' tokens to api.push.apple.com so a
            // mistakenly-prod token from the simulator just won't deliver.
            return "prod"
        }
        // The profile is a CMS-signed blob that contains the entitlements
        // plist as plain XML between `<?xml` and `</plist>`.
        let raw = String(decoding: data, as: UTF8.self)
        guard let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else {
            return "dev"
        }
        let plistRange = start.lowerBound..<end.upperBound
        let plistData = Data(raw[plistRange].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String else {
            return "dev"
        }
        return env == "production" ? "prod" : "dev"
    }
}

// MARK: - AppDelegate adaptor

/// Minimal UIApplicationDelegate that bridges the iOS push lifecycle into
/// PushService. SwiftUI app embeds this via @UIApplicationDelegateAdaptor.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Stand up the PushKit registry now — iOS may deliver a VoIP push
        // (waking us from a cold launch) before any other code runs, and
        // the delegate must be wired before that happens. The CallKit
        // provider's setDelegate is similarly idempotent and gets armed
        // here so the answer/decline path is ready when the first push
        // arrives.
        VoIPPushService.shared.bootstrap()
        CallKitManager.shared.bootstrap()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared.handleDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushService.shared.handleRegistrationFailure(error) }
    }

    /// Show alert / play sound while the app is foreground — matches user
    /// expectation for IM-style apps. List view's Realtime channel will
    /// also pick up the same message, so the alert is mostly a heads-up.
    /// Exception: if the push targets the conversation already on screen,
    /// drop the banner/sound (the open view shows it live) and keep only
    /// the badge update.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
                                -> UNNotificationPresentationOptions {
        let convId = notification.request.content.userInfo["conversationId"] as? String
        if let convId, await PushService.shared.activeConversationId == convId {
            return [.badge]
        }
        return [.banner, .sound, .badge]
    }

    // Voice rings are now delivered as PushKit VoIP pushes that surface
    // CallKit's system incoming-call UI directly — no UNUserNotification
    // tap handler needed for that path. Any other actionable
    // notification kinds would land here in the future.
}

/// One-slot store observed by MessageTabView + ConversationView to react
/// to an accepted incoming CallKit call. The CallKitManager answer
/// callback sets both fields together:
///   • `pendingNavConversationId` — MessageTabView pushes/selects the
///     conversation, then nils it out.
///   • `pendingAutoJoinConversationId` — ConversationView's onAppear
///     auto-opens GroupCallView (no second tap), then nils it out.
/// Keeping the two slots separate avoids a race between MessageTabView
/// nav-on-set and ConversationView read-on-appear — the nav-side field
/// can clear without taking the auto-join signal with it.
@MainActor
@Observable
final class IncomingCallStore {
    static let shared = IncomingCallStore()
    private init() {}

    var pendingNavConversationId: String?
    var pendingAutoJoinConversationId: String?
}

// MARK: - PushKit / VoIP

/// PushKit registry owner. Initialised at app launch (so the
/// `pushRegistry(didReceiveIncomingPushWith:)` delegate is wired before
/// iOS hands us a wake-up push after relaunch) and held across the
/// app's lifetime — Apple's VoIP push contract: every push delivered to
/// this registry **must** be reported to CallKit as an incoming call,
/// or iOS will revoke our VoIP privileges. There is no "ignore" path.
///
/// Token upload is gated on auth state inside PushService — PushKit can
/// hand us the token before the user signs in, which we stash until
/// AccountStore.current goes non-nil.
@MainActor
final class VoIPPushService: NSObject {
    static let shared = VoIPPushService()

    private let registry: PKPushRegistry

    private override init() {
        // PKPushRegistry expects to be created on the main queue and
        // posts callbacks there by default — we set the delegate queue
        // explicitly so the callbacks land on main even on first launch.
        self.registry = PKPushRegistry(queue: .main)
        super.init()
        registry.delegate = self
        // Subscribing to .voIP makes us a VoIP-eligible app; the system
        // mints a token (delivered via the delegate) and starts routing
        // future VoIP pushes to us — including from cold launch.
        registry.desiredPushTypes = [.voIP]
    }

    /// Called from PendingBotApp.init via AppDelegate to materialise the
    /// singleton. No-op afterwards (init does all the work).
    func bootstrap() {}
}

extension VoIPPushService: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType,
    ) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        Task { @MainActor in PushService.shared.handleVoIPToken(token) }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType,
    ) {
        guard type == .voIP else { return }
        Task { @MainActor in PushService.shared.handleVoIPTokenInvalidation() }
    }

    /// Apple's hard contract: this delegate must call CallKit's
    /// `reportNewIncomingCall` synchronously-ish (before the system kills
    /// us for not producing an incoming-call surface) and only call
    /// `completion()` after `reportNewIncomingCall` finishes. On iOS 13+
    /// failing this path repeatedly costs us VoIP push privileges
    /// app-wide.
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void,
    ) {
        guard type == .voIP else { completion(); return }
        let dict = payload.dictionaryPayload
        Task { @MainActor in
            // Pull the fields the worker stamped onto the VoIP payload.
            // Anything missing → report a minimal call so we still
            // satisfy the OS contract (rather than skipping report and
            // losing privileges); the user just sees a blank caller name.
            let kind = dict["kind"] as? String
            let convId = dict["conversation_id"] as? String ?? ""
            let uuidStr = dict["call_uuid"] as? String
            let callerName = dict["caller_display_name"] as? String ?? "未知"
            let groupTitle = dict["group_title"] as? String ?? "群语音"
            let uuid: UUID = uuidStr.flatMap(UUID.init(uuidString:)) ?? UUID()
            if kind != "voice_ring" {
                // Unknown kinds — still report (Apple's contract) but as
                // a generic call. The user can decline.
                CallKitManager.shared.reportIncomingCall(
                    uuid: uuid,
                    conversationId: convId,
                    callerDisplayName: callerName,
                    groupTitle: groupTitle,
                    completion: { _ in completion() },
                )
                return
            }
            CallKitManager.shared.reportIncomingCall(
                uuid: uuid,
                conversationId: convId,
                callerDisplayName: callerName,
                groupTitle: groupTitle,
                completion: { _ in completion() },
            )
        }
    }
}
#endif
