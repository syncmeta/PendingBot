import Foundation
import OSLog

/// Stops a PostgREST **write** from leaving the device carrying nothing but
/// the anon / publishable key.
///
/// ## Why this exists as a mechanism and not a convention
///
/// `supabase-swift`'s `SupabaseClient.adapt(request:)` resolves the auth
/// session with `try?`. When it can't (keychain miss, refresh failure, signed
/// out) the request keeps the default `Authorization: Bearer <publishableKey>`
/// header and **goes out anyway, as anon**. The server then answers with an
/// RLS `permission denied for table X`, and that is where the trail goes cold:
/// the error names a table and a database, and says nothing about the phone
/// that never had a token. We have misdiagnosed this exact shape twice, both
/// times as a backend/DB bug, because the report arrives one full network
/// round-trip away from the cause.
///
/// `SupabaseStack.authedClient()` fixes it at the call site, but a call-site
/// convention is only as good as the next person's memory. This is the same
/// rule enforced at the last possible moment — the request is failed **before
/// any bytes leave**, and the error names the real cause.
///
/// ## How it hooks in
///
/// A `URLProtocol` registered on the Supabase client's own `URLSession`
/// (`SupabaseClientOptions.GlobalOptions.session`). `canInit(with:)` returns
/// `true` **only** for requests that are already violations, so every other
/// request takes the normal networking path untouched — this protocol never
/// proxies, never re-issues, never buffers a body. It exists to say no.
///
/// ## What counts as a violation
///
/// `POST` / `PATCH` / `PUT` / `DELETE` to `/rest/v1/<table>` whose
/// `Authorization` header is still the publishable key.
///
/// Deliberately **not** covered:
///   - `/rest/v1/rpc/…` — a POST there may be a read (`list_bot_invitees` is
///     one today), and we can't tell read RPCs from write RPCs at the HTTP
///     layer. Tripping on those would break working signed-out reads. Logged
///     in `docs/tech-debt.md`.
///   - `/auth/v1/…`, `/storage/v1/…` — anon there is legitimate (that's how
///     you sign in) or already fails visibly.
///   - reads (`GET`) — anon reads come back as empty results, which reads as
///     "no data", not as a corrupted backend.
final class SupabaseAnonWriteGuard: URLProtocol {
    private static let log = Logger.category("supabase-guard")

    static let errorDomain = "PendingBot.SupabaseAnonWriteGuard"
    static let errorCode = 1

    // Written once while `SupabaseStack.shared` is being constructed, then
    // read from URLSession's worker threads. Lock rather than
    // `nonisolated(unsafe)` because the read side is genuinely concurrent.
    private static let lock = NSLock()
    private static var _publishableKey = ""

    /// Called by `SupabaseStack` before the client is built.
    static func arm(publishableKey: String) {
        lock.lock()
        _publishableKey = publishableKey
        lock.unlock()
    }

    private static var publishableKey: String {
        lock.lock()
        defer { lock.unlock() }
        return _publishableKey
    }

    // MARK: - Detection

    private static let writeMethods: Set<String> = ["POST", "PATCH", "PUT", "DELETE"]

    /// Exposed for tests; pure function of the request.
    static func isAnonWrite(_ request: URLRequest) -> Bool {
        let key = publishableKey
        guard !key.isEmpty else { return false }
        guard let method = request.httpMethod?.uppercased(),
              writeMethods.contains(method) else { return false }
        guard let path = request.url?.path,
              let range = path.range(of: "/rest/v1/") else { return false }
        // `/rest/v1/rpc/...` — read-vs-write is not decidable here.
        guard !path[range.upperBound...].hasPrefix("rpc/") else { return false }
        return request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)"
    }

    private static func violationMessage(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "?"
        let path = request.url?.path ?? "?"
        return """
            supabase-swift 要把一个登录后才能做的写请求以 anon 身份发出去：\
            \(method) \(path)。这不是后端问题 —— 是这台设备上的会话没解析出来\
            （钥匙串取不到 / 刷新失败 / 已登出），supabase-swift 的 adapt() 用 \
            try? 吞掉了它，于是退回 publishable key。请求已在发出前拦下。\
            写路径必须走 SupabaseStack.authedClient()，不要直接用 \
            SupabaseStack.shared。
            """
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        isAnonWrite(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let message = Self.violationMessage(request)
        // Debug: stop the developer here, at the cause, with the call stack
        // still holding the offending call site. This is the whole point —
        // the alternative is reading it off a database error tomorrow.
        assertionFailure(message)
        Self.log.fault("\(message, privacy: .public)")
        client?.urlProtocol(
            self,
            didFailWithError: NSError(
                domain: Self.errorDomain,
                code: Self.errorCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "登录态不可用，请重新登录后再试",
                    NSDebugDescriptionErrorKey: message,
                ]
            )
        )
    }

    override func stopLoading() {}
}
