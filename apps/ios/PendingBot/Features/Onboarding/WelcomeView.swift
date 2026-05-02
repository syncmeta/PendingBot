import SwiftUI
import AuthenticationServices

/// First-launch / signed-out screen. Logo on top, three sign-in methods
/// below (Apple, Google, email-code). All three are equal-width capsule
/// buttons stacked vertically; the email row's TextField swaps to a
/// 6-digit code input after the first submit.
///
/// Auth backed by supabase-swift via the AppleSignIn / PendingGoogleSignIn /
/// EmailSignIn helpers — AccountStore picks up the resulting Session via
/// authStateChanges and RootView swaps to TabRoot.
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
            VStack(spacing: 14) {
                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 16, y: 5)
                Text("登录 / 注册")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom half: three equal-width capsule buttons (or code step).
            VStack(spacing: 14) {
                methods
                if let errorText {
                    errorBlock(text: errorText)
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

    @ViewBuilder
    private var methods: some View {
        if stage == .codeSent || stage == .verifying {
            VStack(spacing: 14) {
                emailEchoRow
                codeRow
            }
        } else {
            VStack(spacing: 14) {
                appleButton
                googleButton
                emailRow
            }
            .disabled(isBusy)
        }
    }

    /// Native SwiftUI `SignInWithAppleButton` clipped to a capsule. Apple's
    /// HIG explicitly allows the corner radius to match surrounding
    /// buttons, so a fully-rounded pill is fine.
    private var appleButton: some View {
        SignInWithAppleButton(.continue,
            onRequest: { req in
                req.requestedScopes = [.email, .fullName]
                req.nonce = sha256Hex(siwaNonce)
            },
            onCompletion: { result in Task { await handleAppleResult(result) } }
        )
        .signInWithAppleButtonStyle(.black)
        .frame(height: 52)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var googleButton: some View {
        Button { Task { await beginGoogle() } } label: {
            HStack(spacing: 10) {
                googleGlyph
                Text("用 Google 继续")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(red: 0.18, green: 0.18, blue: 0.20))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .glassCapsule()
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用 Google 继续")
    }

    @ViewBuilder
    private var googleGlyph: some View {
        if UIImage(named: "GoogleG") != nil {
            Image("GoogleG")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
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
        case .codeSent:
            return code.trimmingCharacters(in: .whitespaces).count >= 4
        case .verifying:
            return false
        }
    }

    // MARK: - Apple

    /// SignInWithAppleButton's onCompletion is sync. Hand the credential
    /// to the same code path AppleSignIn helper would: pull the identity
    /// token, exchange via signInWithIdToken with our nonce.
    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        guard !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        switch result {
        case .failure(let err):
            if let asErr = err as? ASAuthorizationError, asErr.code == .canceled {
                return
            }
            errorText = err.localizedDescription
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorText = "Apple 没有返回 identity token"
                return
            }
            do {
                _ = try await SupabaseStack.shared.auth.signInWithIdToken(
                    credentials: .init(provider: .apple,
                                       idToken: idToken,
                                       nonce: siwaNonce)
                )
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Google + Email

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

    private func primaryAction() async {
        guard canSubmit, !busy else { return }
        switch stage {
        case .enteringEmail: await sendCode()
        case .codeSent: await verify()
        case .verifying: break
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
        stage = .verifying
        errorText = nil
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
    /// iOS 26 liquid-glass capsule fallback: ultraThinMaterial + hairline.
    @ViewBuilder
    func glassCapsule() -> some View {
        self
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// SHA-256 hex of an arbitrary string. Used for the SIWA nonce.
private func sha256Hex(_ input: String) -> String {
    let bytes = Array(input.utf8)
    var hash = [UInt8](repeating: 0, count: 32)
    sha256ComputeWelcome(bytes, into: &hash)
    return hash.map { String(format: "%02x", $0) }.joined()
}

private func randomNonce(length: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
    return String(bytes.map { charset[Int($0) % charset.count] })
}

// FIPS-180-4 SHA-256, inlined to avoid pulling CommonCrypto headers into
// this file (the AppleSignIn helper has its own copy with a different
// name; both internal-only).
private func sha256ComputeWelcome(_ message: [UInt8], into out: inout [UInt8]) {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var padded = message
    let bitLen = UInt64(message.count) * 8
    padded.append(0x80)
    while padded.count % 64 != 56 { padded.append(0) }
    for i in (0..<8).reversed() { padded.append(UInt8((bitLen >> UInt64(i * 8)) & 0xff)) }
    var w = [UInt32](repeating: 0, count: 64)
    for chunk in stride(from: 0, to: padded.count, by: 64) {
        for i in 0..<16 {
            let b0 = UInt32(padded[chunk + i*4 + 0]) << 24
            let b1 = UInt32(padded[chunk + i*4 + 1]) << 16
            let b2 = UInt32(padded[chunk + i*4 + 2]) << 8
            let b3 = UInt32(padded[chunk + i*4 + 3])
            w[i] = b0 | b1 | b2 | b3
        }
        for i in 16..<64 {
            let s0 = (w[i-15] >> 7 | w[i-15] << 25) ^ (w[i-15] >> 18 | w[i-15] << 14) ^ (w[i-15] >> 3)
            let s1 = (w[i-2] >> 17 | w[i-2] << 15) ^ (w[i-2] >> 19 | w[i-2] << 13) ^ (w[i-2] >> 10)
            w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let S1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
            let mj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ mj
            hh = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
    for i in 0..<8 {
        out[i*4 + 0] = UInt8((h[i] >> 24) & 0xff)
        out[i*4 + 1] = UInt8((h[i] >> 16) & 0xff)
        out[i*4 + 2] = UInt8((h[i] >> 8) & 0xff)
        out[i*4 + 3] = UInt8(h[i] & 0xff)
    }
}
