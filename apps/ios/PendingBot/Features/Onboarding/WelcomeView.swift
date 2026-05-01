import SwiftUI
import AuthenticationServices

/// Single-button sign-in screen. Sign in with Apple → Supabase session
/// (handled by AppleSignIn.run). AccountStore's authStateChanges observer
/// flips `current` automatically; the view doesn't navigate itself.
struct WelcomeView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var isSigningIn = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                    Text(HostedConfig.displayName)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }

                Text("用 Apple ID 登录\n你的对话与画像跨设备同步")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Spacer()

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // The native ASAuthorizationAppleIDButton handles its own nonce;
                // we intercept the tap and run our own flow so we can drive
                // AppleSignIn.run() with the SHA-256 nonce supabase requires.
                SignInWithAppleButton(.signIn,
                                      onRequest: { _ in },
                                      onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 52)
                    .padding(.horizontal, 24)
                    .opacity(isSigningIn ? 0.4 : 1.0)
                    .allowsHitTesting(!isSigningIn)
                    .overlay(
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { Task { await beginSignIn() } }
                    )

                if isSigningIn {
                    ProgressView().padding(.top, 4)
                }

                Spacer().frame(height: 24)
            }
            .padding(.bottom, 12)
        }
    }

    private func beginSignIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorText = nil
        defer { isSigningIn = false }
        do {
            _ = try await AppleSignIn.run()
            // AccountStore updates itself via Supabase authStateChanges.
        } catch AppleSignIn.Error.userCancelled {
            // Silent — user backed out.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
