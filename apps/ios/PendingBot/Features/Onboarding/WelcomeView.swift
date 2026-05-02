import SwiftUI
import AuthenticationServices

/// First-launch / signed-out screen. Brand mark on top half, three
/// login methods (Apple / Google / Email) on the bottom half. Each
/// hands off to its own helper in Networking/*.
struct WelcomeView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var isSigningIn = false
    @State private var errorText: String?
    @State private var showingEmail = false

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

            // Bottom half: heading + three sign-in methods.
            VStack(alignment: .leading, spacing: 12) {
                Text("登录 / 注册：")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.leading, 4)
                    .padding(.bottom, 10)

                appleButton.disabled(isSigningIn)
                googleButton.disabled(isSigningIn)
                emailButton.disabled(isSigningIn)

                if let errorText {
                    errorBlock(text: errorText)
                        .padding(.top, 4)
                }

                if isSigningIn {
                    HStack {
                        Spacer()
                        ProgressView().padding(.top, 12)
                        Spacer()
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .sheet(isPresented: $showingEmail) {
            EmailSignInSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Buttons

    private var appleButton: some View {
        Button { Task { await beginAppleSignIn() } } label: {
            HStack(spacing: 10) {
                appleLogoImage.frame(width: 18, height: 18)
                Text("继续使用 Apple")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(.black))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }

    private var googleButton: some View {
        Button { Task { await beginGoogleSignIn() } } label: {
            HStack(spacing: 10) {
                googleLogo.frame(width: 18, height: 18)
                Text("继续使用 Google")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(Color.white))
            .overlay(
                Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Google")
    }

    private var emailButton: some View {
        Button {
            showingEmail = true
            Haptics.tap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                Text("用邮箱登录")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(Theme.Palette.surface))
            .overlay(
                Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with email")
    }

    // MARK: - Logos

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

    /// Multi-color "G" rendered with concentric arcs so we don't ship
    /// a Google brand asset (PNG would land us in their attribution
    /// rules). Approximation is good enough at button glyph size.
    private var googleLogo: AnyView {
        if UIImage(named: "GoogleSignInLogo") != nil {
            return AnyView(
                Image("GoogleSignInLogo")
                    .resizable()
                    .scaledToFit()
            )
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
                .frame(width: 18, height: 18)
        )
    }

    // MARK: - Error block

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

    // MARK: - Actions

    private func beginAppleSignIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true; errorText = nil
        defer { isSigningIn = false }
        do {
            _ = try await AppleSignIn.run()
        } catch AppleSignIn.Error.userCancelled {
            // Silent.
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func beginGoogleSignIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true; errorText = nil
        defer { isSigningIn = false }
        do {
            _ = try await GoogleSignIn.run()
        } catch GoogleSignIn.Error.userCancelled {
            // Silent.
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Email sheet

/// Two-step email OTP: request code → enter code → session.
private struct EmailSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var stage: Stage = .email
    @State private var sending = false
    @State private var verifying = false
    @State private var error: String?

    enum Stage { case email, code }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch stage {
                        case .email: emailStage
                        case .code: codeStage
                        }
                        if let error {
                            Text(error)
                                .font(Theme.Fonts.footnote)
                                .foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                }
            }
            .navigationTitle("用邮箱登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var emailStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我们会发一封验证码邮件给你。")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
            TextField("you@example.com", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled(true)
                .font(.system(size: 17, weight: .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
        }
        Button {
            Task { await sendCode() }
        } label: {
            HStack {
                if sending { ProgressView().tint(.white) }
                Text(sending ? "发送中" : "发送验证码")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(Capsule().fill(canSend ? Theme.Palette.accent
                : Theme.Palette.accent.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    @ViewBuilder
    private var codeStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("验证码已发到 \(email)")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
            TextField("6 位验证码", text: $code)
                .textInputAutocapitalization(.never)
                .keyboardType(.numberPad)
                .autocorrectionDisabled(true)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
        }
        HStack(spacing: 10) {
            Button {
                stage = .email; code = ""; error = nil
            } label: {
                Text("改个邮箱")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Capsule().fill(Theme.Palette.accentBg))
            }
            .buttonStyle(.plain)
            Button {
                Task { await verify() }
            } label: {
                HStack {
                    if verifying { ProgressView().tint(.white) }
                    Text(verifying ? "验证中" : "登录")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Capsule().fill(canVerify ? Theme.Palette.accent
                    : Theme.Palette.accent.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(!canVerify)
        }
    }

    private var canSend: Bool {
        !sending && email.contains("@") && email.contains(".")
    }
    private var canVerify: Bool {
        !verifying && code.trimmingCharacters(in: .whitespaces).count >= 4
    }

    private func sendCode() async {
        guard canSend else { return }
        sending = true; error = nil
        defer { sending = false }
        do {
            try await EmailSignIn.requestCode(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            stage = .code
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func verify() async {
        guard canVerify else { return }
        verifying = true; error = nil
        defer { verifying = false }
        do {
            _ = try await EmailSignIn.verify(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                code: code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // AccountStore picks up the session via authStateChanges and
            // RootView swaps; closing the sheet is purely cosmetic.
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
