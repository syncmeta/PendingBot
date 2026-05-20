import Foundation
import UIKit
import UserNotifications
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

    // MARK: - Public lifecycle hooks

    /// Called from PendingBotApp when AccountStore.current goes from nil → set.
    /// Idempotent; safe to call multiple times.
    func onSignedIn() async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from AppDelegate after the system hands us the token blob.
    func handleDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard hex != lastRegisteredToken else { return }
        lastRegisteredToken = hex
        Task { await registerWithBackend(hex: hex) }
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

    private func registerWithBackend(hex: String) async {
        do {
            let body: [String: Any] = [
                "platform": "ios",
                "token": hex,
                "apnsEnv": Self.detectApnsEnv(),
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
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
                                -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    /// User tapped a push. For voice_ring payloads, surface a request to
    /// the UI layer to open the conversation and rejoin the call.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let kind = info["kind"] as? String, kind == "voice_ring",
              let convId = info["conversation_id"] as? String
        else { return }
        await MainActor.run {
            IncomingVoiceRingStore.shared.pendingConversationId = convId
        }
    }
}

/// One-slot store that the message-tab and conversation views observe to
/// react to a tapped "voice_ring" push. The push handler stores the
/// conversation id; ContentView / MessageTabView pops the corresponding
/// conversation onto its nav stack, which in turn shows the call view.
@MainActor
@Observable
final class IncomingVoiceRingStore {
    static let shared = IncomingVoiceRingStore()
    private init() {}

    /// Set by the push handler when the user taps a ring notification.
    /// The observing view consumes (reads + nils-out) the value once it
    /// has acted on it.
    var pendingConversationId: String?
}
