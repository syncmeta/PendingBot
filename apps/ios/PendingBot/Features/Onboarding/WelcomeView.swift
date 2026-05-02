import SwiftUI
import UIKit
import AuthenticationServices

/// First-launch / signed-out screen. Brand mark on top; below it two
/// circular logo buttons (Apple / Google) side by side, then an email
/// capsule. Email path is a two-stage OTP: type address → tap arrow
/// to send → row swaps to a 6-digit code input → tap arrow to verify.
///
/// All auth runs through supabase-swift via the `AppleSignIn` /
/// `PendingGoogleSignIn` / `EmailSignIn` helpers. AccountStore picks up
/// the resulting Session via authStateChanges; RootView swaps to
/// TabRoot automatically.
struct WelcomeView: View {
    enum Stage { case enteringEmail, codeSent }
    enum Field { case email, code }

    @EnvironmentObject private var store: AccountStore
    @State private var stage: Stage = .enteringEmail
    @State private var email: String = ""
    @State private var code: String = ""
    @State private var busy: Bool = false
    @State private var errorText: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 14, y: 4)
                    .padding(.bottom, 14)

                Text("登录 / 注册")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.bottom, 20)

                methods.padding(.bottom, 12)

                if let errorText {
                    errorBlock(text: errorText)
                        .padding(.top, 4)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    // MARK: - Sections

    @ViewBuilder
    private var methods: some View {
        VStack(spacing: 18) {
            if stage == .enteringEmail {
                HStack(spacing: 28) {
                    appleCircleButton
                    googleCircleButton
                }
                .frame(maxWidth: .infinity)
                .disabled(busy)
                .padding(.bottom, 4)

                emailRow
            } else {
                emailEchoRow
                codeRow
            }
        }
    }

    private var appleCircleButton: some View {
        Button { Task { await beginApple() } } label: {
            ZStack {
                Circle().fill(Color.black)
                appleLogoImage
            }
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }

    @ViewBuilder
    private var appleLogoImage: some View {
        if UIImage(named: "AppleSignInLogo") != nil {
            Image("AppleSignInLogo")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.white)
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "applelogo")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .offset(y: -1)
        }
    }

    private var googleCircleButton: some View {
        Button { Task { await beginGoogle() } } label: {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                googleGlyph
            }
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Google")
    }

    @ViewBuilder
    private var googleGlyph: some View {
        if UIImage(named: "GoogleG") != nil {
            Image("GoogleG")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            // Fallback when GoogleG.imageset hasn't been added to the
            // asset catalogue yet — gradient "G" approximates the brand
            // marks well enough at glyph size.
            Text("G")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: 0x4285F4),
                             Color(hex: 0xEA4335),
                             Color(hex: 0xFBBC05),
                             Color(hex: 0x34A853)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
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
                .padding(.leading, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await primaryAction() } } label: {
                Group {
                    if busy {
                        ProgressView().tint(Theme.Palette.accent)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                canSubmit ? Theme.Palette.accent
                                : Theme.Palette.inkMuted.opacity(0.4)
                            )
                    }
                }
                .frame(width: 44, height: 44)
                .padding(.trailing, 4)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || busy)
        }
        .frame(height: 52)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
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
            .font(Theme.Fonts.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
    }

    // MARK: - State

    private var canSubmit: Bool {
        switch stage {
        case .enteringEmail:
            let s = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.contains("@") && s.contains(".")
        case .codeSent:
            return code.trimmingCharacters(in: .whitespaces).count >= 4
        }
    }

    // MARK: - Actions

    /// The arrow button drives both stages — sends the code on the
    /// email stage, verifies it on the code stage.
    private func primaryAction() async {
        guard canSubmit, !busy else { return }
        switch stage {
        case .enteringEmail: await sendCode()
        case .codeSent: await verify()
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
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
    }

    private func verify() async {
        busy = true; errorText = nil
        defer { busy = false }
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
}
