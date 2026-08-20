import Foundation
import PostHog
import RevenueCat
import Sentry

/// Single coordinator for the three client-side external services that need
/// to know **who the user is**: PostHog (product analytics), Sentry (crash /
/// error tracking) and RevenueCat (billing identity for IAP).
///
/// Why one place instead of scattering SDK calls: all three share the exact
/// same lifecycle — init once at launch, `identify` on sign-in, `reset` on
/// sign-out — and the same input, the user's `subject_id` (= auth.users.id).
/// Folding them here gives one subscription point (PendingBotApp watches
/// `AccountStore.current`), one key-gate, and one spot for any platform `#if`.
///
/// **Identifier policy:** the id handed to all three is the Supabase
/// `auth.users.id`, matching the edge side (`distinctId = subjectId`,
/// Polar `externalId = subjectId`, RevenueCat webhook `app_user_id`). We never
/// pass email or other PII — keeps the user keyed consistently across the whole
/// stack and avoids leaking identifiers into third-party dashboards.
///
/// **Gating:** each SDK is keyed by a value in `HostedConfig`. An empty key
/// means "off" — `configure()` skips that SDK entirely, so `.dev` builds and
/// any not-yet-provisioned service stay silent rather than emitting junk. The
/// RevenueCat key is currently empty (account not provisioned), so its identity
/// wiring is present but dormant until a key lands — see docs/tech-debt.md.
///
/// Main-thread only: every call site is the app entry point or the
/// `AccountStore.current` observer, both on the main actor.
@MainActor
final class Telemetry {
    static let shared = Telemetry()
    private init() {}

    private var posthogOn = false
    private var sentryOn = false
    // RevenueCat tracks its own configured-state via `Purchases.isConfigured`.

    /// Initialise the SDKs whose keys are present. Call as early as possible
    /// (app `init()`, before the first frame) so Sentry can catch launch
    /// crashes and RevenueCat is ready before any purchase UI.
    func configure() {
        let env = HostedConfig.environment

        // Sentry first — earliest init catches the most crashes. DSN empty →
        // SDK never starts, setUser later is a no-op.
        let dsn = env.sentryDSN
        if !dsn.isEmpty {
            SentrySDK.start { options in
                options.dsn = dsn
                // Defaults keep automatic crash + error capture on; PII
                // scrubbing (sendDefaultPii = false) stays at the safe default.
            }
            sentryOn = true
        }

        // PostHog. sessionReplay is left at its default (false) — it's an
        // iOS-only property, so not touching it keeps this file platform-clean.
        let token = env.posthogKey
        if !token.isEmpty {
            let config = PostHogConfig(projectToken: token, host: env.posthogHost)
            config.captureScreenViews = false       // no SwiftUI screen autocapture
            config.personProfiles = .identifiedOnly // only build profiles for identified users
            PostHogSDK.shared.setup(config)
            posthogOn = true
        }

        // RevenueCat — configure anonymous; logIn(subjectId) happens in
        // identify(_:). Key empty (account not yet provisioned) → skip entirely.
        let rcKey = env.revenueCatKey
        if !rcKey.isEmpty {
            Purchases.logLevel = .warn
            Purchases.configure(withAPIKey: rcKey, appUserID: nil)
        }
    }

    /// Link the active session to all configured SDKs. Idempotent — safe to
    /// call again with the same id (cold-launch + later sign-in both route here).
    func identify(_ userId: String) {
        if sentryOn {
            let user = Sentry.User()
            user.userId = userId
            SentrySDK.setUser(user)
        }
        if posthogOn {
            PostHogSDK.shared.identify(userId)
        }
        if Purchases.isConfigured {
            // logIn is async; identity sync must never block or break the
            // sign-in flow, so fire-and-forget and swallow errors.
            Task { _ = try? await Purchases.shared.logIn(userId) }
        }
    }

    /// Clear the user from all configured SDKs on sign-out / account deletion.
    func reset() {
        if sentryOn {
            SentrySDK.setUser(nil)
        }
        if posthogOn {
            PostHogSDK.shared.reset()
        }
        if Purchases.isConfigured {
            Task { _ = try? await Purchases.shared.logOut() }
        }
    }
}
