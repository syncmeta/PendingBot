import Foundation
import AuthenticationServices
import Supabase

/// Sign in with Google → Supabase session.
///
/// Implementation: Supabase OAuth flow via ASWebAuthenticationSession.
/// supabase-swift hands us the provider's auth URL (`launchFlow`'s
/// argument); we open it in the in-app browser, the user signs in on
/// Google's page, Google redirects back to `pendingbot://login-callback`
/// with an auth code, and supabase-swift exchanges that code for a
/// session and installs it.
///
/// Server-side prerequisite: Supabase project → Authentication →
/// Providers → Google must be enabled, with Web client ID + secret from
/// Google Cloud Console. Add the redirect URL to the project's allow
/// list: `pendingbot://login-callback`.
@MainActor
enum GoogleSignIn {
    enum Error: Swift.Error, LocalizedError {
        case userCancelled
        case underlying(Swift.Error)
        var errorDescription: String? {
            switch self {
            case .userCancelled: return "已取消"
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    private static let redirectURL = URL(string: "pendingbot://login-callback")!

    static func run() async throws -> Session {
        do {
            try await SupabaseStack.shared.auth.signInWithOAuth(
                provider: .google,
                redirectTo: redirectURL,
                launchFlow: { authURL in
                    try await launch(authURL)
                }
            )
            // signInWithOAuth installs the session into the auth client;
            // pull the freshly-set value to hand back to the caller.
            return try await SupabaseStack.shared.auth.session
        } catch let asError as ASWebAuthenticationSessionError where asError.code == .canceledLogin {
            throw Error.userCancelled
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Open the provider's auth URL in ASWebAuthenticationSession and
    /// return the callback URL once Google redirects back to us.
    private static func launch(_ authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Swift.Error>) in
            // Strip the `://login-callback` to get the bare scheme — that's
            // what ASWebAuthenticationSession matches on.
            let scheme = redirectURL.scheme ?? "pendingbot"
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let callbackURL {
                    cont.resume(returning: callbackURL)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(throwing: Error.underlying(URLError(.badServerResponse)))
                }
            }
            // Don't share cookies with Safari — keeps "switch account"
            // working without a system-level Google logout.
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = PresentationAnchor.shared
            session.start()
            // Holding `session` alive is the caller's job here — but
            // ASWebAuthenticationSession internally retains itself for
            // the duration of the flow.
        }
    }
}

@MainActor
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchor()

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                    return window
                }
            }
            return ASPresentationAnchor()
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
