#if os(macOS)
import SwiftUI
@preconcurrency import WebKit

/// macOS 登录 gate + Email-OTP 登录页。
///
/// PendingBot Mac 端此前没有任何登录入口（`MacRootView` 直接显示），导致没有
/// supabase 会话、所有 `/v1/*` 调用 401。这一刀给 macOS 补上 iOS 同款的会话 gate
/// + 一个最小可用的 Email-OTP 登录界面，让 Mac 端真正能登录（进而 Crew viewer
/// 能拉到数据）。
///
/// 为什么只做 Email OTP：`EmailSignIn` 本就是跨平台纯 async/await，而
/// Apple/Google 登录都依赖 iOS-only 的 presentation anchor / SDK。Email 一条路
/// 最省事且全平台可信。Turnstile 人机验证沿用 iOS 的 WKWebView 方案，这里包成
/// macOS 的 `NSViewRepresentable`（WebKit 本身跨平台）。
struct MacRootGate: View {
    @EnvironmentObject private var store: AccountStore

    var body: some View {
        Group {
            if !store.sessionHydrated {
                // 冷启动 hydrate 持久化 session 期间的占位，避免闪 "未登录"。
                VStack(spacing: 10) {
                    ProgressView()
                    Text("加载中…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.current == nil {
                MacWelcomeView()
            } else {
                MacRootView()
            }
        }
    }
}

struct MacWelcomeView: View {
    private enum Stage { case email, code }

    @State private var stage: Stage = .email
    @State private var email = ""
    @State private var code = ""
    /// Turnstile token（~5min、单次使用）。`requestCode` 成功后作废，返回重发会
    /// bump `turnstileId` 重建 widget 取新 token。
    @State private var captchaToken: String?
    @State private var turnstileInteractive = false
    @State private var turnstileId = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                Text("登录 PendingBot").font(.title2.weight(.semibold))
                Text("用邮箱验证码登录").font(.callout).foregroundStyle(.secondary)
            }

            if stage == .email {
                emailStage
            } else {
                codeStage
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - stages

    private var emailStage: some View {
        VStack(spacing: 12) {
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if canSend { Task { await send() } } }

            // Turnstile widget — 后台预加载;interaction-only 多数静默通过（0 高度），
            // 只有需要交互时撑开。token 到了 send 按钮才可用。
            MacTurnstileWebView(
                siteKey: HostedConfig.environment.turnstileSiteKey,
                host: HostedConfig.environment.turnstileHost,
                onToken: { token in captchaToken = token; error = nil },
                onError: { msg in error = "人机验证失败：\(msg)" },
                onInteractive: { turnstileInteractive = true }
            )
            .id(turnstileId)
            .frame(width: 300, height: turnstileInteractive ? 72 : 0)
            .clipped()

            if captchaToken == nil && error == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在验证你不是机器人…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await send() }
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Text("发送验证码").frame(width: 200) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSend)
        }
    }

    private var codeStage: some View {
        VStack(spacing: 12) {
            Text("验证码已发到 \(email)").font(.callout).foregroundStyle(.secondary)
            TextField("6 位验证码", text: $code)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .multilineTextAlignment(.center)
                .onSubmit { if canVerify { Task { await verify() } } }

            Button {
                Task { await verify() }
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Text("登录").frame(width: 200) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canVerify)

            Button("换个邮箱") {
                stage = .email
                code = ""
                error = nil
                captchaToken = nil
                turnstileInteractive = false
                turnstileId += 1 // 重建 widget 取新 token
            }
            .buttonStyle(.link)
            .disabled(busy)
        }
    }

    private var canSend: Bool {
        !busy && captchaToken != nil && email.contains("@")
    }
    private var canVerify: Bool {
        !busy && code.trimmingCharacters(in: .whitespaces).count >= 6
    }

    // MARK: - actions

    private func send() async {
        guard let token = captchaToken else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await EmailSignIn.requestCode(email: trimmedEmail, captchaToken: token)
            stage = .code
        } catch {
            self.error = error.localizedDescription
            // token 可能已被消费/作废 — 重建 widget 以便重试。
            captchaToken = nil
            turnstileInteractive = false
            turnstileId += 1
        }
    }

    private func verify() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            // 成功后 supabase authStateChanges 触发，AccountStore.current 更新，
            // MacRootGate 自动切到 MacRootView。
            _ = try await EmailSignIn.verify(email: trimmedEmail, code: code.trimmingCharacters(in: .whitespaces))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// macOS WKWebView host for the Cloudflare Turnstile widget — the `NSViewRepresentable`
/// twin of iOS's `TurnstileWebView`. Same HTML/JS bridge (`window.webkit.messageHandlers`
/// works identically in macOS WKWebView); only the representable wrapper differs.
struct MacTurnstileWebView: NSViewRepresentable {
    let siteKey: String
    let host: URL
    var onToken: (String) -> Void
    var onError: (String) -> Void
    var onInteractive: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError, onInteractive: onInteractive)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "turnstile")
        cfg.userContentController = userContent
        cfg.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.setValue(false, forKey: "drawsBackground") // 透明背景（macOS WKWebView）
        view.loadHTMLString(buildHTML(siteKey: siteKey), baseURL: host)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    private func buildHTML(siteKey: String) -> String {
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onloadTurnstileCallback" async defer></script>
          <style>
            html, body { margin: 0; padding: 0; background: transparent; }
            body { display: flex; align-items: center; justify-content: center; min-height: 100vh; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            #ts { display: flex; align-items: center; justify-content: center; }
          </style>
        </head>
        <body>
          <div id="ts"></div>
          <script>
            function send(type, payload) {
              try {
                window.webkit.messageHandlers.turnstile.postMessage(Object.assign({type: type}, payload || {}));
              } catch (_) {}
            }
            window.onloadTurnstileCallback = function() {
              try {
                turnstile.render('#ts', {
                  sitekey: '\(siteKey)',
                  appearance: 'interaction-only',
                  callback: function(token) { send('token', {token: token}); },
                  'error-callback': function(err) { send('error', {message: String(err)}); },
                  'expired-callback': function() { send('error', {message: 'expired'}); },
                  'timeout-callback': function() { send('error', {message: 'timeout'}); },
                  'before-interactive-callback': function() { send('interactive', {}); }
                });
              } catch (e) {
                send('error', {message: 'render: ' + (e && e.message || e)});
              }
            };
            setTimeout(function() {
              if (typeof turnstile === 'undefined') {
                send('error', {message: 'script failed to load'});
              }
            }, 10000);
          </script>
        </body>
        </html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onToken: (String) -> Void
        let onError: (String) -> Void
        let onInteractive: () -> Void
        private var settled = false

        init(onToken: @escaping (String) -> Void,
             onError: @escaping (String) -> Void,
             onInteractive: @escaping () -> Void) {
            self.onToken = onToken
            self.onError = onError
            self.onInteractive = onInteractive
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            let type = dict["type"] as? String ?? ""
            switch type {
            case "token":
                guard !settled, let token = dict["token"] as? String else { return }
                settled = true
                onToken(token)
            case "error":
                guard !settled else { return }
                onError(dict["message"] as? String ?? "unknown")
            case "interactive":
                onInteractive()
            default:
                break
            }
        }
    }
}
#endif
