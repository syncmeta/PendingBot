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

    private var stateTask: Task<Void, Never>?

    private init() {
        // Hydrate synchronously from any persisted session before the first
        // view mounts; supabase-swift loads from its keychain store on init.
        if let session = SupabaseStack.shared.auth.currentSession {
            current = Self.makeAccount(session: session)
        }
        observeAuth()
    }

    private func observeAuth() {
        stateTask = Task { [weak self] in
            for await (_, session) in SupabaseStack.shared.auth.authStateChanges {
                await MainActor.run {
                    if let session {
                        self?.current = Self.makeAccount(session: session)
                    } else {
                        self?.current = nil
                    }
                }
            }
        }
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
