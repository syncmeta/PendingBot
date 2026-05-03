import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit

/// First-launch / signed-out screen. Logo on top, three sign-in methods below
/// (Apple, Google, email-code). Email path uses an inline TextField with a
/// trailing arrow button — tapping the arrow sends the verification code,
/// after which the same row is replaced by the code-entry input.
///
/// The visual layout is the byte-for-byte port of commit c0e7980 (the
/// build that shipped to TestFlight). Auth wiring goes through the
/// supabase-swift helpers AppleSignIn / PendingGoogleSignIn / EmailSignIn.
struct WelcomeView: View {
    enum Stage {
        case enteringEmail
        case codeSent
        case verifying
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore

    @State private var stage: Stage = .enteringEmail
    @State private var email: String = ""
    @State private var code: String = ""
    /// Random nonce mixed into the SIWA request. Apple bakes its SHA-256
    /// hash into the identity token; Supabase verifies replay-protection.
    /// Generated once per appearance — must not change mid-flow.
    @State private var siwaNonce: String = WelcomeView.randomNonce()
    @State private var errorText: String?
    @State private var appleCoordinator: AppleSignInCoordinator?
    @FocusState private var focusedField: Field?

    enum Field { case email, code }

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

            // Bottom half: small "登录 / 注册：" heading + three equal-width
            // capsule buttons (or the code-entry step when applicable).
            VStack(alignment: .leading, spacing: 0) {
                if !inEmailCodeStep {
                    Text("登录 / 注册：")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.leading, 4)
                        .padding(.bottom, 22)
                }

                methods

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
        .onAppear {
            // Don't grab focus for the email field — let users tap it
            // explicitly so the keyboard doesn't fly up on launch. The code
            // step still autofocuses (set when sendCode succeeds).
            if stage == .codeSent { focusedField = .code }
        }
    }

    // MARK: - Sections

    private var inEmailCodeStep: Bool {
        stage == .codeSent || stage == .verifying
    }

    @ViewBuilder
    private var methods: some View {
        if inEmailCodeStep {
            VStack(spacing: 14) {
                emailEchoRow
                codeRow
            }
        } else {
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

    private var emailRow: some View {
        inputRow {
            TextField("邮箱", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.continue)
                .onSubmit { Task { await primaryAction() } }
        }
    }

    private var codeRow: some View {
        inputRow {
            TextField("6 位验证码", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
                .submitLabel(.go)
                .onSubmit { Task { await primaryAction() } }
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
        Button { Task { await primaryAction() } } label: {
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

    private var emailEchoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text(email)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("换个") {
                stage = .enteringEmail
                code = ""
                errorText = nil
                focusedField = .email
            }
            .buttonStyle(.plain)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Palette.accent.opacity(0.85))
        }
        .padding(.horizontal, 4)
    }

    private func errorBlock(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived state

    private var isBusy: Bool { stage == .verifying }

    private var canSubmit: Bool {
        switch stage {
        case .enteringEmail: return email.contains("@") && email.contains(".")
        case .codeSent:      return code.count >= 4
        case .verifying:     return false
        }
    }

    // MARK: - Email-code flow

    @MainActor
    private func primaryAction() async {
        errorText = nil
        switch stage {
        case .enteringEmail: await sendCode()
        case .codeSent: await verifyCode()
        case .verifying: break
        }
    }

    @MainActor
    private func sendCode() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        do {
            try await EmailSignIn.requestCode(email: trimmed)
            stage = .codeSent
            focusedField = .code
            Haptics.tap()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    @MainActor
    private func verifyCode() async {
        stage = .verifying
        do {
            _ = try await EmailSignIn.verify(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                code: code.trimmingCharacters(in: .whitespaces)
            )
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
            stage = .codeSent
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
        controller.performRequests()
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
            stage = .verifying
            do {
                _ = try await SupabaseStack.shared.auth.signInWithIdToken(
                    credentials: .init(provider: .apple,
                                       idToken: idToken,
                                       nonce: siwaNonce)
                )
                Haptics.success()
            } catch {
                errorText = error.localizedDescription
                stage = .enteringEmail
                Haptics.error()
            }
        }
    }

    // MARK: - Google

    @MainActor
    private func beginGoogle() async {
        errorText = nil
        stage = .verifying
        do {
            _ = try await PendingGoogleSignIn.run()
            Haptics.success()
        } catch PendingGoogleSignIn.Error.userCancelled {
            stage = .enteringEmail
        } catch {
            errorText = error.localizedDescription
            stage = .enteringEmail
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
}
