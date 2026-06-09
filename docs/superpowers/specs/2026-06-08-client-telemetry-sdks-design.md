# 客户端观测/计费身份 SDK 接入(PostHog / Sentry / RevenueCat)

- **日期**: 2026-06-08
- **分支**: feat/client-telemetry-sdks
- **背景**: docs/tech-debt.md「客户端从不把用户身份同步给 RevenueCat / PostHog / Sentry」一条。
  edge 侧约定外部服务都用 `subject_id`(= `auth.users.id`)当外部主键且已接好;
  客户端(iOS/Mac)三个 SDK 全缺,本 spec 补上。

## 目标 / 非目标

**目标**
- iOS + macOS 接入 PostHog(分析)、Sentry(崩溃/错误)、RevenueCat(计费身份)。
- 登录后用 `subject_id` 调 identify/setUser/logIn;登出 reset/clear/logOut。
- 标识只用 `subject_id`,**不传 email/PII**,与 edge `distinctId=subjectId` 对齐。

**非目标(YAGNI)**
- RevenueCat **只接身份**,不碰 ASC 内购产品 / offering / paywall / 购买流程(随 IAP 上线另做)。
- 不开 PostHog session replay;不加手动 breadcrumb / 自定义 perf span(用 Sentry 默认自动捕获)。
- 不动 edge 侧(edge 的 PostHog/Sentry 已接)。

## 架构:单一 `Telemetry` 协调器 + 订阅 `AccountStore.current`

三个 SDK 生命周期一致(启动 init → 登录 identify → 登出 reset)、输入一致
(`AccountStore.current?.id`),收成一个类:一处订阅、一处按 key gate、一处放平台 `#if`。

### 组件

1. **`HostedConfig` 加 key**(每环境 `.dev` / `.remote`):
   - `posthogKey` / `posthogHost` / `sentryDSN` / `revenueCatKey`
   - `.remote` 填真值:PostHog `phc_…`(host = EU `https://eu.i.posthog.com`)、Sentry iOS DSN。
     RevenueCat 暂留**空串占位**(账号未开)。
   - `.dev` 全空。**空 key = 该 SDK configure 时跳过(no-op)**,本地/预发布不误报数据、RC 不崩。

2. **`Telemetry.swift`(新,三端共享,`Sources/Networking/`)**:
   - `static func configure()` — `PendingBotApp.init()`(首帧前)调。
     - 空 DSN/key 的 SDK 整段跳过。
     - Sentry 最早 init(抓启动崩溃);PostHog `setup`(sessionReplay=false、captureScreenViews=false、personProfiles=.identifiedOnly);
       RevenueCat `configure(withAPIKey:appUserID:nil)`。
   - `func identify(_ userId: String)` / `func reset()`:
     - Sentry:`User().userId = id; SentrySDK.setUser(user)` / `setUser(nil)`
     - PostHog:`PostHogSDK.shared.identify(id)` / `.reset()`
     - RevenueCat:`Purchases.shared.logIn(id)` / `logOut()`(best-effort,匿名态 logOut 抛错吞掉)

3. **挂到 `AccountStore.current`(@Published)**:
   - iOS `PendingBotApp`:复用已有 `.onChange(of: accountStore.current)`(push service 也挂这)——非空→`identify(id)`,空→`reset()`。
   - macOS `@main` 当前**没有** onChange,只有 `.task bootstrap`,需补一个 onChange 挂同样逻辑。

4. **`project.yml` 加 SPM**(都支持 macOS,不加 `platforms:` 限制):
   - `posthog-ios`(`github.com/PostHog/posthog-ios`,3.x)
   - `sentry-cocoa`(`github.com/getsentry/sentry-cocoa`,9.x)
   - `purchases-ios`(`github.com/RevenueCat/purchases-ios`,5.x,product `RevenueCat`)
   - 改完 `xcodegen` 重生 project。

## 错误处理 / 降级

- 每个 SDK 调用按 key 存在性 gate;key 空 → 整段 no-op,绝不崩。
- RevenueCat logIn/logOut `try?` 吞错(身份同步失败不该影响登录流程)。
- identify/reset 在 `@MainActor` 上跑(AccountStore.current 是 main-actor @Published)。

## 验证

- `xcodegen` → iOS Simulator build + macOS build 双绿。
- 装模拟器启动,确认 `Telemetry.configure()` 不崩、登录后无异常。
- **事件真实投递到 dashboard** 需开 app + 看 PostHog/Sentry 后台 → 归**手动验证**,
  连同 RevenueCat 占位 key 一并记 tech-debt(代码就位、待真值/真机闭环)。

## 待办尾巴(交付时记 tech-debt)

- RevenueCat `revenueCatKey` 占位空串 → RC 休眠,待账号开通补 key + 真上 IAP。
- PostHog/Sentry 事件投递的真机闭环验证未做(只验编译 + 启动不崩)。
