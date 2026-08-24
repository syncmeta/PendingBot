import Foundation
import AuthenticationServices
import Supabase
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 「用 Apple 登录」的**网页 OAuth** 路径：起一个 `ASWebAuthenticationSession`
/// 让用户在浏览器里授权，Apple → Supabase → 回跳 `pendingbot://auth-callback`，
/// 再用回调里的授权码换一个 Supabase 会话。
///
/// **为什么要有这条，明明已经有 `AppleSignIn.swift`**：Apple 不给「直接分发」
/// （Developer ID，非 Mac App Store）的 macOS 应用签发
/// `com.apple.developer.applesignin`，所以原生的 `ASAuthorizationController`
/// 在我们自己发的 `.dmg` 里根本用不了（见 `MacWelcomeView.appleSignInAvailable`
/// 的长注释和 `docs/tech-debt.md`）。网页 OAuth 不依赖那项授权。
///
/// 代码是跨平台的（`Sources/Networking/` 两端都编），但**只打算在 Mac 上用**：
/// iOS 有原生流程，体验更好，不该退回浏览器。
///
/// ⚠️ **入口目前是关着的** —— 没有任何界面调到这里。`docs/apple-web-oauth-research.md`
/// 第 5 节那次实测（同一个 Apple 账号在 iPhone 和 Mac 上是不是同一行 `auth.users`）
/// 通过之前，不许放出按钮：配错时不会报错，只会悄悄多出一个账号。
///
/// 详见 `docs/apple-web-oauth-research.md`。
@MainActor
enum AppleWebSignIn {
    enum Error: Swift.Error, LocalizedError {
        /// 用户自己关掉了授权窗口。
        case userCancelled
        /// Apple / Supabase 明确回了错误码（后台配错走这一支）。
        case provider(code: String, description: String?)
        /// 回调 URL 里既没有授权码也没有错误码 —— 形状不认识。
        case unrecognizedCallback(URL)
        /// `ASWebAuthenticationSession.start()` 直接回了 false —— 浏览器根本没被起来。
        /// 这个返回值以前是被丢掉的，失败会表现成「点了没反应」。
        case browserDidNotOpen
        /// **会话没有真正落盘**。见 `run()` 里那段注释，这是本文件最要紧的一条。
        case sessionNotPersisted(underlying: Swift.Error)
        case underlying(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "已取消"
            case .provider(let code, let description):
                return AppleWebCallback.humanMessage(errorCode: code, description: description)
            case .unrecognizedCallback:
                return "Apple 登录回跳的地址无法识别，请重试一次。"
            case .browserDidNotOpen:
                return "没能打开浏览器完成登录。请完全退出 Safari（⌘Q）后重试，或改用邮箱验证码登录。"
            case .sessionNotPersisted:
                return "登录成功了，但会话没能保存下来，请重试一次。"
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    /// 走完整条链路，返回建立好的会话。
    static func run() async throws -> Session {
        let session: Session
        do {
            session = try await SupabaseStack.shared.auth.signInWithOAuth(
                provider: .apple,
                redirectTo: AppleWebCallback.url
                // 刻意**不传 scopes**：Supabase 服务端的 Apple provider 已经把
                // scope 固定成 `email` + `name`，并配套设了 Apple 在带 scope 时
                // 要求的 `response_mode=form_post`（supabase/auth 的
                // internal/api/provider/apple.go）。从客户端再传一遍只会覆盖掉
                // 那份已经配对好的组合。
                //
                // 拿到 email 不只是为了好看：Supabase 的账号归并在 `sub` 对不上时
                // 会退回按**已验证邮箱**找老用户（研究文档第 3 节），没有 email
                // 就没有这层兜底。
            ) { @MainActor url in
                try await presentAuthorization(url)
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.underlying(error)
        }

        // ── fail loud：会话必须真的落盘 ────────────────────────────────────
        //
        // supabase-swift 的 `SessionStorage.store` 把写失败**吞掉了**，只打一行
        // 日志（Sources/Auth/Internal/SessionStorage.swift）。所以 Keychain 写不
        // 进去（典型是签名不对导致的 -34018）时，上面这个 `session` 照样正常返回，
        // 而下一次任何需要登录态的写请求会**静默降级成 anon 发出**，最终以一句
        // 「permission denied for table …」冒出来 —— 这个坑在本项目已经被误诊成
        // 后端 / DB 故障不止一次（见 `docs/tech-debt.md` 与 `SupabaseStack` 里
        // 那段写门注释）。
        //
        // `authedClient()` 会重新走一遍 `auth.session`，而它读的是**存储**
        // （`sessionStorage.get()`），不是内存里那份，所以写失败时这里会抛
        // `AuthError.sessionMissing`。宁可在这里当场报错，也不要让用户带着一个
        // 看起来登录了、实际什么都写不了的状态走下去。
        do {
            _ = try await SupabaseStack.authedClient()
        } catch {
            throw Error.sessionNotPersisted(underlying: error)
        }

        return session
    }

    // MARK: - ASWebAuthenticationSession

    /// 起浏览器授权窗口，返回 Apple/Supabase 回跳过来的 URL。
    ///
    /// 自己实现这一段（而不是用 supabase-swift 那个自带 `configure:` 的重载）
    /// 有两个理由：
    ///   1. 它默认的 presentation anchor 是一个**空的 `ASPresentationAnchor()`**，
    ///      在 macOS 上等于凭空造一个窗口来挂 sheet；这里沿用
    ///      `AppleSignIn.swift` 已有的 key-window 查找。
    ///   2. 能在把回调交给 supabase 之前先看一眼 —— provider 回的错误码是后台
    ///      配错时**唯一**的线索，必须原样带出来。
    private static func presentAuthorization(_ authorizationURL: URL) async throws -> URL {
        let anchorProvider = PresentationAnchorProvider()
        // 强引用住会话本体直到回调结束。`ASWebAuthenticationSession` 不由系统替我们
        // 持有 —— 只是个局部变量的话，`start()` 之后它可能当场被释放、会话被取消，
        // 症状恰恰就是「浏览器起来了但什么都不发生」。Google 那条路没这个问题，是
        // 因为 AppAuth 拿实例变量存着（OIDExternalUserAgentMac 的
        // `_webAuthenticationSession`）；我们这条一开始漏了。
        var retainedSession: ASWebAuthenticationSession?
        return try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: AppleWebCallback.scheme
            ) { callbackURL, error in
                defer {
                    // 把 anchorProvider 拉活到回调结束：ASWebAuthenticationSession
                    // 对 presentationContextProvider 只持弱引用。
                    _ = anchorProvider
                    retainedSession = nil
                }

                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: Error.userCancelled)
                    } else {
                        continuation.resume(throwing: Error.underlying(error))
                    }
                    return
                }
                guard let callbackURL else {
                    // 文档保证 url / error 至少有一个，但不拿 fatalError 赌
                    // ——这条链路在真机上还一次都没跑过。
                    continuation.resume(throwing: Error.unrecognizedCallback(authorizationURL))
                    return
                }

                switch AppleWebCallback.classify(callbackURL) {
                case .providerError(let code, let description):
                    continuation.resume(throwing: Error.provider(code: code, description: description))
                case .notACallback:
                    continuation.resume(throwing: Error.unrecognizedCallback(callbackURL))
                case .authorizationCode:
                    // 授权码本身交给 supabase-swift 的 `session(from:)` 去换，
                    // 它同时负责 PKCE 的 code_verifier。
                    continuation.resume(returning: callbackURL)
                }
            }
            webSession.presentationContextProvider = anchorProvider
            retainedSession = webSession
            // `start()` 的返回值必须看 —— 它回 false（拿不到 anchor、浏览器起不来）
            // 时不会走 completionHandler，丢掉它等于把失败咽了，界面就永远停在
            // 「验证中」。
            guard webSession.start() else {
                retainedSession = nil
                continuation.resume(throwing: Error.browserDidNotOpen)
                return
            }
        }
    }
}

/// key window 查找 —— 与 `AppleSignIn.swift` 里那份同源。
@MainActor
private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // 系统保证在主线程回调，所以这里断言 MainActor 隔离是安全的。
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                    return window
                }
            }
            return ASPresentationAnchor()
            #elseif canImport(AppKit)
            return NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}
