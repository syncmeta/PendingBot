import Foundation
import UIKit
import GoogleSignIn
import Supabase

/// Native Google Sign-In → Supabase session.
///
/// We use the GoogleSignIn-iOS SDK (in-process, no Safari handoff) to
/// run Google's sign-in sheet and get an ID token. That JWT is handed
/// to supabase-swift's `signInWithIdToken(.google, ...)` — same shape
/// as the Apple flow.
///
/// Setup checklist:
///   • Google Cloud Console: create OAuth 2.0 Client ID, type = iOS,
///     bundle ID = com.pendingname.pendingbot. Note the iOS Client ID
///     and the Reversed Client ID.
///   • Info.plist: register the Reversed Client ID as a URL scheme
///     (e.g. `com.googleusercontent.apps.<digits>-<token>`) under
///     CFBundleURLTypes. Also set GIDClientID = the iOS Client ID
///     (alternatively pass it programmatically — see configure()).
///   • Supabase dashboard: Authentication → Providers → Google → On.
///     Web Client ID + Secret can stay empty if you're native-only;
///     paste the iOS Client ID into "Authorized Client IDs" so
///     Supabase will accept ID tokens whose `aud` claim is that ID.
@MainActor
enum PendingGoogleSignIn {
    enum Error: Swift.Error, LocalizedError {
        case missingIdToken
        case userCancelled
        case missingClientID
        case underlying(Swift.Error)
        var errorDescription: String? {
            switch self {
            case .missingIdToken: return "Google 没返回 idToken"
            case .userCancelled: return "已取消"
            case .missingClientID: return "Info.plist 缺 GIDClientID 或 GoogleSignIn 未配置"
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// Run the native Google sign-in sheet and exchange the resulting
    /// ID token for a Supabase session.
    static func run() async throws -> Session {
        configureIfNeeded()
        guard let presenter = topViewController() else {
            throw Error.underlying(URLError(.badServerResponse))
        }

        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter
            )
        } catch let err as NSError where err.code == GIDSignInError.canceled.rawValue {
            throw Error.userCancelled
        } catch {
            throw Error.underlying(error)
        }

        guard let idToken = result.user.idToken?.tokenString else {
            throw Error.missingIdToken
        }
        do {
            return try await SupabaseStack.shared.auth.signInWithIdToken(
                credentials: .init(provider: .google, idToken: idToken)
            )
        } catch {
            throw Error.underlying(error)
        }
    }

    /// Read GIDClientID from Info.plist on first call. Idempotent —
    /// the SDK caches the configuration internally.
    private static func configureIfNeeded() {
        if GIDSignIn.sharedInstance.configuration != nil { return }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty else {
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                var top = key
                while let presented = top.presentedViewController { top = presented }
                return top
            }
        }
        return nil
    }
}
