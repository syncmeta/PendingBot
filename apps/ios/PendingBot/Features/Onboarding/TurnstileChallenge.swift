import SwiftUI
@preconcurrency import WebKit

/// Cloudflare Turnstile challenge presented as a modal sheet during the
/// email-OTP signup flow. Hosts a `WKWebView` that loads an inline HTML
/// page running Turnstile's JS widget; the widget calls back with a
/// short-lived token (~5min validity) which the caller forwards to
/// Supabase Auth via `signInWithOTP(captchaToken:)`.
///
/// Why an in-app WebView instead of a native SDK: Cloudflare doesn't
/// ship an official iOS SDK and the WebView path is what their docs
/// recommend for native apps. The Turnstile script enforces an origin
/// check, so the WebView's baseURL must match a hostname registered
/// for the site key (see `HostedConfig.Environment.turnstileHost`).
///
/// UX: managed mode runs invisibly when Cloudflare is confident, so
/// the sheet flashes briefly and dismisses on its own. When a real
/// challenge fires, the WebView grows to display the interactive
/// iframe and the user taps through it manually. Either path ends in
/// `onResult(.success(token))`.
struct TurnstileChallenge: View {
    let onResult: (Result<String, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .loading

    enum Status: Equatable {
        case loading
        case interactive
        case failed(String)
    }

    enum ChallengeError: Swift.Error, LocalizedError {
        case widgetError(String)
        case dismissed

        var errorDescription: String? {
            switch self {
            case .widgetError(let msg): return "人机验证失败：\(msg)"
            case .dismissed:            return "已取消人机验证"
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("人机验证")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("取消") {
                    onResult(.failure(ChallengeError.dismissed))
                    dismiss()
                }
                .font(.system(size: 15))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ZStack {
                TurnstileWebView(
                    siteKey: HostedConfig.environment.turnstileSiteKey,
                    host: HostedConfig.environment.turnstileHost,
                    onToken: { token in
                        onResult(.success(token))
                        dismiss()
                    },
                    onError: { msg in
                        status = .failed(msg)
                    },
                    onInteractive: {
                        status = .interactive
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if status == .loading {
                    ProgressView()
                        .controlSize(.large)
                }
                if case .failed(let msg) = status {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true)
    }
}

private struct TurnstileWebView: UIViewRepresentable {
    let siteKey: String
    let host: URL
    var onToken: (String) -> Void
    var onError: (String) -> Void
    var onInteractive: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError, onInteractive: onInteractive)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "turnstile")
        cfg.userContentController = userContent
        cfg.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.loadHTMLString(buildHTML(siteKey: siteKey), baseURL: host)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    private func buildHTML(siteKey: String) -> String {
        // The Turnstile JS API script must be requested with the
        // `?onload=...` query so it calls our bootstrap once the SDK
        // finishes loading. `async defer` keeps the page responsive.
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
                  appearance: 'always',
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
                let msg = dict["message"] as? String ?? "unknown"
                onError(msg)
            case "interactive":
                onInteractive()
            default:
                break
            }
        }
    }
}
