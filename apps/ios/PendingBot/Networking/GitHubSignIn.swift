import Foundation
import AuthenticationServices
import Supabase
#if canImport(UIKit)
import UIKit
#endif

/// GitHub OAuth → Supabase session.
///
/// Unlike Apple/Google (OIDC, native id_token in-process), GitHub does not
/// hand out an OIDC id_token. We therefore go through the OAuth code-grant
/// hosted by Supabase: open `https://<project>.supabase.co/auth/v1/authorize?
/// provider=github&redirect_to=pendingbot://login-callback` in
/// ASWebAuthenticationSession, let Supabase round-trip to GitHub, and parse
/// the session out of the final redirect.
///
/// Setup checklist:
///   • GitHub → Settings → Developer settings → OAuth Apps → New.
///     Authorization callback URL = `https://<project-ref>.supabase.co/auth/v1/callback`.
///     Note Client ID + Client Secret.
///   • Supabase → Authentication → Providers → GitHub → On.
///     Paste Client ID + Client Secret.
///   • Supabase → Authentication → URL Configuration → Redirect URLs →
///     add `pendingbot://login-callback`.
///   • Info.plist already registers `pendingbot` under CFBundleURLTypes
///     (no extra scheme needed).
@MainActor
enum PendingGitHubSignIn {
    enum Error: Swift.Error, LocalizedError {
        case userCancelled
        case missingCallback
        case underlying(Swift.Error)
        var errorDescription: String? {
            switch self {
            case .userCancelled: return "已取消"
            case .missingCallback: return "GitHub 没返回回调 URL"
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    static let callbackURL = URL(string: "pendingbot://login-callback")!
    static let callbackScheme = "pendingbot"

    /// Run the GitHub OAuth flow and return the resulting Supabase session.
    static func run() async throws -> Session {
        do {
            return try await SupabaseStack.shared.auth.signInWithOAuth(
                provider: .github,
                redirectTo: callbackURL
            ) { url in
                try await launchWebSession(authURL: url)
            }
        } catch let err as Error {
            throw err
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Wrap `ASWebAuthenticationSession` in an async API. Translates
    /// the user-cancel signal into our typed `userCancelled` error so
    /// the caller can silence-back-off without surfacing a red banner,
    /// matching the Apple / Google flows.
    private static func launchWebSession(authURL: URL) async throws -> URL {
        let presenter = WebAuthAnchorProvider()
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callback, error in
                if let error {
                    let nsErr = error as NSError
                    if nsErr.domain == ASWebAuthenticationSessionErrorDomain,
                       nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: Error.userCancelled)
                    } else {
                        cont.resume(throwing: Error.underlying(error))
                    }
                    return
                }
                guard let callback else {
                    cont.resume(throwing: Error.missingCallback)
                    return
                }
                cont.resume(returning: callback)
            }
            session.presentationContextProvider = presenter
            // Tie the presenter's lifetime to the session so it survives
            // until the completion handler fires.
            objc_setAssociatedObject(
                session, &WebAuthAnchorProvider.holderKey,
                presenter, .OBJC_ASSOCIATION_RETAIN
            )
            session.start()
        }
    }
}

/// Supplies the key window as the presentation anchor for
/// ASWebAuthenticationSession. One instance per sign-in attempt.
@MainActor
private final class WebAuthAnchorProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    nonisolated(unsafe) static var holderKey: UInt8 = 0

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        // ASWebAuthenticationSession invokes this on main; assume isolation
        // for the UIKit lookup.
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
