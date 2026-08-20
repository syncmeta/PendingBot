#if os(iOS)
import SwiftUI
import UIKit

/// First-launch / signed-out screen. Logo on top, three sign-in methods below
/// (Apple, Google, email-code). Email path uses an inline TextField with a
/// trailing arrow button — tapping the arrow advances to a "你是？"
/// human-check stage that pre-loads a Cloudflare Turnstile token in the
/// background, then drops the user straight into a code-entry row once
/// the OTP has been sent.
///
/// All flow/auth logic lives in the cross-platform `WelcomeViewModel` (shared
/// with the native macOS `MacWelcomeView`); this view owns only the iOS-native
/// rendering — glass capsules, the `TurnstileWebView` representable, keyboard
/// types, and `@FocusState`.
struct WelcomeView: View {
    @StateObject private var vm = WelcomeViewModel()
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
                switch vm.stage {
                case .enteringEmail:
                    enteringEmailBody
                case .humanCheck:
                    humanCheckBody
                        .transition(.opacity)
                }

                if let noticeText = vm.noticeText {
                    noticeBlock(text: noticeText)
                        .padding(.top, 12)
                }
                if let errorText = vm.errorText {
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
            if vm.stage == .humanCheck {
                backButton
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Don't grab focus for the email field — let users tap it
            // explicitly so the keyboard doesn't fly up on launch.
            if vm.otpSent { focusedField = .code }
        }
        .onChange(of: vm.otpSent) { _, sent in
            if sent { focusedField = .code }
        }
        .onReceive(resendTimer) { _ in
            vm.tickResendCooldown()
        }
        .animation(.easeInOut(duration: 0.28), value: vm.stage)
        .animation(.easeInOut(duration: 0.28), value: vm.humanChoice)
        .animation(.easeInOut(duration: 0.28), value: vm.otpSent)
        .animation(.easeInOut(duration: 0.28), value: vm.codeBlockShown)
        .animation(.easeInOut(duration: 0.28), value: vm.turnstileInteractive)
    }

    // MARK: - Stage: entering email

    @ViewBuilder
    private var enteringEmailBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("登录 / 注册：")
                .font(Theme.Fonts.system(size: 15, weight: .semibold))
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
            .disabled(vm.isBusy)
        }
    }

    // MARK: - Stage: human check

    @ViewBuilder
    private var humanCheckBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("你是？")
                .font(Theme.Fonts.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.leading, 4)

            HStack(spacing: 12) {
                humanButton
                robotButton
            }
            .disabled(vm.isBusy || vm.codeBlockShown)

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
                if vm.codeBlockShown {
                    codeBlock
                        .transition(.opacity)
                } else if vm.humanChoice == .robot {
                    robotEasterEgg
                        .transition(.opacity)
                } else if vm.humanChoice == .human && !vm.turnstileInteractive && !vm.turnstileFailed {
                    verifyingHint
                        .transition(.opacity)
                }
            }
        }
    }

    /// Top-left chevron back to the email-entry stage. Native glass on
    /// iOS 26+ via `.glassEffect`; pre-26 falls back to a thin material
    /// circle so it still reads as a button.
    private var backButton: some View {
        Button {
            vm.backToEmailEntry()
            focusedField = .email
        } label: {
            Image(systemName: "chevron.left")
                .font(Theme.Fonts.glyph(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 38, height: 38)
                .glassCircle()
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(vm.isVerifying)
        .accessibilityLabel("返回")
    }

    private var humanButton: some View {
        Button {
            vm.tapHuman()
        } label: {
            choicePill(text: "人类", filled: vm.humanChoice == .human)
        }
        .buttonStyle(.plain)
    }

    private var robotButton: some View {
        Button {
            vm.tapRobot()
        } label: {
            choicePill(text: "机器人", filled: vm.humanChoice == .robot)
        }
        .buttonStyle(.plain)
    }

    private func choicePill(text: String, filled: Bool) -> some View {
        Text(text)
            .font(Theme.Fonts.system(size: 17, weight: .medium))
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

    /// Always-mounted Turnstile widget. Stays at 1pt height + opacity 0 for
    /// silent passes; only animates open if Cloudflare actually fires the
    /// `before-interactive-callback`.
    private var turnstileWidget: some View {
        let visible = vm.humanChoice == .human && !vm.codeBlockShown && vm.turnstileInteractive
        return TurnstileWebView(
            siteKey: HostedConfig.environment.turnstileSiteKey,
            host: HostedConfig.environment.turnstileHost,
            onToken: { token in vm.handleTurnstileToken(token) },
            onError: { msg in vm.handleTurnstileError(msg) },
            onInteractive: { vm.markTurnstileInteractive() }
        )
        .frame(maxWidth: .infinity)
        .frame(height: visible ? 80 : 1)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .id(vm.turnstileWidgetID)
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
            if vm.otpSent {
                codeRow
                    .transition(.opacity)
            }
        }
    }

    private var codeStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(Theme.Fonts.glyph(size: 13))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text("\(vm.otpSent ? "码已发至：" : "码将发至：")\(vm.email)")
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
            if vm.resendCooldown > 0 {
                Text("\(vm.resendCooldown)s")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.7))
            } else if !vm.otpSent {
                Button("发送") {
                    vm.tapSend()
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                .disabled(vm.isVerifying || vm.turnstileToken == nil)
            } else {
                Button("重发") {
                    Task { await vm.resend() }
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                .disabled(vm.isVerifying)
            }
        }
    }

    private var robotEasterEgg: some View {
        VStack(spacing: 22) {
            Text("😲😲😲")
                .font(Theme.Fonts.system(size: 56))
            VStack(spacing: 10) {
                Text("尊敬的机器人您好，请联系 hello@pendingname.com")
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
    /// widths and the logos line up naturally. The actual SIWA flow runs
    /// through the cross-platform `AppleSignIn` helper.
    private var appleButton: some View {
        Button { Task { await vm.beginApple() } } label: {
            brandPillContent(logo: appleLogoImage, text: "Apple", textColor: Theme.Palette.onApplePill)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(Theme.Palette.applePill))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }

    /// Google sign-in button. Same internal pill layout as `appleButton`,
    /// so the logos sit at matching X positions.
    private var googleButton: some View {
        Button { Task { await vm.beginGoogle() } } label: {
            brandPillContent(
                logo: AnyView(Image("GoogleG").resizable().scaledToFit()),
                text: "Google",
                textColor: Theme.Palette.googleInk
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
                    .foregroundStyle(Theme.Palette.onApplePill)
                    .scaledToFit()
            )
        } else {
            AnyView(
                Image(systemName: "applelogo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Palette.onApplePill)
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
                .font(Theme.Fonts.system(size: 19, weight: .medium))
                .foregroundStyle(textColor)
        }
    }

    // MARK: - Email row (stage: enteringEmail)

    private var emailRow: some View {
        inputRow {
            TextField("邮箱", text: $vm.email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.continue)
                .onSubmit { advance() }
        }
    }

    private var codeRow: some View {
        inputRow {
            TextField("码可能在垃圾邮件里", text: $vm.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
                .submitLabel(.go)
                .onSubmit { Task { await vm.verifyCode() } }
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
                .font(Theme.Fonts.system(size: 17))
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
            switch vm.stage {
            case .enteringEmail: advance()
            case .humanCheck:    Task { await vm.verifyCode() }
            }
        } label: {
            Group {
                if vm.isBusy {
                    ProgressView()
                        .tint(Theme.Palette.onAccent)
                } else {
                    Image(systemName: "arrow.right")
                        .font(Theme.Fonts.glyph(size: 15, weight: .bold))
                        .foregroundStyle(Theme.Palette.onAccent)
                }
            }
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(vm.canSubmit ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.28))
            )
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSubmit || vm.isBusy)
        .animation(.easeInOut(duration: 0.15), value: vm.canSubmit)
    }

    private func errorBlock(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Neutral-ink counterpart to `errorBlock` — used when a sign-in method
    /// simply has no coordinate in this build. Deliberately not red: this
    /// isn't a failure, it's what a public clone ships.
    private func noticeBlock(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Palette.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions bridging view focus → view model

    /// Advance email → human-check, dismissing the keyboard only if the
    /// address actually validated.
    private func advance() {
        if vm.advanceToHumanCheck() {
            focusedField = nil
        }
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
#endif
