import SwiftUI
import AuthenticationServices

/// First-launch / signed-out screen. Brand mark on top half, login methods
/// on the bottom half. Visual layout matches the pre-cutover design;
/// Google / email-code paths are placeholders until Supabase Auth is
/// configured for them.
struct WelcomeView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var isSigningIn = false
    @State private var errorText: String?

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

            // Bottom half: heading + Apple sign-in button.
            VStack(alignment: .leading, spacing: 0) {
                Text("登录 / 注册：")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.leading, 4)
                    .padding(.bottom, 22)

                appleButton
                    .disabled(isSigningIn)

                if let errorText {
                    errorBlock(text: errorText)
                        .padding(.top, 12)
                }

                if isSigningIn {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.top, 16)
                        Spacer()
                    }
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

    // MARK: - Apple button

    /// Custom-styled to match the prior UI's visual weight (full-width
    /// black capsule, "Apple" wordmark + glyph centered). The actual SIWA
    /// flow goes through ASAuthorizationController inside AppleSignIn.run().
    private var appleButton: some View {
        Button { Task { await beginSignIn() } } label: {
            HStack(spacing: 10) {
                appleLogoImage.frame(width: 19, height: 19)
                Text("Apple")
                    .font(.system(size: 19, weight: .medium))
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

    // MARK: - Action

    private func beginSignIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorText = nil
        defer { isSigningIn = false }
        do {
            _ = try await AppleSignIn.run()
            // AccountStore observes Supabase authStateChanges and flips
            // `current` automatically; RootView swaps to TabRoot.
        } catch AppleSignIn.Error.userCancelled {
            // Silent.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
