import Foundation
import Combine
import Supabase

/// Mirrors the Supabase auth state into a published `current: Account?`.
///
/// supabase-swift handles JWT persistence + refresh on disk; we just observe
/// `auth.authStateChanges` and translate Sessions into our domain model.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var current: Account?
    /// Multi-account view models still expect a list — surface a single-element
    /// array (or empty) until the views are updated to read `current` directly.
    var accounts: [Account] { current.map { [$0] } ?? [] }
    /// nil = not yet checked, false = needs the random-name+avatar onboarding,
    /// true = profile is set up (display_name + avatar_seed in pendingbot.users).
    @Published var hasBootstrapped: Bool?
    /// Avatar seed pulled from pendingbot.users.custom_fields.avatar_seed —
    /// drives BotAvatar everywhere we render the user's own face.
    @Published var avatarSeed: String?
    /// Display name from pendingbot.users.display_name (canonical, set by
    /// the bootstrap step). Falls back to the auth-metadata name when the
    /// row hasn't been refreshed yet.
    @Published var profileDisplayName: String?

    private var stateTask: Task<Void, Never>?

    private init() {
        if let session = SupabaseStack.shared.auth.currentSession {
            current = Self.makeAccount(session: session)
            Task { await self.refreshProfileFlags() }
        }
        observeAuth()
    }

    private func observeAuth() {
        stateTask = Task { [weak self] in
            for await (_, session) in SupabaseStack.shared.auth.authStateChanges {
                await MainActor.run {
                    if let session {
                        self?.current = Self.makeAccount(session: session)
                        Task { await self?.refreshProfileFlags() }
                    } else {
                        self?.current = nil
                        self?.hasBootstrapped = nil
                        self?.avatarSeed = nil
                    }
                }
            }
        }
    }

    /// Pull the current user's `pendingbot.users` row to figure out whether
    /// they've finished the random-name+avatar onboarding. Called on launch
    /// (when a persisted session is found) and right after sign-in.
    func refreshProfileFlags() async {
        guard let userId = current?.id else { return }
        do {
            // Pull as raw JSON so we don't fight Codable over the variant
            // shape of the custom_fields jsonb (we write it as a string map
            // but other code paths could put nested values in there).
            let data = try await SupabaseStack.shared.database
                .from("users")
                .select("display_name, custom_fields")
                .eq("id", value: userId)
                .single()
                .execute()
                .data
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let cf = json["custom_fields"] as? [String: Any] ?? [:]
                self.hasBootstrapped = (cf["bootstrapped"] as? String) == "1"
                self.avatarSeed = cf["avatar_seed"] as? String
                if let dn = json["display_name"] as? String, !dn.isEmpty {
                    self.profileDisplayName = dn
                }
            } else {
                self.hasBootstrapped = false
            }
        } catch {
            // Most likely cause is the user row not existing yet — treat as
            // "needs bootstrap" so the onboarding view runs and creates it.
            self.hasBootstrapped = false
        }
    }

    /// Called by ProfileBootstrapView after a successful UPDATE so the
    /// RootView can flip from onboarding → TabRoot without a refetch.
    func markBootstrapped(displayName: String, avatarSeed: String) {
        self.hasBootstrapped = true
        self.avatarSeed = avatarSeed
        self.profileDisplayName = displayName
    }

    /// Sign out everywhere. Clears the Supabase session (which fires the
    /// authStateChanges listener and nils `current`) AND wipes the local
    /// SQLite cache so the next user doesn't see leftover conversations.
    func signOut() async {
        do {
            try await SupabaseStack.shared.auth.signOut()
        } catch {
            // signOut hits a best-effort token revoke + local clear; even if
            // the network half fails the local session is gone.
            print("[account] signOut error:", error)
        }
        LocalDatabase.shared.clear()
    }

    private static func makeAccount(session: Session) -> Account {
        let user = session.user
        let displayName = (user.userMetadata["name"]?.stringValue
            ?? user.userMetadata["full_name"]?.stringValue
            ?? user.email?.split(separator: "@").first.map(String.init)
            ?? "你")
        return Account(
            id: user.id.uuidString,
            displayName: displayName,
            email: user.email,
            jwt: session.accessToken,
            workerURL: HostedConfig.environment.workerURL
        )
    }
}

extension AnyJSON {
    /// Convenience peek at a string-typed AnyJSON value. Used by the few
    /// places we touch raw Realtime payload columns (ConversationView,
    /// AccountStore session metadata).
    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }
}
