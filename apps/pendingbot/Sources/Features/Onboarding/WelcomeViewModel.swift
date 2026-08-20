import SwiftUI

/// Shared sign-in state machine for the signed-out screen, driving BOTH the
/// iOS `WelcomeView` and the native macOS `MacWelcomeView`. The two platforms
/// render the same flow with platform-native controls (UIKit vs AppKit text
/// fields, a `UIViewRepresentable` vs `NSViewRepresentable` Turnstile webview,
/// glass material vs material fallback) but share every piece of *logic* here
/// so the email-OTP / Apple / Google flows can't drift between platforms.
///
/// Flow: email entry → "你是？" human-check (pre-loads a Cloudflare Turnstile
/// token in the background) → code entry once the OTP has been sent. Apple and
/// Google go straight through `AppleSignIn` / `PendingGoogleSignIn` (both now
/// cross-platform). The view layer owns only `@FocusState` and the actual
/// representable widget; it reacts to published state via `onChange`.
@MainActor
final class WelcomeViewModel: ObservableObject {
    enum Stage {
        case enteringEmail
        case humanCheck
    }

    enum HumanChoice {
        case undecided
        case human
        case robot
    }

    @Published var stage: Stage = .enteringEmail
    /// Orthogonal to `stage`: true during any in-flight auth round-trip
    /// (email-code verify, Apple SIWA token exchange, Google sign-in).
    /// Kept separate from `stage` so Apple/Google verification doesn't
    /// flip the UI into the email-code step.
    @Published var isVerifying: Bool = false
    @Published var email: String = ""
    @Published var code: String = ""

    // MARK: Human-check stage state

    @Published var humanChoice: HumanChoice = .undecided
    /// Latest Turnstile token. Captured silently as soon as Cloudflare
    /// emits one; cleared once consumed by `sendCode`.
    @Published var turnstileToken: String?
    /// True between "user tapped 人类" and "we issued a sendCode call" —
    /// flips back to false the moment a token is consumed. Lets the
    /// async token callback know it should fire sendCode immediately.
    @Published var awaitingTurnstileSend: Bool = false
    /// Cloudflare actually wants the user to interact (rare). Until this
    /// flips true, the widget stays collapsed and the user only sees a
    /// "正在验证…" affordance.
    @Published var turnstileInteractive: Bool = false
    /// Set on hard widget failure (script load timeout, expired, etc).
    @Published var turnstileFailed: Bool = false
    /// Bumping this id remounts the underlying webview so we get a fresh
    /// token — used on resend, since Turnstile tokens are single-use.
    @Published var turnstileWidgetID: UUID = UUID()
    /// True after the first successful `sendCode`. Used to flip the
    /// status row from "码将发至" / 发送 → "码已发至" / 重发, and to
    /// reveal the code-entry input.
    @Published var otpSent: Bool = false
    /// Seconds remaining on the resend cooldown. >0 ⇒ button is the
    /// grey countdown; ==0 ⇒ "重发" is tappable again.
    @Published var resendCooldown: Int = 0
    @Published var errorText: String?
    /// Non-error copy shown when the tapped sign-in method has no backend
    /// coordinate in this build. Kept separate from `errorText` so it can be
    /// rendered in neutral ink — nothing failed, the coordinate simply isn't
    /// in a public clone. Set on tap, never at launch.
    @Published var noticeText: String?

    // MARK: - Derived state

    // MARK: Configured-or-not
    //
    // Both read `HostedConfig`, which is the single source of truth (README
    // cites it too). We check at the moment a method is *tapped* rather than
    // disabling the buttons at launch: a dead control with no explanation is
    // exactly the "this software is broken" impression this is meant to avoid.

    /// Worker + Supabase coordinates present — Apple / Google sign-in can run.
    var isHostedConfigured: Bool { HostedConfig.isConfigured }

    /// Above, plus a real Turnstile site key — the email-code path can run.
    var isEmailSignInConfigured: Bool { HostedConfig.isEmailSignInConfigured }

    /// Sets `noticeText` and returns false when the hosted line is missing.
    private func requireHostedConfigured() -> Bool {
        guard isHostedConfigured else {
            errorText = nil
            noticeText = HostedConfig.unconfiguredNotice
            return false
        }
        return true
    }

    /// True once we're ready to surface the verify-code block: Turnstile
    /// has handed us a token (we just need the user to tap 发送), an OTP
    /// request is already in flight, or one has been sent at least once.
    var codeBlockShown: Bool {
        humanChoice == .human && (turnstileToken != nil || otpSent || isVerifying)
    }

    var isBusy: Bool { isVerifying }

    /// Whether the email address looks well-formed enough to advance.
    var emailLooksValid: Bool {
        email.contains("@") && email.contains(".")
    }

    /// Whether the trailing arrow / primary button can fire in the current stage.
    var canSubmit: Bool {
        if isVerifying { return false }
        switch stage {
        case .enteringEmail:
            return emailLooksValid
        case .humanCheck:
            return otpSent && code.count >= 4
        }
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Resend cooldown

    /// Driven by the view's 1s timer.
    func tickResendCooldown() {
        if resendCooldown > 0 { resendCooldown -= 1 }
    }

    // MARK: - Stage transitions

    func backToEmailEntry() {
        if isVerifying { return }
        errorText = nil
        noticeText = nil
        humanChoice = .undecided
        turnstileToken = nil
        awaitingTurnstileSend = false
        turnstileInteractive = false
        turnstileFailed = false
        otpSent = false
        code = ""
        resendCooldown = 0
        // Drop the webview so it stops loading; it'll be remounted with
        // a fresh id next time the user advances.
        turnstileWidgetID = UUID()
        stage = .enteringEmail
    }

    /// Returns true if it actually advanced (email was valid).
    @discardableResult
    func advanceToHumanCheck() -> Bool {
        guard emailLooksValid else { return false }
        guard requireHostedConfigured() else { return false }
        guard isEmailSignInConfigured else {
            errorText = nil
            noticeText = HostedConfig.emailSignInUnconfiguredNotice
            return false
        }
        errorText = nil
        noticeText = nil
        humanChoice = .undecided
        turnstileToken = nil
        awaitingTurnstileSend = false
        turnstileInteractive = false
        turnstileFailed = false
        otpSent = false
        // New widget instance ⇒ fresh token. Cheap because the webview
        // hasn't been mounted yet (we're about to enter humanCheck).
        turnstileWidgetID = UUID()
        stage = .humanCheck
        return true
    }

    func tapHuman() {
        if codeBlockShown { return }
        humanChoice = .human
        errorText = nil
        if turnstileFailed {
            // Force a fresh widget — the previous one already errored.
            turnstileFailed = false
            turnstileInteractive = false
            turnstileToken = nil
            turnstileWidgetID = UUID()
        }
    }

    func tapRobot() {
        humanChoice = .robot
    }

    // MARK: - Turnstile callbacks

    func handleTurnstileToken(_ token: String) {
        turnstileToken = token
        // Resend path: the user has already implicitly authorized a send,
        // so consume the fresh token immediately.
        if awaitingTurnstileSend {
            awaitingTurnstileSend = false
            turnstileToken = nil
            Task { await sendCode(captchaToken: token) }
        }
    }

    func handleTurnstileError(_ msg: String) {
        turnstileFailed = true
        turnstileInteractive = false
        // Drop any prior token — error/expired callbacks invalidate it,
        // and we don't want the 发送 button to remain tappable with a
        // stale value.
        turnstileToken = nil
        if humanChoice == .human {
            errorText = "人机验证失败：\(msg)"
            Haptics.error()
        }
        awaitingTurnstileSend = false
    }

    func markTurnstileInteractive() {
        turnstileInteractive = true
    }

    /// First-tap 发送 in the status row: consume the Turnstile token already
    /// in hand and fire the initial OTP.
    func tapSend() {
        guard let token = turnstileToken else { return }
        turnstileToken = nil
        // Flip isVerifying synchronously so SwiftUI's next render already
        // sees an in-flight state — otherwise there's a one-frame gap where
        // the code block falls back to "正在验证…".
        isVerifying = true
        Task { await sendCode(captchaToken: token) }
    }

    // MARK: - Email-code flow

    func sendCode(captchaToken: String) async {
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await EmailSignIn.requestCode(
                email: trimmedEmail,
                captchaToken: captchaToken
            )
            otpSent = true
            resendCooldown = 60
            Haptics.tap()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    func resend() async {
        if resendCooldown > 0 || isVerifying { return }
        errorText = nil
        // Fresh Turnstile token: bump widget id, then either reuse a
        // newly-arrived token or wait for one (revealing the widget if
        // CF demands an interaction).
        turnstileToken = nil
        turnstileInteractive = false
        turnstileFailed = false
        turnstileWidgetID = UUID()
        awaitingTurnstileSend = true
    }

    func verifyCode() async {
        guard otpSent else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            _ = try await EmailSignIn.verify(
                email: trimmedEmail,
                code: code.trimmingCharacters(in: .whitespaces)
            )
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    // MARK: - Apple / Google

    func beginApple() async {
        guard requireHostedConfigured() else { return }
        errorText = nil
        noticeText = nil
        isVerifying = true
        defer { isVerifying = false }
        do {
            _ = try await AppleSignIn.run()
            Haptics.success()
        } catch AppleSignIn.Error.userCancelled {
            // user backed out of the SIWA sheet — silent, stay put
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    func beginGoogle() async {
        guard requireHostedConfigured() else { return }
        errorText = nil
        noticeText = nil
        isVerifying = true
        defer { isVerifying = false }
        do {
            _ = try await PendingGoogleSignIn.run()
            Haptics.success()
        } catch PendingGoogleSignIn.Error.userCancelled {
            // user backed out of the Google sheet — silent, stay put
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }
}
