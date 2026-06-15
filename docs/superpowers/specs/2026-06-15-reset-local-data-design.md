# 重置 / 清除本机所有数据 — 设计文档

- 日期:2026-06-15
- 分支:`feat/reset-local-data`
- 涉及:`apps/pendingcrew`(Mac)、`apps/pendingbot`(iOS + macOS)

## 目标

在 PendingBot 与 PendingCrew 的设置里各加一个破坏性选项「清除本机所有数据」,把该 app 在本机的全部本地数据清空,回到接近「全新安装」的状态。

**仅本地清除**,不涉及服务器:
- ≠ PendingBot 已有的「注销账号」(那是 `POST /v1/me/account-deletion` 服务端删号)。
- 不删服务器上的账号、crew、消息、钱包。清的是本机缓存 / 会话 / 设置 / 本地 crew 数据。

## 非目标

- 不做服务器侧账号或数据删除。
- 不重命名底层 `FamilyCredential*` / 本地模式里"BYOK"标识符的代码(仅改用户可见文案)。持久化标识符改名风险大,留作独立工作。
- 不抽公共 Swift 包:两 app 代码库分离,各自实现协调器、复用各自原语。

## 共享登录状态 —— 用户自选(两 app 一致)

两 app 通过共享 keychain access group(`M42BKJN82S.com.pendingname.shared`,service `com.pendingname.family-sso`)共用一份登录凭证,让同机的另一个 app 免扫码登录。底层代码叫 `FamilyCredential`,但**用户文案不出现"家庭/family"**,而是按"与另一个 app 共享的登录状态"描述。

### 交互流程(点「清除本机所有数据」后)

1. **先查共享凭证是否存在**:
   - PendingCrew:`FamilyCredentialStore.get() != nil`
   - PendingBot:`#if os(macOS) FamilyCredentialWriter.get() != nil #else false #endif`
   - 共享凭证是 macOS-only(PendingCrew 仅 Mac;PendingBot 的共享写入也 `#if os(macOS)`),所以 **iOS 上恒为 false**,自然只走"直接清除",无需平台分支特判。

2. **若共享凭证存在** → `confirmationDialog` 给两个破坏性选项 + 取消:
   - PendingCrew 文案:
     - 「清除(保留与 PendingBot 共享的登录状态)」
     - 「清除,并清除与 PendingBot 共享的登录状态」
   - PendingBot 文案:
     - 「清除(保留与 PendingCrew 共享的登录状态)」
     - 「清除,并清除与 PendingCrew 共享的登录状态」
   - dialog 说明:不可恢复、仅本机。

3. **若共享凭证不存在** → 简单 `confirmationDialog`:
   - 「清除本机所有数据」(destructive) + 取消
   - 说明:不可恢复、仅本机。
   - 执行时不碰共享凭证(本来也没有)。

协调器以 `clearSharedCredential: Bool` 参数控制;不存在或用户选"保留"时为 `false`,选"一并清除"时为 `true`。

## PendingCrew(Mac-only)

### Part 1 — chore:删死 BYOK key

PendingCrew 本地模式早已转向"驱动本机已登录的 claude/codex CLI,无需 key"(`WelcomeView`/`LocalSetupView` 文案、`enterLocalMode()` 以 `localModeSelected` 标志判定,与 key 解耦)。provider key 那套是为"未来 API-key 额度池路径"预留的脚手架,**只写不读、零消费**(runner 不注入任何 `*_API_KEY` env),`clearByokConfig()` 零调用。删之零回归。

删除清单:
- 删文件 `Sources/Stores/BYOKConfig.swift`。
- `Sources/Stores/AppModel.swift`:删 `byokConfig` @Published、`saveByokConfig`、`clearByokConfig`、init 里 BYOK 加载段、`saveDeviceGrantToken` 里的 `BYOKConfig.clear()`、`KeychainAccount.byok{Anthropic,OpenAI,Gemini}`;`localModeSelected` init 去掉 `loadedByok?.hasAnyKey` 向后兼容(macOS `isConfigured` 恒 true,该兼容走不到)。
- `Sources/Mac/Views/LocalSetupView.swift`:删三个 SecureField + form + `save()` 里 BYOK 构造,保留「进入」按钮 → `model.enterLocalMode()`,更新陈旧文案。
- `Sources/Support/PendingCrewAuthCredential.swift`:删死的 `case byok`(全代码无人构造),更新 doc。
- `Sources/Views/WelcomeView.swift`:更新 footnote / doc 里提"BYOK key"的陈旧文案。

**保留(活的本地模式,仅名字过时)**:`notSupportedInByok` 错误 case(三处真 throw)、`local-byok` / `local-byok-user` 持久化标识符、machine `kind:"byok"`、所有把"BYOK"当"本地模式"的注释。命名漂移记入 `docs/tech-debt.md`。

### Part 2 — feat:LocalDataReset 协调器

`Sources/Stores/LocalDataReset.swift`(新),`performReset(clearSharedCredential:)` 顺序:
1. 删 keychain `device-grant`(`KeychainStore.delete(account: .deviceGrant)`)。
2. `clearSharedCredential == true` 时 `FamilyCredentialStore.clear()`;否则不动。
3. `UserDefaults.standard.removePersistentDomain(forName: <bundleId>)` —— 清整个 app 域(apiBaseURL / localModeSelected / firstLaunchDisclosureAccepted.v1 / sessionLastViewed / lastWorkingDirectory / deviceId / appearance)。
4. 删整个 `~/Library/Application Support/PendingCrew/` 目录(local-crews.json / captain-templates.json / whiteboards/ / *.approvals.json / corrupt 备份全包)。
5. **重启 app**:`NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: createsNewApplicationInstance=true)` 成功回调里 `NSApp.terminate(nil)`。

重启的理由:Mac 上 `AppModel.isConfigured` 恒 true → 永不回 WelcomeView;且运行中进程里 `@AppStorage`、`FirstLaunchDisclosureGate` 的 `@State`、`LocalCrewStore/CaptainTemplateStore/...` 单例、缓存的 deviceId 都还在内存。重启后全部从(已空的)盘重读 = 真·恢复出厂,省掉脆弱的"逐个重置内存单例"。

### UI

`Sources/Mac/Views/CrewSettingsView.swift`(⌘, 设置窗)底部加「危险区」分区,红色按钮「清除本机所有数据」→ 上述交互流程。

## PendingBot(iOS + macOS)

### LocalDataReset 协调器

复用已有 sign-out 原语 + 补齐缺口。`performReset(clearSharedCredential:)` 顺序:
1. `Telemetry.shared.reset()` —— PostHog / Sentry / RevenueCat 身份。
2. `try? await SupabaseStack.shared.auth.signOut(scope: .local)` —— 清 supabase 会话(本地 scope,不发网络撤销),会话变 nil 触发观察者 → `accountStore.current = nil`。
3. `LocalDatabase.shared.wipeForSignOut()` —— 删 SQLCipher 库 + WAL/SHM + 轮换 keychain 密钥。
4. `URLCache.shared.removeAllCachedResponses()`;iOS `AvatarCache.shared.clear()`。
5. `UserDefaults.standard.removePersistentDomain(forName: "com.pendingname.pendingbot")`。
6. `clearSharedCredential == true` 且 macOS 时 `FamilyCredentialWriter.clear()`;否则不动。
7. 收尾:
   - **macOS** → 重启 app(同 PendingCrew 的 openApplication + terminate)。
   - **iOS** → 不能自重启(Apple guideline)。原地 teardown:第 2 步已把 session 置空 → `RootView` 自动 gate 回 WelcomeView / 登录页。UserDefaults 整域已清;运行中 `@AppStorage`(如 appearance)的内存缓存属 cosmetic,下次启动彻底归零。

### UI 入口

`apps/pendingbot/Sources/Features/Me/MeTabView.swift` 危险区,挨着已有「退出登录 / 注销账号」,加「清除本机所有数据」红色 row → 上述交互流程。

## 各 app 清除清单速查

| 数据 | PendingCrew | PendingBot |
|---|---|---|
| 登录 token / 会话 | keychain `device-grant` | supabase session(SDK,`.signOut(.local)`)|
| 本地结构化数据 | App Support/PendingCrew 整目录 | LocalDatabase(SQLCipher)`wipeForSignOut` |
| HTTP / 图片缓存 | (无显式) | `URLCache` + iOS AvatarCache |
| UserDefaults | `removePersistentDomain` | `removePersistentDomain` |
| 遥测身份 | (PendingCrew 若有 Telemetry 一并 reset) | `Telemetry.reset()` |
| 共享登录状态 | 按用户选择 `FamilyCredentialStore.clear()` | 按用户选择 `FamilyCredentialWriter.clear()`(macOS)|
| 清完去向 | 重启 app | macOS 重启 / iOS 回登录页 |

## 验证

- PendingCrew:`cd apps/pendingcrew && xcodebuild ... -destination 'platform=macOS' build`(改 project.yml 先 xcodegen)+ GUI 实跑:点清除 → 确认 → app 重启 → crew 列表空、已登出、首启免责声明重现。
- PendingBot:`xcodebuild -scheme PendingBot -destination 'generic/platform=iOS Simulator' build` + iOS 模拟器装机实跑(点清除→回登录页→消息缓存/会话空)、`-destination 'platform=macOS' build` + Mac GUI 实跑(清除→重启)。
- 共享凭证两条路径都验:有共享凭证(Mac 双 app 都登录过)→ 出二选一;无 → 直接单确认。

## 提交拆分(依赖序)

1. `chore(pendingcrew): 删死 BYOK provider-key 路径`
2. `chore(docs): tech-debt 记 BYOK→本地模式 命名漂移`
3. `feat(pendingcrew): LocalDataReset 协调器 + 设置入口`
4. `feat(pendingbot): LocalDataReset 协调器 + 设置入口`
5. 验证(Mac build / iOS+Mac build + 实跑)
