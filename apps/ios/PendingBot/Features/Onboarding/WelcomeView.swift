import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit

/// First-launch / signed-out screen. Logo on top, three sign-in methods below
/// (Apple, Google, email-code). Email path uses an inline TextField with a
/// trailing arrow button — tapping the arrow advances to a "你是？"
/// human-check stage that pre-loads a Cloudflare Turnstile token in the
/// background, then drops the user straight into a code-entry row once
/// the OTP has been sent.
///
/// Auth wiring goes through the supabase-swift helpers AppleSignIn /
/// PendingGoogleSignIn / EmailSignIn.
struct WelcomeView: View {
    enum Stage {
        case enteringEmail
        case humanCheck
    }

    enum HumanChoice {
        case undecided
        case human
        case robot
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore

    @State private var stage: Stage = .enteringEmail
    /// Orthogonal to `stage`: true during any in-flight auth round-trip
    /// (email-code verify, Apple SIWA token exchange, Google sign-in).
    /// Kept separate from `stage` so Apple/Google verification doesn't
    /// flip the UI into the email-code step.
    @State private var isVerifying: Bool = false
    @State private var email: String = ""
    @State private var code: String = ""

    // MARK: Human-check stage state

    @State private var humanChoice: HumanChoice = .undecided
    /// Latest Turnstile token. Captured silently as soon as Cloudflare
    /// emits one; cleared once consumed by `sendCode`.
    @State private var turnstileToken: String?
    /// True between "user tapped 人类" and "we issued a sendCode call" —
    /// flips back to false the moment a token is consumed. Lets the
    /// async token callback know it should fire sendCode immediately.
    @State private var awaitingTurnstileSend: Bool = false
    /// Cloudflare actually wants the user to interact (rare). Until this
    /// flips true, the widget stays collapsed to a 1pt sliver and the
    /// user only sees a "正在验证…" affordance.
    @State private var turnstileInteractive: Bool = false
    /// Set on hard widget failure (script load timeout, expired, etc).
    @State private var turnstileFailed: Bool = false
    /// Bumping this id remounts the underlying `WKWebView` so we get a
    /// fresh token — used on resend, since Turnstile tokens are
    /// single-use.
    @State private var turnstileWidgetID: UUID = UUID()
    /// True after the first successful `sendCode`. Used to flip the
    /// status row from "码将发至" / 发送 → "码已发至" / 重发, and to
    /// reveal the code-entry input.
    @State private var otpSent: Bool = false
    /// Seconds remaining on the resend cooldown. >0 ⇒ button is the
    /// grey countdown; ==0 ⇒ "重发" is tappable again.
    @State private var resendCooldown: Int = 0

    /// Random nonce mixed into the SIWA request. Apple bakes its SHA-256
    /// hash into the identity token; Supabase verifies replay-protection.
    /// Generated once per appearance — must not change mid-flow.
    @State private var siwaNonce: String = WelcomeView.randomNonce()
    @State private var errorText: String?
    @State private var appleCoordinator: AppleSignInCoordinator?
    @FocusState private var focusedField: Field?

    enum Field { case email, code }

    private let resendTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Top half: brand mark, vertically centered.
            Image("BrandMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 16, y: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom half: branches by stage.
            VStack(alignment: .leading, spacing: 0) {
                switch stage {
                case .enteringEmail:
                    enteringEmailBody
                case .humanCheck:
                    humanCheckBody
                        .transition(.opacity)
                }

                if let errorText {
                    errorBlock(text: errorText)
                        .padding(.top, 12)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // Keyboard avoidance respects the bottom safe-area inset, so
        // adding a clear strip here lifts the verify-code row off the
        // keyboard instead of letting it stick flush against it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 24)
        }
        .overlay(alignment: .topLeading) {
            if stage == .humanCheck {
                backButton
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Don't grab focus for the email field — let users tap it
            // explicitly so the keyboard doesn't fly up on launch.
            if otpSent { focusedField = .code }
        }
        .onReceive(resendTimer) { _ in
            if resendCooldown > 0 { resendCooldown -= 1 }
        }
        .animation(.easeInOut(duration: 0.28), value: stage)
        .animation(.easeInOut(duration: 0.28), value: humanChoice)
        .animation(.easeInOut(duration: 0.28), value: otpSent)
        .animation(.easeInOut(duration: 0.28), value: codeBlockShown)
        .animation(.easeInOut(duration: 0.28), value: turnstileInteractive)
    }

    // MARK: - Stage: entering email

    @ViewBuilder
    private var enteringEmailBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("登录 / 注册：")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.leading, 4)
                .padding(.bottom, 22)

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    appleButton
                    googleButton
                }
                emailRow
            }
            .disabled(isBusy)
        }
    }

    // MARK: - Stage: human check

    @ViewBuilder
    private var humanCheckBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("你是？")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.leading, 4)

            HStack(spacing: 12) {
                humanButton
                robotButton
            }
            .disabled(isBusy || codeBlockShown)

            // The Turnstile widget is mounted as soon as we land on this
            // stage so it can pre-load while the user reads the prompt.
            // It collapses to a 1pt sliver when CF doesn't need a real
            // interaction, then animates open if the `interactive`
            // callback fires.
            turnstileWidget

            // Sub-content under the buttons. The code block is shown
            // as soon as Turnstile clears (or the OTP has already been
            // sent at least once); the inline "发送" tap is what
            // actually fires the OTP. While CF is still working on a
            // silent pass, show a small loading hint instead.
            Group {
                if codeBlockShown {
                    codeBlock
                        .transition(.opacity)
                } else if humanChoice == .robot {
                    robotEasterEgg
                        .transition(.opacity)
                } else if humanChoice == .human && !turnstileInteractive && !turnstileFailed {
                    verifyingHint
                        .transition(.opacity)
                }
            }
        }
    }

    /// Test-account back door: any `@pendingname.com` address (case-
    /// insensitive, after trimming) skips Turnstile *and* the actual
    /// `signInWithOTP` call. The verify-code UI flows exactly as it
    /// would for a real address — same labels, same cooldown — but no
    /// CF challenge is mounted and no email is sent. Codes are pulled
    /// out-of-band via the Supabase admin API for these accounts.
    private var isTestEmail: Bool {
        email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix("@pendingname.com")
    }

    /// True once we're ready to surface the verify-code block: either
    /// the address is a test domain (instant), Turnstile has handed us
    /// a token (we just need the user to tap 发送), an OTP request is
    /// already in flight, or one has been sent at least once. Including
    /// `isVerifying` covers the gap between consuming the token and
    /// `otpSent` flipping true — without
    /// it the block would briefly drop back to "正在验证…" while the
    /// network round-trip is in progress.
    private var codeBlockShown: Bool {
        humanChoice == .human && (isTestEmail || turnstileToken != nil || otpSent || isVerifying)
    }

    /// Top-left chevron back to the email-entry stage. Native glass on
    /// iOS 26+ via `.glassEffect`; pre-26 falls back to a thin material
    /// circle so it still reads as a button.
    private var backButton: some View {
        Button { backToEmailEntry() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 38, height: 38)
                .glassCircle()
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isVerifying)
        .accessibilityLabel("返回")
    }

    private var humanButton: some View {
        Button {
            tapHuman()
        } label: {
            choicePill(text: "人类", filled: humanChoice == .human)
        }
        .buttonStyle(.plain)
    }

    private var robotButton: some View {
        Button {
            humanChoice = .robot
        } label: {
            choicePill(text: "机器人", filled: humanChoice == .robot)
        }
        .buttonStyle(.plain)
    }

    private func choicePill(text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(filled ? .white : Theme.Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Group {
                    if filled {
                        Capsule().fill(Theme.Palette.accent)
                    } else {
                        Capsule().fill(Color.clear)
                    }
                }
            )
            .overlay(
                Capsule().strokeBorder(
                    filled ? Color.clear : Theme.Palette.ink.opacity(0.18),
                    lineWidth: 1
                )
            )
            .shadow(color: filled ? Color.black.opacity(0.18) : .clear, radius: 10, y: 4)
            .contentShape(Capsule())
    }

    /// Always-mounted Turnstile widget for real addresses. Stays at
    /// 1pt height + opacity 0 for silent passes; only animates open if
    /// Cloudflare actually fires the `before-interactive-callback`.
    /// Test-domain addresses bypass it entirely so we don't burn CF
    /// quota on accounts that aren't going through email at all.
    @ViewBuilder
    private var turnstileWidget: some View {
        if !isTestEmail {
            let visible = humanChoice == .human && !codeBlockShown && turnstileInteractive
            TurnstileWebView(
                siteKey: HostedConfig.environment.turnstileSiteKey,
                host: HostedConfig.environment.turnstileHost,
                onToken: { token in handleTurnstileToken(token) },
                onError: { msg in handleTurnstileError(msg) },
                onInteractive: { turnstileInteractive = true }
            )
            .frame(maxWidth: .infinity)
            .frame(height: visible ? 80 : 1)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .id(turnstileWidgetID)
        }
    }

    private var verifyingHint: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在验证…")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.horizontal, 4)
    }

    private var codeBlock: some View {
        VStack(spacing: 14) {
            codeStatusRow
            if otpSent {
                codeRow
                    .transition(.opacity)
            }
        }
    }

    private var codeStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text("\(otpSent ? "码已发至：" : "码将发至：")\(email)")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            sendOrResendButton
        }
        .padding(.horizontal, 4)
    }

    /// Right-side action in the status row. The first tap fires the
    /// initial OTP using the Turnstile token already in hand; later
    /// taps go through `resend` (which remounts the widget for a
    /// fresh single-use token). Greyed-out countdown when on cooldown.
    private var sendOrResendButton: some View {
        Group {
            if resendCooldown > 0 {
                Text("\(resendCooldown)s")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.7))
            } else if !otpSent {
                Button("发送") {
                    let token: String?
                    if isTestEmail {
                        // Test back door — call signInWithOTP with no
                        // captcha token so we can observe whether the
                        // Supabase backend actually enforces it.
                        token = nil
                    } else {
                        guard let t = turnstileToken else { return }
                        turnstileToken = nil
                        token = t
                    }
                    // Flip isVerifying synchronously so SwiftUI's next
                    // render already sees an in-flight state — otherwise
                    // there's a one-frame gap where the code block
                    // falls back to "正在验证…".
                    isVerifying = true
                    Task { await sendCode(captchaToken: token) }
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                .disabled(isVerifying || (!isTestEmail && turnstileToken == nil))
            } else {
                Button("重发") {
                    Task { await resend() }
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                .disabled(isVerifying)
            }
        }
    }

    private var robotEasterEgg: some View {
        VStack(spacing: 22) {
            Text("😲😲😲")
                .font(.system(size: 56))
            VStack(spacing: 10) {
                Text("尊敬的机器人您好，请联系 kipper_yonder.0u@icloud.com")
                Text("我会稳稳地接住你")
                Text("我还可以帮你生成我和机器人的关系图")
            }
            .font(Theme.Fonts.footnote)
            .foregroundStyle(Theme.Palette.ink)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Apple / Google buttons

    /// Apple sign-in button. Custom-styled because SwiftUI's
    /// `SignInWithAppleButton` ships fixed Apple-localized labels only
    /// ("通过 Apple 继续" etc.) and we want the single word "Apple" so it
    /// pairs visually with the Google pill — both labels then have similar
    /// widths and the logos line up naturally. The actual SIWA flow is
    /// still driven through Apple's own `ASAuthorizationController` API;
    /// only the button styling is custom.
    private var appleButton: some View {
        Button { triggerAppleSignIn() } label: {
            brandPillContent(logo: appleLogoImage, text: "Apple", textColor: .white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(.black))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }

    /// Google sign-in button. Same internal pill layout as `appleButton`,
    /// so the logos sit at matching X positions.
    private var googleButton: some View {
        Button { Task { await beginGoogle() } } label: {
            brandPillContent(
                logo: AnyView(Image("GoogleG").resizable().scaledToFit()),
                text: "Google",
                textColor: Color(red: 0.18, green: 0.18, blue: 0.20)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .glassCapsule()
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Google")
    }

    /// Picks the official Apple-supplied logo-only artwork when present,
    /// falling back to the SF Symbol while the asset hasn't been dropped
    /// in yet (see Assets.xcassets/AppleSignInLogo.imageset/README.md).
    private var appleLogoImage: AnyView {
        if UIImage(named: "AppleSignInLogo") != nil {
            AnyView(
                Image("AppleSignInLogo")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .scaledToFit()
            )
        } else {
            AnyView(
                Image(systemName: "applelogo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
            )
        }
    }

    /// Shared inner layout for both brand pills: a 19pt logo + 10pt gap
    /// + the brand word, the whole combo centered. Identical structure
    /// on both buttons means the logos sit at the same X coordinate as
    /// long as the text widths match — and "Apple" / "Google" are both
    /// 5–6 ASCII chars at the same font, so they line up to within a
    /// glyph-width without any per-button tweaking.
    private func brandPillContent(
        logo: AnyView, text: String, textColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            logo.frame(width: 19, height: 19)
            Text(text)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(textColor)
        }
    }

    // MARK: - Email row (stage: enteringEmail)

    private var emailRow: some View {
        inputRow {
            TextField("邮箱", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.continue)
                .onSubmit { advanceToHumanCheck() }
        }
    }

    private var codeRow: some View {
        inputRow {
            TextField("码可能在垃圾邮件里", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
                .submitLabel(.go)
                .onSubmit { Task { await verifyCode() } }
        }
    }

    /// One row: a text input on the left, a green circular submit button
    /// on the right. The button shows the arrow when idle, a spinner when
    /// busy, and dims when the input is empty/invalid.
    @ViewBuilder
    private func inputRow<Content: View>(
        @ViewBuilder field: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            field()
                .font(.system(size: 17))
                .padding(.leading, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            submitArrowButton
                .padding(.trailing, 7)
        }
        .frame(height: 52)
        .glassCapsule()
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private var submitArrowButton: some View {
        Button {
            switch stage {
            case .enteringEmail: advanceToHumanCheck()
            case .humanCheck:    Task { await verifyCode() }
            }
        } label: {
            Group {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(canSubmit ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.28))
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isBusy)
        .animation(.easeInOut(duration: 0.15), value: canSubmit)
    }

    private func errorBlock(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived state

    private var isBusy: Bool { isVerifying }

    private var canSubmit: Bool {
        if isVerifying { return false }
        switch stage {
        case .enteringEmail:
            return email.contains("@") && email.contains(".")
        case .humanCheck:
            return otpSent && code.count >= 4
        }
    }

    // MARK: - Email-code flow

    private func backToEmailEntry() {
        if isVerifying { return }
        errorText = nil
        humanChoice = .undecided
        turnstileToken = nil
        awaitingTurnstileSend = false
        turnstileInteractive = false
        turnstileFailed = false
        otpSent = false
        code = ""
        resendCooldown = 0
        // Drop the WebView so it stops loading; it'll be remounted with
        // a fresh id next time the user advances.
        turnstileWidgetID = UUID()
        stage = .enteringEmail
        focusedField = .email
    }

    private func advanceToHumanCheck() {
        guard email.contains("@") && email.contains(".") else { return }
        errorText = nil
        focusedField = nil
        humanChoice = .undecided
        turnstileToken = nil
        awaitingTurnstileSend = false
        turnstileInteractive = false
        turnstileFailed = false
        otpSent = false
        // New widget instance ⇒ fresh token. Cheap because the WebView
        // hasn't been mounted yet (we're about to enter humanCheck).
        turnstileWidgetID = UUID()
        stage = .humanCheck
    }

    @MainActor
    private func tapHuman() {
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

    @MainActor
    private func handleTurnstileToken(_ token: String) {
        turnstileToken = token
        // Resend path: the user has already implicitly authorized a send,
        // so consume the fresh token immediately.
        if awaitingTurnstileSend {
            awaitingTurnstileSend = false
            turnstileToken = nil
            Task { await sendCode(captchaToken: token) }
        }
    }

    @MainActor
    private func handleTurnstileError(_ msg: String) {
        turnstileFailed = true
        turnstileInteractive = false
        // Drop any prior token — error/expired callbacks invalidate it,
        // and we don't want the 发送 button to remain tappable with a
        // stale value (which the Supabase backend may or may not reject
        // depending on whether captcha-secret is configured).
        turnstileToken = nil
        if humanChoice == .human {
            errorText = "人机验证失败：\(msg)"
            Haptics.error()
        }
        awaitingTurnstileSend = false
    }

    @MainActor
    private func sendCode(captchaToken: String?) async {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await EmailSignIn.requestCode(
                email: trimmed,
                captchaToken: captchaToken
            )
            otpSent = true
            resendCooldown = 60
            focusedField = .code
            Haptics.tap()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    @MainActor
    private func resend() async {
        if resendCooldown > 0 || isVerifying { return }
        errorText = nil
        if isTestEmail {
            // Re-send straight through with no captcha token.
            await sendCode(captchaToken: nil)
            return
        }
        // Fresh Turnstile token: bump widget id, then either reuse a
        // newly-arrived token or wait for one (revealing the widget if
        // CF demands an interaction).
        turnstileToken = nil
        turnstileInteractive = false
        turnstileFailed = false
        turnstileWidgetID = UUID()
        awaitingTurnstileSend = true
    }

    @MainActor
    private func verifyCode() async {
        guard otpSent else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            _ = try await EmailSignIn.verify(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                code: code.trimmingCharacters(in: .whitespaces)
            )
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    // MARK: - SIWA helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    private func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Apple SIWA

    /// Custom-button replacement for `SignInWithAppleButton`. Drives the
    /// same Apple flow (`ASAuthorizationAppleIDProvider`) the SwiftUI
    /// wrapper uses; we just lose Apple's pre-styled button.
    @MainActor
    private func triggerAppleSignIn() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email, .fullName]
        request.nonce = sha256Hex(siwaNonce)

        let coordinator = AppleSignInCoordinator { result in
            Task { await handleAppleResult(result) }
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = coordinator
        controller.presentationContextProvider = coordinator
        // Hold a strong ref — ASAuthorizationController doesn't retain
        // its delegate, and the coordinator must outlive performRequests().
        self.appleCoordinator = coordinator
        // performRequests() internally waits on a Default-QoS thread, which
        // Xcode flags as a hang risk when invoked from the userInteractive
        // main actor. Hop to a userInitiated queue to avoid the priority
        // inversion; the controller dispatches presentation back to main via
        // its presentationContextProvider.
        nonisolated(unsafe) let unsafeController = controller
        DispatchQueue.global(qos: .userInitiated).async {
            unsafeController.performRequests()
        }
    }

    @MainActor
    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        errorText = nil
        switch result {
        case .failure(let err):
            if (err as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            errorText = err.localizedDescription
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorText = "Apple 没返回 identity token"
                return
            }
            isVerifying = true
            defer { isVerifying = false }
            do {
                _ = try await SupabaseStack.shared.auth.signInWithIdToken(
                    credentials: .init(provider: .apple,
                                       idToken: idToken,
                                       nonce: siwaNonce)
                )
                Haptics.success()
            } catch {
                errorText = error.localizedDescription
                Haptics.error()
            }
        }
    }

    // MARK: - Google

    @MainActor
    private func beginGoogle() async {
        errorText = nil
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

/// Bridges `ASAuthorizationController`'s Objective-C delegate callbacks
/// into the SwiftUI-friendly `Result` closure that `WelcomeView` already
/// understands. One instance per sign-in attempt; the view holds it
/// strongly until the controller finishes.
fileprivate final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private let completion: (Result<ASAuthorization, Error>) -> Void

    init(completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.completion = completion
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        completion(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        completion(.failure(error))
    }

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window ?? ASPresentationAnchor()
    }
}

/// iOS 26+ uses the new Liquid Glass material via `.glassEffect`; older
/// systems fall back to the standard system material in a capsule. Both
/// produce a frosted-glass capsule background; the iOS 26 path additionally
/// reacts to motion / what's underneath in true Liquid Glass fashion.
private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }
}
