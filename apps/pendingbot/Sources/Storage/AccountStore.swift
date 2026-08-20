import Foundation
import Combine
import Supabase
import OSLog

private let log = Logger.category("account")

/// Mirrors the Supabase auth state into a published `current: Account?`.
///
/// supabase-swift handles JWT persistence + refresh on disk; we just observe
/// `auth.authStateChanges` and translate Sessions into our domain model.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var current: Account?
    /// Flips to true the moment `bootstrap()` has consulted the persisted
    /// Supabase session. RootView gates on this to avoid a flash of
    /// WelcomeView for users who are already signed in: bootstrap runs in
    /// `.task` (after first frame), so without this gate the launch screen
    /// hands off to WelcomeView for one tick before TabRoot appears.
    @Published private(set) var sessionHydrated = false
    /// Multi-account view models still expect a list — surface a single-element
    /// array (or empty) until the views are updated to read `current` directly.
    var accounts: [Account] { current.map { [$0] } ?? [] }
    /// nil = not yet checked, false = needs the random-name+avatar onboarding,
    /// true = profile is set up (display_name + avatar_seed in pendingbot.users).
    @Published var hasBootstrapped: Bool?
    /// Avatar seed pulled from pendingbot.users.custom_fields.avatar_seed —
    /// drives BotAvatar everywhere we render the user's own face.
    @Published var avatarSeed: String?
    /// Optional uploaded avatar — when set, UserAvatar fetches the image
    /// from /v1/uploads/<id> and shows it instead of the BotAvatar glyph.
    @Published var avatarAttachmentId: String?
    /// Display name from pendingbot.users.display_name (canonical, set by
    /// the bootstrap step). Falls back to the auth-metadata name when the
    /// row hasn't been refreshed yet.
    @Published var profileDisplayName: String?
    /// One-shot flag that flips to true the moment we cancel a pending
    /// account-deletion tombstone on sign-in. RootView watches it to
    /// show "账号已恢复" once, then resets it. See refreshProfileFlags().
    @Published var accountRecovered: Bool = false

    private var stateTask: Task<Void, Never>?
    private var didBootstrap = false

    private init() {}

    /// Touch SupabaseStack and hydrate from any persisted session. Deferred
    /// out of `init` because the lazy SupabaseClient construction (auth +
    /// realtimeV2 + storage) is non-trivial on real-device debug builds and
    /// blocks SwiftUI's first frame if it runs at App.init time — leaving
    /// the launch screen visible while LLDB resolves symbols.
    /// Idempotent; PendingBotApp calls this from `.task`.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        // 秒进 + 后台刷新 —— 镜像主流 IM 的冷启动。
        //
        // 旧实现在启动路径上 `await auth.session`(会阻塞做一次 token 刷新),
        // access token 默认只活 1h,所以任何隔了 1h 以上的冷启动都会卡在
        // "加载中" 一个网络往返(EU 区从国内 RTT 更明显),刷新一旦真 hang
        // 连登录页都进不去。
        //
        // 现在改成:有持久化会话就先用本地缓存的(可能已过期的)会话立刻渲染
        // 已登录界面,不在首屏路径上等任何网络。token 刷新丢到后台 Task
        // (见 refreshSessionInBackground)。所有 /v1 调用取 token 都走
        // `auth.session`(按需自动刷新),所以即便此刻 access token 过期,
        // 首屏后的第一个请求也会自愈。
        if SupabaseStack.shared.auth.currentSession != nil {
            current = SupabaseStack.shared.auth.currentSession.map(Self.makeAccount)
            Task { await self.refreshProfileFlags() }
            Task { await self.refreshSessionInBackground() }
        }
        sessionHydrated = true
        observeAuth()
    }

    /// 后台刷新持久化会话的 token。三种结局:
    ///   - 成功 → 用新会话更新 `current`(authStateChanges 的 .tokenRefreshed
    ///     也会跟进,这里直接更一次免得多等一拍)。
    ///   - server 明确拒绝 refresh token(失效 / 被吊销 / 已用过,统一是
    ///     `AuthError`)→ 登录态确实没了,本地登出回退登录页。
    ///   - 纯网络 / 传输错误(`URLError` 等,非 `AuthError`)→ 不是登录态失效,
    ///     不把人踢出去:保留缓存会话留在 app 里,等 SDK autoRefresh / 下次
    ///     冷启动 / 下个请求继续重试。跟"正常使用中途断网"一致。
    private func refreshSessionInBackground() async {
        do {
            let session = try await SupabaseStack.shared.auth.session
            current = Self.makeAccount(session: session)
        } catch is AuthError {
            log.error("session refresh rejected by server — signing out locally")
            await signOutLocally()
        } catch {
            log.error("session refresh network error, keeping cached session: \(String(describing: error), privacy: .public)")
        }
    }

    /// 仅清本地会话 + 我们派生的 profile 状态,把 RootView 推回登录页。
    /// 用 `.local` scope:此时 refresh token 已被 server 判失效,没必要(也可能
    /// 失败/挂起)再走一次网络 revoke。
    private func signOutLocally() async {
        current = nil
        hasBootstrapped = nil
        avatarSeed = nil
        avatarAttachmentId = nil
        profileDisplayName = nil
        FamilyCredentialWriter.clear()
        try? await SupabaseStack.shared.auth.signOut(scope: .local)
    }

    private func observeAuth() {
        stateTask = Task { [weak self] in
            for await (event, session) in SupabaseStack.shared.auth.authStateChanges {
                await MainActor.run {
                    switch event {
                    case .signedOut:
                        // 真·登出(用户主动登出 / server 判会话失效)。
                        self?.current = nil
                        self?.hasBootstrapped = nil
                        self?.avatarSeed = nil
                    default:
                        // .initialSession / .signedIn / .tokenRefreshed 等。
                        // 只在拿到"没过期"的会话时才更新 current —— 一个有效的
                        // 新 JWT。过期的 .initialSession(冷启动用 emitLocalSession-
                        // AsInitialSession 立刻吐出来的本地旧会话)不清 current:
                        // 首屏已 optimistic 设好,是否真失效交给
                        // refreshSessionInBackground 判定,别在这里抢着踢人。
                        if let session, !Self.isExpired(session) {
                            self?.current = Self.makeAccount(session: session)
                            Task { await self?.refreshProfileFlags() }
                        }
                    }
                }
            }
        }
    }

    /// True if the session's expires_at is in the past (with 30s slack
    /// for clock skew). supabase-swift exposes `isExpired` only on
    /// newer versions; compute it ourselves so it works either way.
    private static func isExpired(_ session: Session) -> Bool {
        let expiresAt = session.expiresAt
        return Date(timeIntervalSince1970: expiresAt) < Date().addingTimeInterval(-30)
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
            let data = try await SupabaseStack.shared
                .from("users")
                .select("display_name, avatar_path, custom_fields, pending_deletion_at")
                .eq("id", value: userId)
                .single()
                .execute()
                .data
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let cf = json["custom_fields"] as? [String: Any] ?? [:]
                self.hasBootstrapped = (cf["bootstrapped"] as? String) == "1"
                self.avatarSeed = cf["avatar_seed"] as? String
                // avatar_path is the canonical column read by /v1/contacts.
                // 0062 backfilled and removed the legacy custom_fields key.
                self.avatarAttachmentId = (json["avatar_path"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                }
                if let dn = json["display_name"] as? String, !dn.isEmpty {
                    self.profileDisplayName = dn
                }
                // 家族 SSO：有有效会话且共享 keychain 组还没凭据时，向 worker 签发一张写进去
                // （PendingCrew 静默登录用）。带 profile 供确认卡离线展示。
                // iOS 和 macOS 都写；幂等 + best-effort，不阻塞 profile 刷新。
                Task { await FamilyCredentialWriter.syncIfNeeded(displayName: self.profileDisplayName, avatarSeed: self.avatarSeed) }
                // 28-day deletion cooldown: if there's a tombstone, signing
                // back in is the cancellation gesture. Clear it server-side
                // and surface a one-shot banner via accountRecovered.
                if json["pending_deletion_at"] is String {
                    await cancelPendingDeletion()
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

    /// Clears a pending-deletion tombstone via the cancel_account_deletion
    /// RPC and flags accountRecovered so RootView can show a one-shot
    /// "已恢复你的账号" alert. Failures are logged but not surfaced — if the
    /// RPC fails the tombstone stays put and tomorrow's cron sweep is the
    /// next chance for the user to log in and recover.
    private func cancelPendingDeletion() async {
        do {
            struct CancelResult: Decodable { let cleared: Bool }
            // 注销取消收进 worker(DELETE /v1/me/account-deletion);cleared =
            // 是否清掉了待删 tombstone,据此弹"已恢复账号"。(T2 #264)
            let res: CancelResult = try await APIClient().delete("v1/me/account-deletion")
            if res.cleared {
                self.accountRecovered = true
            }
        } catch {
            log.error("cancel_account_deletion failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Called by ProfileBootstrapView after a successful UPDATE so the
    /// RootView can flip from onboarding → TabRoot without a refetch.
    /// `attachmentId` is set when the user picked a custom photo —
    /// nil means stay on the deterministic BotAvatar.
    func markBootstrapped(displayName: String, avatarSeed: String,
                          attachmentId: String? = nil) {
        self.hasBootstrapped = true
        self.avatarSeed = avatarSeed
        self.profileDisplayName = displayName
        self.avatarAttachmentId = attachmentId?.isEmpty == false ? attachmentId : nil
    }

    /// Sign out everywhere. Clears the Supabase session (which fires the
    /// authStateChanges listener and nils `current`) AND hard-wipes the local
    /// SQLite cache — deleting the DB file and rotating its SQLCipher key — so
    /// the next user neither sees leftover conversations nor inherits a key
    /// that could decrypt a forensic copy of the prior user's data.
    ///
    /// - Parameter clearSharedLogin: When `true` (the default), the macOS
    ///   shared-keychain credential used by PendingCrew's family-SSO is also
    ///   removed. `LocalDataReset.performReset` passes `false` when the user
    ///   chooses to keep that credential intact.
    /// - Parameter scope: Supabase revoke scope. Defaults to `.global` (the
    ///   normal "sign out" semantics — revoke the user's sessions). The local
    ///   data reset passes `.local` so clearing data on THIS machine does not
    ///   sign the user out on their other devices.
    func signOut(clearSharedLogin: Bool = true, scope: SignOutScope = .global) async {
        do {
            try await SupabaseStack.shared.auth.signOut(scope: scope)
        } catch {
            // signOut hits a best-effort token revoke + local clear; even if
            // the network half fails the local session is gone.
            log.error("signOut error: \(String(describing: error), privacy: .public)")
        }
        wipeLocalDataCaches()
        // 主动登出也清掉共享组里的家族凭据 —— 凭据是账号级的，下个登录者
        // 不能继承上个账号的 PendingCrew 静默登录能力（iOS + macOS 均清）。
        if clearSharedLogin {
            FamilyCredentialWriter.clear()
        }
    }

    /// Account-scoped local cache wipe, shared by `signOut()` and the
    /// account-switch guard in PendingBotApp. Everything here is data the
    /// next account must not inherit: the SQLCipher conversation cache
    /// (file deleted + key rotated), the shared URLCache (cached HTTP
    /// bodies — mainly attachment images served by /v1/uploads/:id; this is
    /// the ProtectedURLCache-backed instance, so the flush covers its disk
    /// directory too), and the in-memory avatar cache.
    func wipeLocalDataCaches() {
        LocalDatabase.shared.wipeForSignOut()
        URLCache.shared.removeAllCachedResponses()
        #if os(iOS)
        // AvatarCache lives in Sources/Components/UserAvatar.swift, which
        // is whole-file gated behind #if os(iOS) (UIImage-based).
        AvatarCache.shared.clear()
        #endif
    }

    /// Called from PendingBotApp's account `onChange` when it detects an
    /// account SWITCH — old and new user ids both non-nil and different —
    /// that never passed through `signOut()` (a session replaced in place,
    /// e.g. a deep-link / magic-link login over an existing session). The
    /// local caches all belong to the previous account, so wipe them at
    /// the same level sign-out does. The shared family-SSO credential is
    /// cleared too: it's account-scoped, and `FamilyCredentialWriter
    /// .syncIfNeeded` only writes when the slot is EMPTY, so a stale
    /// credential would otherwise never be replaced. `refreshProfileFlags()`
    /// then re-issues the new account's credential (and re-derives profile
    /// state) — this also repairs the benign race where the new session's
    /// earlier sync wrote a fresh credential that this clear just removed.
    func handleAccountSwitch() {
        wipeLocalDataCaches()
        FamilyCredentialWriter.clear()
        Task { await refreshProfileFlags() }
    }

    private static func makeAccount(session: Session) -> Account {
        let user = session.user
        let displayName = (user.userMetadata["name"]?.stringValue
            ?? user.userMetadata["full_name"]?.stringValue
            ?? user.email?.split(separator: "@").first.map(String.init)
            ?? "你")
        return Account(
            // Lowercase to match Postgres canonical form. Swift's
            // `UUID.uuidString` is uppercase; DB-returned ids (Realtime
            // payloads, REST selects) are lowercase. Stamping the local id
            // uppercase made `sender_id == me` checks miss for our own
            // canonical rows — the user_bot bubble flipped to the bot side
            // the instant the Realtime row replaced the optimistic local-*.
            id: user.id.uuidString.lowercased(),
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
