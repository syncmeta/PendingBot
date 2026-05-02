import SwiftUI
import UIKit
import AuthenticationServices

/// First-launch / signed-out screen — the layout from commit `e03d827`:
/// brand mark on top half, then "登录 / 注册：" heading, then a row with
/// Apple (left) + Google (right) capsule pills, and an email capsule
/// directly below. Email path is two-stage OTP — type address → arrow
/// to send → row swaps to a 6-digit code input → arrow to verify.
///
/// Auth wired through supabase-swift via the AppleSignIn /
/// PendingGoogleSignIn / EmailSignIn helpers.
struct WelcomeView: View {
    enum Stage { case enteringEmail, codeSent, verifying }
    enum Field { case email, code }

    @EnvironmentObject private var store: AccountStore
    @State private var stage: Stage = .enteringEmail
    @State private var email: String = ""
    @State private var code: String = ""
    @State private var siwaNonce: String = randomNonce()
    @State private var busy: Bool = false
    @State private var errorText: String?
    @FocusState private var focusedField: Field?

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

            // Bottom half: "登录 / 注册：" heading + Apple|Google row + email
            VStack(alignment: .leading, spacing: 0) {
                if !inCodeStep {
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
    }

    // MARK: - Sections

    private var inCodeStep: Bool {
        stage == .codeSent || stage == .verifying
    }

    @ViewBuilder
    private var methods: some View {
        if inCodeStep {
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
            .disabled(busy)
        }
    }

    /// Custom-styled Apple pill (not the system SignInWithAppleButton)
    /// because we want the single word "Apple" so it pairs visually with
    /// the Google pill — both labels then have similar widths and the
    /// logos line up. The actual SIWA flow still goes through Apple's
    /// own ASAuthorizationController via the AppleSignIn helper.
    private var appleButton: some View {
        Button { Task { await beginApple() } } label: {
            brandPillContent(logo: appleLogoImage, text: "Apple", textColor: .white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(.black))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }

    private var googleButton: some View {
        Button { Task { await beginGoogle() } } label: {
            brandPillContent(
                logo: googleLogoImage,
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

    private var appleLogoImage: AnyView {
        if UIImage(named: "AppleSignInLogo") != nil {
            return AnyView(
                Image("AppleSignInLogo")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .scaledToFit()
            )
        }
        return AnyView(
            Image(systemName: "applelogo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
        )
    }

    /// Multi-color "G" rendered as a Text fallback when the official
    /// Google brand asset hasn't been dropped into the catalogue yet
    /// (drop a 60×60 PNG at Assets.xcassets/GoogleG.imageset/ to swap).
    private var googleLogoImage: AnyView {
        if UIImage(named: "GoogleG") != nil {
            return AnyView(Image("GoogleG").resizable().scaledToFit())
        }
        return AnyView(
            Text("G")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: 0x4285F4),
                             Color(hex: 0xEA4335),
                             Color(hex: 0xFBBC05),
                             Color(hex: 0x34A853)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
    }

    /// Shared inner layout for both brand pills: 19pt logo + 10pt gap +
    /// brand word, centred. Same structure on both pills means the
    /// logos sit at the same X coordinate.
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
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(canSubmit ? Theme.Palette.accent
                                        : Theme.Palette.accent.opacity(0.28))
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

    private var isBusy: Bool { busy || stage == .verifying }
    private var canSubmit: Bool {
        switch stage {
        case .enteringEmail:
            let s = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.contains("@") && s.contains(".")
        case .codeSent: return code.trimmingCharacters(in: .whitespaces).count >= 4
        case .verifying: return false
        }
    }

    // MARK: - Actions

    private func primaryAction() async {
        guard canSubmit, !busy else { return }
        switch stage {
        case .enteringEmail: await sendCode()
        case .codeSent: await verify()
        case .verifying: break
        }
    }

    private func beginApple() async {
        guard !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            _ = try await AppleSignIn.run()
        } catch AppleSignIn.Error.userCancelled {
            // Silent.
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func beginGoogle() async {
        guard !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            _ = try await PendingGoogleSignIn.run()
        } catch PendingGoogleSignIn.Error.userCancelled {
            // Silent.
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func sendCode() async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try await EmailSignIn.requestCode(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            stage = .codeSent
            focusedField = .code
            Haptics.tap()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    private func verify() async {
        stage = .verifying; errorText = nil
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
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        self
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

private func randomNonce(length: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
    return String(bytes.map { charset[Int($0) % charset.count] })
}
