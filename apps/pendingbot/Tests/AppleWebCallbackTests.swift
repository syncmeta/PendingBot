// AppleWebCallback 的单测 —— Mac 端 Apple 网页登录回跳 URL 的解析与错误分支。
//
// 本分支还没有 iOS 单测 target（feat/ios-unit-tests 未合 main），而
// AppleWebCallback.swift 刻意只 import Foundation，所以可以直接用 swiftc
// 把它和本文件编到一起跑：
//
//     apps/pendingbot/Tests/run-apple-web-callback-tests.sh
//
// 真正的 target 落地后把这些用例平移过去、删掉脚本 —— 断言 1:1 对得上 XCTest。
//
// ⚠️ 这里验的是**回调解析**，不是端到端登录。整条链路能不能真的登上，
// 必须等作者把 Apple 后台的 Services ID 和 Supabase 的 Apple provider 配好，
// 见 docs/apple-web-oauth-research.md 第 5 节。

import Foundation

// ── 简易 harness（同 ModelRevealPolicyTests）────────────────────────────
var failures = 0
var checks = 0

func expect(
    _ actual: AppleWebCallback.Outcome,
    _ expected: AppleWebCallback.Outcome,
    _ what: String,
    line: Int = #line
) {
    checks += 1
    if actual != expected {
        failures += 1
        print("✘ \(what) (line \(line))")
        print("    expected \(expected)")
        print("    actual   \(actual)")
    }
}

func expectTrue(_ cond: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !cond {
        failures += 1
        print("✘ \(what) (line \(line))")
    }
}

func classify(_ raw: String) -> AppleWebCallback.Outcome {
    guard let url = URL(string: raw) else {
        failures += 1
        print("✘ 测试用例本身的 URL 就构不出来: \(raw)")
        return .notACallback
    }
    return AppleWebCallback.classify(url)
}

@main
struct AppleWebCallbackTests {
    static func main() {
    // ── 回调地址常量 ────────────────────────────────────────────────────────
    // 这三条钉的是「代码里的地址」和「要填进 Supabase Redirect URLs 的地址」是同一个。
    // scheme 必须和 Resources/Info.plist 的 CFBundleURLSchemes 一致。

    expectTrue(AppleWebCallback.scheme == "pendingbot", "scheme 必须是 Info.plist 里注册的 pendingbot")
    expectTrue(AppleWebCallback.host == "auth-callback", "host 必须是 auth-callback")
    expectTrue(
        AppleWebCallback.url.absoluteString == "pendingbot://auth-callback",
        "完整回调地址必须是 pendingbot://auth-callback（这一串要逐字填进 Supabase 的 Redirect URLs）"
    )

    // ── 成功路径：PKCE 授权码挂在 query 上 ──────────────────────────────────

    expect(
        classify("pendingbot://auth-callback?code=abc123"),
        .authorizationCode("abc123"),
        "带 ?code= 的回调应解析出授权码"
    )
    expect(
        classify("pendingbot://auth-callback?code=abc123&state=xyz"),
        .authorizationCode("abc123"),
        "回调里带别的参数不影响取 code"
    )
    expect(
        classify("PENDINGBOT://AUTH-CALLBACK?code=abc123"),
        .authorizationCode("abc123"),
        "scheme / host 大小写不敏感（URL 规范如此，系统回跳时大小写不保证）"
    )
    expect(
        classify("pendingbot://auth-callback#code=frag123"),
        .authorizationCode("frag123"),
        "挂在 fragment 上的参数也要收（与 supabase-swift 的 extractParams 口径一致）"
    )
    expect(
        classify("pendingbot://auth-callback?code=a%2Fb%2Bc"),
        .authorizationCode("a/b+c"),
        "百分号编码要解开：%2F→/、%2B→+"
    )
    expect(
        classify("pendingbot://auth-callback?code=a+b"),
        .authorizationCode("a b"),
        "form-urlencoded 里裸的 + 是空格，不是加号"
    )

    // ── 错误路径：后台配错时唯一的线索，绝不能吞 ────────────────────────────

    expect(
        classify("pendingbot://auth-callback?error=invalid_client"),
        .providerError(code: "invalid_client", description: nil),
        "只有 error= 时也要认出是错误"
    )
    expect(
        classify("pendingbot://auth-callback?error=invalid_client&error_description=Bad%20client"),
        .providerError(code: "invalid_client", description: "Bad client"),
        "error + error_description 都要带出来"
    )
    expect(
        classify("pendingbot://auth-callback?error_code=422&error_description=oops"),
        .providerError(code: "422", description: "oops"),
        "Supabase 有时只回 error_code，也要认"
    )
    expect(
        classify("pendingbot://auth-callback?error=access_denied&code=leftover"),
        .providerError(code: "access_denied", description: nil),
        "错误和 code 同时出现时，错误优先 —— 不能拿着半截 code 往下走"
    )
    expect(
        classify("pendingbot://auth-callback#error=server_error&error_description=Try+later"),
        .providerError(code: "server_error", description: "Try later"),
        "错误挂在 fragment 上同样要认"
    )

    // ── 不是我们的回调 ──────────────────────────────────────────────────────

    expect(classify("pendingbot://auth-callback"), .notACallback, "空回调既无 code 也无 error → 不认")
    expect(classify("pendingbot://auth-callback?code="), .notACallback, "code 为空串等于没有")
    expect(classify("pendingbot://auth-callback?error="), .notACallback, "error 为空串等于没有")
    expect(
        classify("pendingbot://other-thing?code=abc"),
        .notACallback,
        "同 scheme 但不同 host 的 deep link 不能被当成登录回调吞掉"
    )
    expect(
        classify("https://bot.pendingname.com/b/token123?code=abc"),
        .notACallback,
        "邀请链接（universal link）不是登录回调"
    )

    // ── 错误码 → 人话 ───────────────────────────────────────────────────────
    // 关键一条：默认分支必须把**原始错误码**带出来。这条链路在后台配好之前跑不通，
    // 配错时错误码是唯一线索，吞掉它等于让人瞎猜。

    expectTrue(
        AppleWebCallback.humanMessage(errorCode: "access_denied", description: nil) == "已取消",
        "用户拒绝授权应显示「已取消」，不该是一句吓人的报错"
    )
    expectTrue(
        AppleWebCallback.humanMessage(errorCode: "invalid_client", description: nil)
            .contains("invalid_client"),
        "invalid_client 的提示要点出配置问题并保留原始码"
    )
    expectTrue(
        AppleWebCallback.humanMessage(errorCode: "some_new_code", description: nil)
            .contains("some_new_code"),
        "没见过的错误码必须原样带出来（默认分支不许吞码）"
    )
    expectTrue(
        AppleWebCallback.humanMessage(errorCode: "some_new_code", description: "详细原因")
            .contains("详细原因"),
        "有 description 时要一并显示"
    )

    // ── 收尾 ────────────────────────────────────────────────────────────────
    if failures == 0 {
        print("✓ \(checks)/\(checks) 条断言通过")
        exit(0)
    } else {
        print("✘ \(checks - failures)/\(checks) 条断言通过")
        exit(1)
    }
    }
}
