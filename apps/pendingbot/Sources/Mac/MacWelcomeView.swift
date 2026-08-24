#if os(macOS)
import SwiftUI
import AppKit
@preconcurrency import WebKit

/// macOS 登录 gate + 登录页。
///
/// PendingBot Mac 端此前没有任何登录入口(`MacRootView` 直接显示),导致没有
/// supabase 会话、所有 `/v1/*` 调用 401。这一刀给 macOS 补上 iOS 同款的会话 gate
/// + 登录界面。
///
/// **与 iOS 对齐(#253):** 界面逐块原生重画镜像 iOS `WelcomeView` —— 同样的
/// BrandMark logo 上半屏、「登录 / 注册：」+ Apple/Google 双 pill + 邮箱箭头行,
/// 第二步「你是？」人机验证(Turnstile)+ 验证码 + 机器人彩蛋,全套走共享的
/// `Theme` 设计 token。逻辑 100% 复用跨平台 `WelcomeViewModel`(与 iOS 同一个),
/// 仅渲染层用 AppKit 原生控件 + `MacTurnstileWebView`(NSViewRepresentable)。
/// 三种登录都通——Apple 走原生 `ASAuthorizationController`(NSWindow anchor),
/// Google 走 GoogleSignIn-iOS 的 macOS target(`signIn(withPresenting: NSWindow)`),
/// 邮箱 OTP 走 `EmailSignIn`。
struct MacRootGate: View {
    @EnvironmentObject private var store: AccountStore

    var body: some View {
        Group {
            if !store.sessionHydrated {
                // 冷启动 hydrate 持久化 session 期间的占位,避免闪 "未登录"。
                // 用登录页同款紧凑尺寸,免得 hydrate→登录 时窗口跳大小。
                VStack(spacing: 10) {
                    ProgressView()
                    Text("加载中…")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                .frame(minWidth: 770, minHeight: 420)
                .background(MacWindowGrowAnchorRecorder())
            } else if store.current == nil {
                MacWelcomeView()
            } else if store.hasBootstrapped == false {
                // 跟 iOS `RootView` 同一档:登录后若 profile 还没设过(随机名 +
                // 随机头像 onboarding 没走完),先走这一屏。Mac 端原先漏了这步,
                // 新用户登录直接落进主壳、永远没机会取名 —— 这正是「新用户没有
                // 选名字的页面」的根因。`hasBootstrapped` 仍是 nil(刷新在途)
                // 时按「已设」处理直接进主壳,避免给老用户闪一下 onboarding。
                // ProfileBootstrapView 已跨平台(iOS/macOS 共用)。
                ProfileBootstrapView()
                    .environmentObject(store)
                    .frame(minWidth: 770, minHeight: 560)
            } else {
                // 登录后才声明主 app 尺寸 → 窗口从登录小窗长到紧凑的 IM 主窗。
                // A8:登录后渲染跨平台三列 shell WideRootView(已取代旧的
                // Mac 专属 MacRootView,后者连同消息/好友 Mac 平行列已删)。
                WideRootView()
                    .frame(minWidth: 920, minHeight: 620)
            }
        }
    }
}

/// 把「登录前」窗口的中心 + 尺寸(hydrate 占位 / 登录页)带给
/// `MacMainWindowStyler`:登录后窗口从小窗长到主尺寸时,用它把中心搬回原处,
/// 让窗口「以中心为锚」展开,而不是钉住左上角往右下方蹿。
@MainActor
enum MacWindowGrowAnchor {
    static var center: NSPoint?
    static var preSize: NSSize?
}

/// 贴在登录前内容背后,持续把当前窗口中心/尺寸记到 `MacWindowGrowAnchor`。
/// 登录后该视图随登录页一起被移除,自然停止记录;主窗 styler 再消费并清空。
private struct MacWindowGrowAnchorRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in
            if let w = v?.window { context.coordinator.record(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let w = nsView?.window { context.coordinator.record(w) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        func record(_ window: NSWindow) {
            MacWindowGrowAnchor.center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            MacWindowGrowAnchor.preSize = window.frame.size
        }
    }
}

struct MacWelcomeView: View {
    @StateObject private var vm = WelcomeViewModel()
    @FocusState private var focusedField: Field?
    @State private var showingQRLogin = false

    enum Field { case email, code }

    private let resendTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // Logo + form sit as one centered cluster (not pushed to opposite
        // edges), on a compact window — smaller than the main app window
        // restored once signed in via MacRootGate.
        HStack(spacing: 96) {
            // 左侧是个固定 140 宽的槽(=二维码宽):logo 居中、二维码填满,两者共享
            // 同一中心。切换 logo↔二维码不改变整簇宽度,所以右侧表单纹丝不动。
            Group {
                if showingQRLogin {
                    PendingBotMacQRLoginView()
                        .transition(.opacity)
                } else {
                    Image("BrandMark")
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 18, y: 5)
                }
            }
            .frame(width: 140)

            VStack(alignment: .leading, spacing: 0) {
                if vm.stage == .humanCheck {
                    backButton
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }

                switch vm.stage {
                case .enteringEmail:
                    enteringEmailBody
                case .humanCheck:
                    humanCheckBody
                        .transition(.opacity)
                }

                if let noticeText = vm.noticeText {
                    noticeBlock(text: noticeText)
                        .padding(.top, 12)
                }
                if let errorText = vm.errorText {
                    errorBlock(text: errorText)
                        .padding(.top, 12)
                }
            }
            .frame(width: 310)
        }
        .padding(44)
        // 默认尺寸:窗口整体放大,内容簇保持原大小、居中,四周留更多空白。
        // 内容簇加宽到 310(容下 Apple/Google/扫码 三件同排),窗口宽同步 +30。
        .frame(minWidth: 770, minHeight: 420, alignment: .center)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .background(MacLoginWindowStyler())
        .background(MacWindowGrowAnchorRecorder())
        .onChange(of: vm.otpSent) { _, sent in
            if sent { focusedField = .code }
        }
        .onReceive(resendTimer) { _ in
            vm.tickResendCooldown()
        }
        .animation(.easeInOut(duration: 0.28), value: vm.stage)
        .animation(.easeInOut(duration: 0.28), value: vm.humanChoice)
        .animation(.easeInOut(duration: 0.28), value: vm.otpSent)
        .animation(.easeInOut(duration: 0.28), value: vm.codeBlockShown)
        .animation(.easeInOut(duration: 0.28), value: vm.turnstileInteractive)
        .animation(.easeInOut(duration: 0.28), value: showingQRLogin)
    }

    // MARK: - Stage: entering email

    @ViewBuilder
    private var enteringEmailBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("登录 / 注册：")
                .font(Theme.Fonts.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.leading, 4)
                .padding(.bottom, 22)

            VStack(spacing: 14) {
                // Apple / Google / 扫码 三个玻璃胶囊同排:Apple 固定 110(最窄),
                // 扫码胶囊固定 56(只放一个 qrcode 图标),Google 吃掉剩余宽(≈124,
                // 比之前略窄)。三者总宽 = 下方邮箱行宽,所以输入框天然与这排对齐。
                HStack(spacing: 10) {
                    // Apple 这颗在「直接分发」的包里不出现 —— 见
                    // `appleSignInAvailable` 的说明。Google 会自动吃掉腾出来的宽度。
                    if Self.appleSignInAvailable {
                        appleButton
                            .frame(width: 110)
                    }
                    googleButton
                    qrLoginButton
                        .frame(width: 56)
                }
                emailRow
            }
            .disabled(vm.isBusy)
        }
    }

    // MARK: - Stage: human check

    @ViewBuilder
    private var humanCheckBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("你是？")
                .font(Theme.Fonts.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.leading, 4)

            HStack(spacing: 12) {
                humanButton
                robotButton
            }
            .disabled(vm.isBusy || vm.codeBlockShown)

            turnstileWidget

            Group {
                if vm.codeBlockShown {
                    codeBlock
                        .transition(.opacity)
                } else if vm.humanChoice == .robot {
                    robotEasterEgg
                        .transition(.opacity)
                } else if vm.humanChoice == .human && !vm.turnstileInteractive && !vm.turnstileFailed {
                    verifyingHint
                        .transition(.opacity)
                }
            }
        }
    }

    private var backButton: some View {
        Button {
            vm.backToEmailEntry()
            focusedField = .email
        } label: {
            Image(systemName: "chevron.left")
                .font(Theme.Fonts.glyph(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 32, height: 32)
                .macGlassCircle()
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(vm.isVerifying)
        .accessibilityLabel("返回")
    }

    private var humanButton: some View {
        Button {
            vm.tapHuman()
        } label: {
            choicePill(text: "人类", filled: vm.humanChoice == .human)
        }
        .buttonStyle(.plain)
    }

    private var robotButton: some View {
        Button {
            vm.tapRobot()
        } label: {
            choicePill(text: "机器人", filled: vm.humanChoice == .robot)
        }
        .buttonStyle(.plain)
    }

    private func choicePill(text: String, filled: Bool) -> some View {
        Text(text)
            .font(Theme.Fonts.system(size: 16, weight: .medium))
            .foregroundStyle(filled ? .white : Theme.Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                Group {
                    if filled {
                        Capsule().fill(Theme.Palette.accent)
                    } else {
                        Capsule().fill(Color.clear)
                    }
                }
            )
            .overlay(
                Capsule().strokeBorder(
                    filled ? Color.clear : Theme.Palette.ink.opacity(0.18),
                    lineWidth: 1
                )
            )
            .shadow(color: filled ? Color.black.opacity(0.18) : .clear, radius: 10, y: 4)
            .contentShape(Capsule())
    }

    /// Always-mounted Turnstile widget. Collapsed to a 1pt sliver for silent
    /// passes; only animates open if Cloudflare fires the
    /// `before-interactive-callback`.
    private var turnstileWidget: some View {
        let visible = vm.humanChoice == .human && !vm.codeBlockShown && vm.turnstileInteractive
        return MacTurnstileWebView(
            siteKey: HostedConfig.environment.turnstileSiteKey,
            host: HostedConfig.environment.turnstileHost,
            onToken: { token in vm.handleTurnstileToken(token) },
            onError: { msg in vm.handleTurnstileError(msg) },
            onInteractive: { vm.markTurnstileInteractive() }
        )
        .frame(maxWidth: .infinity)
        .frame(height: visible ? 72 : 1)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .id(vm.turnstileWidgetID)
    }

    private var verifyingHint: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在验证…")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.horizontal, 4)
    }

    private var codeBlock: some View {
        VStack(spacing: 14) {
            codeStatusRow
            if vm.otpSent {
                codeRow
                    .transition(.opacity)
            }
        }
    }

    private var codeStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(Theme.Fonts.glyph(size: 13))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text("\(vm.otpSent ? "码已发至：" : "码将发至：")\(vm.email)")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            sendOrResendButton
        }
        .padding(.horizontal, 4)
    }

    private var sendOrResendButton: some View {
        Group {
            if vm.resendCooldown > 0 {
                Text("\(vm.resendCooldown)s")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.7))
            } else if !vm.otpSent {
                Button("发送") {
                    vm.tapSend()
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                .disabled(vm.isVerifying || vm.turnstileToken == nil)
            } else {
                Button("重发") {
                    Task { await vm.resend() }
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                .disabled(vm.isVerifying)
            }
        }
    }

    private var robotEasterEgg: some View {
        VStack(spacing: 22) {
            Text("😲😲😲")
                .font(Theme.Fonts.system(size: 56))
            VStack(spacing: 10) {
                Text("尊敬的机器人您好，请联系 hello@pendingname.com")
                Text("我会稳稳地接住你")
                Text("我还可以帮你生成我和机器人的关系图")
            }
            .font(Theme.Fonts.footnote)
            .foregroundStyle(Theme.Palette.ink)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Apple / Google buttons

    /// 这个包能不能用「用 Apple 登录」。
    ///
    /// **Apple 不给「直接分发」(Developer ID，非 Mac App Store) 的 macOS 应用签发
    /// `com.apple.developer.applesignin`。** 这不是我们配置错了，是 Apple 的规则：
    /// DTS 在 <https://developer.apple.com/forums/thread/129263> 明确答复该能力不
    /// 支持 Developer ID，有人为此提 bug 后 Apple 回的是「此行为符合预期」。
    ///
    /// 2026-08-21 在本项目账号上实测坐实：把发布用的描述文件 `PendingBotDistribute`
    /// **重新生成**了一张（新 UUID、当天的生成时刻），该项授权**仍然不在文件里**；
    /// 而同一个 App ID 的**开发**描述文件里有。所以不是文件太旧。
    ///
    /// 后果曾经真的发生过：2026-08-07 那版 Developer ID 包里这项授权被签名步骤
    /// **静默剥掉**，登录页上的 Apple 按钮点了没用，而签名有效、公证通过、
    /// Gatekeeper 放行 —— 全链路零报错，两周没人发现。
    ///
    /// 所以这里按**包实际拿到的授权**来决定显不显示，而不是按平台写死：
    ///   - 开发构建 / 将来若走 Mac App Store → 授权在，按钮照常出现
    ///   - 我们自己发的 .dmg → 授权拿不到，按钮不出现（Google / 邮箱 / 扫码仍可用）
    ///
    /// 判不出来时**默认不显示**：显示一个点了没反应的按钮，比少一个按钮糟得多。
    ///
    /// iOS 与 Mac App Store 分发不受本条影响；`Networking/AppleSignIn.swift` 是
    /// 跨平台的，一行没动。
    private static let appleSignInAvailable: Bool = {
        // 读法与 `Networking/PushService.swift` 里读 `aps-environment` 的那段同源。
        // macOS 的描述文件在 Contents/ 下，不在 Resources 里，所以不能用
        // Bundle.main.url(forResource:withExtension:)。
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/embedded.provisionprofile")
        guard let data = try? Data(contentsOf: url) else { return false }
        // 描述文件是 CMS 签名过的 blob，里面那份 entitlements plist 是明文 XML。
        let raw = String(decoding: data, as: UTF8.self)
        guard let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else { return false }
        let plistData = Data(raw[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return false
        }
        return entitlements["com.apple.developer.applesignin"] != nil
    }()

    private var appleButton: some View {
        Button { Task { await vm.beginApple() } } label: {
            brandPillContent(logo: appleLogoImage, text: "Apple", textColor: Theme.Palette.onApplePill)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Capsule().fill(Theme.Palette.applePill))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }

    /// 和 iOS 端同一套规矩:底仍是本 app 的玻璃胶囊。Google 品牌指南只核准
    /// 全彩 G 落在他们公布的三套底色上,这里是作者拍板的取舍——按钮与登录页
    /// 其余部分保持同一材质,偏离已记进 `docs/tech-debt.md`。G 本身用的是
    /// Google 官方透明底资源,文字取他们规定的 `Theme.Palette.googleInk`。
    private var googleButton: some View {
        Button { Task { await vm.beginGoogle() } } label: {
            brandPillContent(
                logo: AnyView(Image("GoogleG").resizable().scaledToFit()),
                text: "Google",
                textColor: Theme.Palette.googleInk
            )
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Capsule())   // 玻璃胶囊整片可点(同 qrLoginButton)
            .macGlassCapsule()
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Google")
    }

    /// 扫码登录入口——qrcode 图标装在与 Apple/Google 同款玻璃胶囊里。点击把二维码
    /// 显示在左侧 logo 的位置(见 body 的 `showingQRLogin` 分支);激活时胶囊填成
    /// accent,再点一下收起二维码 / 还原 logo(等于返回)。
    @ViewBuilder
    private var qrLoginButton: some View {
        let glyph = Image(systemName: "qrcode")
            .font(Theme.Fonts.glyph(size: 22, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            // 整个胶囊都可点——否则只有 qrcode 字形本身命中,周围留白点不动。
            .contentShape(Capsule())
        Button {
            showingQRLogin.toggle()
            focusedField = nil
        } label: {
            if showingQRLogin {
                glyph
                    .foregroundStyle(Theme.Palette.onAccent)
                    .background(Capsule().fill(Theme.Palette.accent))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            } else {
                glyph
                    .foregroundStyle(Theme.Palette.ink)
                    .macGlassCapsule()
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("扫码登录")
        .help(showingQRLogin ? "收起二维码" : "扫码登录")
    }

    /// Prefer the Apple-supplied logo-only artwork when present (shared
    /// asset catalog), falling back to the SF Symbol otherwise — mirrors iOS.
    private var appleLogoImage: AnyView {
        if NSImage(named: "AppleSignInLogo") != nil {
            AnyView(
                Image("AppleSignInLogo")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Theme.Palette.onApplePill)
                    .scaledToFit()
            )
        } else {
            AnyView(
                Image(systemName: "applelogo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Palette.onApplePill)
            )
        }
    }

    private func brandPillContent(
        logo: AnyView, text: String, textColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            logo.frame(width: 18, height: 18)
            Text(text)
                .font(Theme.Fonts.system(size: 18, weight: .medium))
                .foregroundStyle(textColor)
        }
    }

    // MARK: - Email / code rows

    private var emailRow: some View {
        inputRow {
            TextField("邮箱", text: $vm.email)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .email)
                .onSubmit { advance() }
        }
    }

    private var codeRow: some View {
        inputRow {
            TextField("码可能在垃圾邮件里", text: $vm.code)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .code)
                .onSubmit { Task { await vm.verifyCode() } }
        }
    }

    /// One row: a plain text input on the left, a green circular submit
    /// button on the right — same shape as the iOS inputRow.
    @ViewBuilder
    private func inputRow<Content: View>(
        @ViewBuilder field: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            field()
                .font(Theme.Fonts.system(size: 16))
                .padding(.leading, 18)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

            submitArrowButton
                .padding(.trailing, 7)
        }
        .frame(height: 48)
        .macGlassCapsule()
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private var submitArrowButton: some View {
        Button {
            switch vm.stage {
            case .enteringEmail: advance()
            case .humanCheck:    Task { await vm.verifyCode() }
            }
        } label: {
            Group {
                if vm.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.Palette.onAccent)
                } else {
                    Image(systemName: "arrow.right")
                        .font(Theme.Fonts.glyph(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Palette.onAccent)
                }
            }
            .frame(width: 35, height: 35)
            .background(
                Circle().fill(vm.canSubmit ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.28))
            )
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSubmit || vm.isBusy)
        .animation(.easeInOut(duration: 0.15), value: vm.canSubmit)
    }

    private func errorBlock(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Neutral-ink counterpart to `errorBlock` — used when a sign-in method
    /// simply has no coordinate in this build. Deliberately not red: this
    /// isn't a failure, it's what a public clone ships.
    private func noticeBlock(text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Palette.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions bridging view focus → view model

    private func advance() {
        if vm.advanceToHumanCheck() {
            focusedField = nil
            showingQRLogin = false   // 走邮箱流程时把 logo 还原
        }
    }
}

private struct PendingBotMacQRLoginView: View {
    @State private var challenge: PendingBotDeviceLoginChallenge?
    @State private var status: Status = .requesting
    @State private var pollTask: Task<Void, Never>?
    @State private var errorMessage: String?

    enum Status: Equatable {
        case requesting
        case waiting
        case approved
        case error
    }

    // 取代 logo 的二维码卡片:白底圆角方卡,只有码(失败/超时则白色模糊 + 刷新图标)。
    var body: some View {
        content
            .frame(width: 140, height: 140)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
            .task { start() }
            .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .requesting:
            // 生成二维码前的过渡:只一个 spinner。
            ProgressView()
                .controlSize(.large)
        case .waiting:
            qrImage(blurred: false)
        case .approved:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
        case .error:
            // 超时 / 过期 / 失败:二维码白色模糊,盖一个刷新图标,点了重新生成。
            ZStack {
                qrImage(blurred: true)
                Color.white.opacity(0.72)
                Button { start() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("刷新")
                .accessibilityLabel("刷新二维码")
            }
        }
    }

    /// 当前 challenge 的二维码;失败态传 `blurred: true` 渲染成模糊。没生成出码就
    /// 返回一块透明占位(由调用方盖白幕 + 刷新图标)。
    @ViewBuilder
    private func qrImage(blurred: Bool) -> some View {
        if let challenge, let bitmap = QRCode.image(challenge.qrPayload, quietModules: 2) {
            Image(platformImage: bitmap)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 116, height: 116)
                .blur(radius: blurred ? 7 : 0)
        } else {
            Color.clear.frame(width: 152, height: 152)
        }
    }

    private func start() {
        errorMessage = nil
        status = .requesting
        pollTask?.cancel()
        Task {
            do {
                let api = PendingBotDeviceLoginAPI()
                let created = try await api.createChallenge()
                challenge = created
                status = .waiting
                startPolling(challenge: created, api: api)
            } catch {
                errorMessage = error.localizedDescription
                status = .error
            }
        }
    }

    private func startPolling(challenge: PendingBotDeviceLoginChallenge, api: PendingBotDeviceLoginAPI) {
        let deadline = Date().addingTimeInterval(4 * 60)
        pollTask = Task {
            while !Task.isCancelled {
                if Date() > deadline {
                    await MainActor.run {
                        errorMessage = "等待批准超时，请重新发起。"
                        status = .error
                    }
                    return
                }
                do {
                    let response = try await api.poll(
                        challengeId: challenge.challengeId,
                        secret: challenge.secret
                    )
                    if response.status == "approved" {
                        guard let tokenHash = response.supabaseTokenHash, !tokenHash.isEmpty else {
                            await MainActor.run {
                                errorMessage = "服务器没有返回可用的登录凭据，请重试。"
                                status = .error
                            }
                            return
                        }
                        _ = try await EmailSignIn.verifyTokenHash(tokenHash)
                        await MainActor.run {
                            status = .approved
                        }
                        // 成功后无需手动关闭:AccountStore 拿到会话 → MacRootGate
                        // 自动把整页换成主界面。
                        return
                    }
                    if response.status == "rejected" {
                        await MainActor.run {
                            errorMessage = "登录请求被拒绝。"
                            status = .error
                        }
                        return
                    }
                    if response.status == "expired" {
                        await MainActor.run {
                            errorMessage = "二维码已过期，请重新发起。"
                            status = .error
                        }
                        return
                    }
                } catch APIError.gone(let message) {
                    await MainActor.run {
                        errorMessage = message.isEmpty ? "二维码已过期，请重新发起。" : message
                        status = .error
                    }
                    return
                } catch {
                    // Network jitter: keep polling until the client-side deadline.
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// macOS 26+ uses the Liquid Glass material via `.glassEffect`; older systems
/// fall back to the standard system material. Twin of the iOS helpers in
/// `WelcomeView`, scoped here so the Mac login reads identically.
private extension View {
    @ViewBuilder
    func macGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func macGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
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

/// Reaches the host `NSWindow` to give the login screen two cosmetic touches
/// the standard `.windowStyle(.hiddenTitleBar)` can't:
///   1. **Bigger rounded corners** — the window is made transparent and the
///      content layer is corner-clipped, so the whole panel reads as a rounded
///      card (rounder than AppKit's default ~10pt) with a matching shadow.
///   2. **Roomier traffic lights** — the close / minimise / zoom buttons are
///      nudged in from the corner and spaced further apart.
/// Constants are kept here so they're easy to tune by eye.
struct MacLoginWindowStyler: NSViewRepresentable {
    var cornerRadius: CGFloat = 22
    var trafficInsetLeft: CGFloat = 20
    var trafficInsetTop: CGFloat = 20
    var trafficSpacing: CGFloat = 12

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.styler = self
        DispatchQueue.main.async { [weak v] in
            if let w = v?.window { context.coordinator.attach(to: w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.styler = self
        DispatchQueue.main.async { [weak nsView] in
            if let w = nsView?.window { context.coordinator.attach(to: w) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var styler: MacLoginWindowStyler?
        private weak var window: NSWindow?
        private var observed = false

        func attach(to window: NSWindow) {
            self.window = window
            applyRounding(window)
            layoutTrafficLights(window)
            guard !observed else { return }
            observed = true
            let nc = NotificationCenter.default
            for name: NSNotification.Name in [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
            ] {
                nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let w = self.window else { return }
                        self.layoutTrafficLights(w)
                    }
                }
            }
        }

        private func applyRounding(_ window: NSWindow) {
            let radius = styler?.cornerRadius ?? 22
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            if let content = window.contentView {
                content.wantsLayer = true
                content.layer?.cornerRadius = radius
                content.layer?.cornerCurve = .continuous
                content.layer?.masksToBounds = true
            }
            window.invalidateShadow()
        }

        private func layoutTrafficLights(_ window: NSWindow) {
            let left = styler?.trafficInsetLeft ?? 20
            let top = styler?.trafficInsetTop ?? 20
            let spacing = styler?.trafficSpacing ?? 12
            let buttons = [NSWindow.ButtonType.closeButton,
                           .miniaturizeButton,
                           .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let bar = buttons[0].superview else { return }
            var x = left
            for button in buttons {
                let size = button.frame.size
                // Titlebar view is flipped-from-top in AppKit window coords, so
                // measure `top` down from the container's top edge.
                let y = bar.bounds.height - top - size.height
                button.setFrameOrigin(NSPoint(x: x, y: y))
                x += size.width + spacing
            }
        }
    }
}
#endif
