import Foundation

/// 浏览器走完 Apple 授权后，Supabase 把用户送回 app 的那个 `pendingbot://` URL —
/// 地址常量 + 纯解析。
///
/// 单独成文件、且只 import Foundation，是为了能被 `swiftc` 直接编译进
/// `Tests/AppleWebCallbackTests.swift` 跑断言（同 `ModelRevealPolicy` 的做法）。
/// 真正起浏览器、换会话的那半在 `AppleWebSignIn.swift`，那半没法单测。
///
/// 背景见 `docs/apple-web-oauth-research.md`。
enum AppleWebCallback {
    /// 已注册在 `Resources/Info.plist` 的 `CFBundleURLTypes` 里。
    /// `ASWebAuthenticationSession` 只按 scheme 匹配回调，不看后面的路径。
    static let scheme = "pendingbot"

    /// 回调路径。**这个值必须逐字加进 Supabase → Authentication →
    /// URL Configuration → Redirect URLs**，否则 Supabase 会拒绝回跳。
    /// 单独挑一个 host（而不是复用 app 已有的 deep link 形状）是为了让它
    /// 和 `bot.pendingname.com/b|g/<token>` 那两种邀请链接不可能撞上。
    static let host = "auth-callback"

    /// `pendingbot://auth-callback`
    static let url = URL(string: "\(scheme)://\(host)")!

    enum Outcome: Equatable {
        /// PKCE 的授权码，交给 supabase-swift 换会话。
        case authorizationCode(String)
        /// Apple / Supabase 明确回了一个错误。**必须报出来，不能当没看见** ——
        /// 后台配错时（Services ID 或 client secret 对不上）走的就是这一支。
        case providerError(code: String, description: String?)
        /// 不是我们的回调（别的 deep link，或者形状不认识）。
        case notACallback
    }

    /// 判断一个回跳 URL 到底是什么。纯函数，无副作用。
    ///
    /// 参数既可能挂在 query 上（PKCE 的 `?code=`、以及各种 `?error=`），也可能
    /// 挂在 fragment 上（implicit 流的 `#access_token=`）—— 两处都收，和
    /// supabase-swift 内部的 `extractParams` 口径一致。本 app 用的是默认的
    /// PKCE 流（`AuthClient.Configuration.defaultFlowType == .pkce`）。
    static func classify(_ url: URL) -> Outcome {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .notACallback
        }

        var params: [String: String] = [:]
        for source in [components.percentEncodedFragment, components.percentEncodedQuery] {
            guard let source, !source.isEmpty else { continue }
            for pair in source.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawName = parts.first, !rawName.isEmpty else { continue }
                let name = formDecode(String(rawName))
                let value = parts.count > 1 ? formDecode(String(parts[1])) : ""
                params[name] = value
            }
        }

        // 错误优先：错误回调里可能同时带着别的字段，先认错的那一支。
        if let code = nonEmpty(params["error"]) ?? nonEmpty(params["error_code"]) {
            return .providerError(code: code, description: nonEmpty(params["error_description"]))
        }
        if let code = nonEmpty(params["code"]) {
            return .authorizationCode(code)
        }
        return .notACallback
    }

    /// 把 provider 回的错误码翻成一句人话。
    ///
    /// 默认那句刻意**带上原始错误码**：这条链路在作者把 Apple 后台和 Supabase
    /// 配好之前根本走不通，配错时唯一的线索就是这个码，吞掉它等于让人瞎猜。
    static func humanMessage(errorCode: String, description: String?) -> String {
        switch errorCode {
        case "user_cancelled_authorize", "access_denied":
            return "已取消"
        case "invalid_client":
            // 最可能撞上的一种：Supabase 里的 Services ID 或 client secret
            // 和 Apple 后台对不上（含 secret 过期）。
            return "Apple 拒绝了这个应用标识（invalid_client）——" +
                   "多半是 Supabase 里的 Services ID 或 client secret 配得不对，或 secret 已过期。"
        case "invalid_request":
            return "Apple 认为这次登录请求不合法（invalid_request）——多半是回调地址没登记。"
        case "invalid_grant":
            return "这次授权已失效（invalid_grant），请重试一次。"
        case "server_error", "temporarily_unavailable":
            return "Apple 服务暂时不可用，请稍后重试。"
        default:
            if let description, !description.isEmpty {
                return "Apple 登录失败：\(description)（\(errorCode)）"
            }
            return "Apple 登录失败：\(errorCode)"
        }
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `application/x-www-form-urlencoded`：`+` 是空格，其余按百分号解码。
    private static func formDecode(_ raw: String) -> String {
        let plussesResolved = raw.replacingOccurrences(of: "+", with: " ")
        return plussesResolved.removingPercentEncoding ?? plussesResolved
    }
}
