# PendingCrew 登录页搬 PendingBot + 同发布者确认登录 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PendingCrew 登录入口换成 PendingBot 那套（Apple/Google/邮箱/扫码），并加一张「检测到本机 PendingBot 已登录 → 显示头像+账号一键继续」的确认卡；底层仍只持有受限 `pendingcrew_control` device grant。

**Architecture:** 沿用 scoped-grant 安全模型（spec [2026-06-08](../specs/2026-06-08-pendingcrew-login-sso-design.md) / [2026-06-17](../specs/2026-06-17-pendingcrew-login-port-design.md)）。三条登录路径殊途同归到「拿 `pfa_` 家族凭据 → `POST /v1/device-grant/mint` 换 `pdg_` grant」。直接登录路径用一个**内存态 Supabase client** 拿一次性 session 调 `/v1/me/family-credential`，用完 `signOut`，session 绝不落 keychain。分 P1（确认卡 + 现有扫码，低依赖）/ P2（完整直接登录栈）两阶段，**P2 前不拆扫码**。

**Tech Stack:** SwiftUI（macOS 14+/iPadOS 17+）、supabase-swift（仅 P2，内存 storage）、GoogleSignIn-iOS（仅 P2）、Cloudflare Turnstile webview；edge = Hono/TypeScript；XCTest（PendingCrewTests，macOS-only bundle）。

**平台：** PendingCrew 跑 macOS + iPad。Mac 上登录是侧栏可选能力叠加（不开屏 gate）；iPad 上登录是首屏硬门槛。

---

## File Structure

**P1 — PendingCrew（确认卡 + 现有扫码）**
- Modify `apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift` — `FamilyCredential` 加可选 `displayName`/`avatarSeed`。
- Create `apps/pendingcrew/Sources/Views/AccountConfirmCard.swift` — 头像+账号+继续/换号卡（跨平台）。
- Create `apps/pendingcrew/Sources/Services/CrewLoginIdentity.swift` — 从 `FamilyCredentialStore` 派生确认卡展示模型（纯 Foundation，可单测）。
- Modify `apps/pendingcrew/Sources/Views/WelcomeView.swift` — iPad gate 改成「有家族凭据→确认卡；换号/无凭据→现有 LoginView」。
- Modify `apps/pendingcrew/Sources/Views/LoginView.swift` — 视觉对齐 PendingBot（BrandMark + Theme），保留扫码 + 家族 SSO。
- Modify `apps/pendingcrew/Sources/Mac/Views/MacRootView.swift` / 侧栏 — Mac 登录入口弹 sheet（确认卡或 LoginView）。
- Modify `apps/pendingcrew/Tests/PendingCrewTests/...` + `apps/pendingcrew/project.yml` — 加 `CrewLoginIdentity` 单测。

**P1 — PendingBot（写 profile + iOS 也写）**
- Modify `apps/pendingbot/Sources/Storage/FamilyCredentialWriter.swift` — `FamilyCredential` 加可选 profile；放开 `#if os(macOS)` 到 iOS。
- Modify `apps/pendingbot/Sources/Storage/AccountStore.swift` — iOS 登录也调 `syncIfNeeded()`；写入时带 profile；登出清除（去掉 macOS-only gate）。
- Modify `apps/pendingbot/Sources/Networking/APIClient.swift`（若需）— `/v1/me/family-credential` 解码加 `displayName`。

**P1 — Edge**
- Modify `apps/edge/src/routes/me.ts` — `POST /v1/me/family-credential` 回包加 `displayName`（用户个人 subject 的 display_name）。

**P2 — PendingCrew（完整直接登录栈）**
- Create `apps/pendingcrew/Sources/Services/CrewHostedConfig.swift` — Supabase URL/publishable key + Turnstile siteKey/host（镜像 PendingBot HostedConfig）。
- Create `apps/pendingcrew/Sources/Services/CrewSupabaseStack.swift` — 内存态 `AuthLocalStorage` 的 SupabaseClient 单例。
- Create `apps/pendingcrew/Sources/Services/InMemoryAuthStorage.swift` — `AuthLocalStorage` 内存实现（可单测）。
- Create `apps/pendingcrew/Sources/Auth/CrewEmailSignIn.swift` / `CrewAppleSignIn.swift` / `CrewGoogleSignIn.swift` — vendor 自 PendingBot，repoint 到 `CrewSupabaseStack`。
- Create `apps/pendingcrew/Sources/Auth/CrewTurnstileWebView.swift` — vendor 自 PendingBot iOS `TurnstileWebView`（+ 复用已存在的 Mac twin 思路）。
- Create `apps/pendingcrew/Sources/Auth/CrewWelcomeViewModel.swift` — vendor 自 PendingBot `WelcomeViewModel`，成功回调改走 `CrewLoginExchange`。
- Create `apps/pendingcrew/Sources/Services/CrewLoginExchange.swift` — session→pfa_→mint→signOut 编排（纯逻辑 + 注入，可单测）。
- Create `apps/pendingcrew/Sources/Views/CrewWelcomeView.swift`（iPad）/ `apps/pendingcrew/Sources/Mac/Views/CrewMacWelcomeView.swift`（Mac）— vendor 自 PendingBot 两个 Welcome 视图渲染层。
- Modify `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift` — 加 `issueFamilyCredential(accessToken:)`。
- Modify `apps/pendingcrew/project.yml` — 加 SPM 依赖 Supabase + GoogleSignIn；`Info.plist` 加 `GIDClientID` + reversed-client-id URL scheme。
- Modify WelcomeView/LoginView/MacRootView — 「换其它账号」目标从现有 LoginView 换成 `CrewWelcomeView`/`CrewMacWelcomeView`。

---

# Phase 1 — 确认卡 + 现有扫码（低依赖，交付 hero 体验）

## Task 1: `FamilyCredential` payload 加可选 profile（两 app 字节级契约）

**Files:**
- Modify: `apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift`
- Modify: `apps/pendingbot/Sources/Storage/FamilyCredentialWriter.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/FamilyCredentialCodecTests.swift` (Create)
- Modify: `apps/pendingcrew/project.yml`（test bundle source 列表加 FamilyCredentialStore + 新测试文件——FamilyCredentialStore 已在列，确认即可）

- [ ] **Step 1: 写失败测试 — 旧 payload（无 profile）仍能 decode，新 payload round-trips**

```swift
// apps/pendingcrew/Tests/PendingCrewTests/FamilyCredentialCodecTests.swift
import XCTest
@testable import PendingCrew

final class FamilyCredentialCodecTests: XCTestCase {
    func testDecodesLegacyPayloadWithoutProfile() throws {
        let legacy = #"{"token":"pfa_abc","subjectId":"11111111-1111-1111-1111-111111111111"}"#
        let cred = try JSONDecoder().decode(FamilyCredential.self, from: Data(legacy.utf8))
        XCTAssertEqual(cred.token, "pfa_abc")
        XCTAssertNil(cred.displayName)
        XCTAssertNil(cred.avatarSeed)
    }

    func testRoundTripsProfileFields() throws {
        let cred = FamilyCredential(token: "pfa_x", subjectId: "sid", displayName: "阿狸", avatarSeed: "seed-9")
        let data = try JSONEncoder().encode(cred)
        let back = try JSONDecoder().decode(FamilyCredential.self, from: data)
        XCTAssertEqual(back.displayName, "阿狸")
        XCTAssertEqual(back.avatarSeed, "seed-9")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/FamilyCredentialCodecTests 2>&1 | tail -20`
Expected: 编译失败（`FamilyCredential` 没有 `displayName`/`avatarSeed`）。

- [ ] **Step 3: 给两边的 `FamilyCredential` 加可选字段（字节级一致）**

两个文件里的 struct 同步改成：

```swift
struct FamilyCredential: Codable, Equatable {
    let token: String        // pfa_*
    let subjectId: String    // 默认 mint 目标（个人主体）
    /// 同发布者确认卡展示用 —— PendingBot 写入侧在登录时带上。可选：旧 payload
    /// 无此字段时 decode 不失败（确认卡降级到通用文案，mint 后再回填真实身份）。
    var displayName: String?
    /// 用户自有头像的 seed（pendingbot.users.custom_fields.avatar_seed），
    /// 驱动确认卡的 BotAvatar 字形。可选，同上降级。
    var avatarSeed: String?
}
```

> 两个文件的 struct 必须逐字一致（service / accessGroup / 字段名 / 类型）。本任务一次提交同时改两边。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/FamilyCredentialCodecTests 2>&1 | tail -20`
Expected: PASS（2 测试）。

- [ ] **Step 5: 提交**

```bash
git add apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift \
        apps/pendingbot/Sources/Storage/FamilyCredentialWriter.swift \
        apps/pendingcrew/Tests/PendingCrewTests/FamilyCredentialCodecTests.swift
git commit -m "feat(pendingcrew): family credential payload 加可选 displayName/avatarSeed (两端契约)"
```

---

## Task 2: PendingBot 写入侧带 profile + iOS 也写

**Files:**
- Modify: `apps/pendingbot/Sources/Storage/FamilyCredentialWriter.swift`
- Modify: `apps/pendingbot/Sources/Storage/AccountStore.swift:152-159`（refreshProfileFlags 的 syncIfNeeded gate）、`:108-110`、`:253-259`（登出清除 gate）

- [ ] **Step 1: `syncIfNeeded` 接收 profile 并写入**

把 `FamilyCredentialWriter` 从 `#if os(macOS)` 放开（删文件首尾的 `#if os(macOS)`/`#endif`，`Host.current()` 用 `currentDeviceName()` 跨平台 helper 替换 —— iOS 用 `UIDevice.current.name`，复用 EmailSignIn.swift 末尾已有的 `currentPendingBotDeviceName()` 同款），`syncIfNeeded` 签名改为带 profile：

```swift
static func syncIfNeeded(displayName: String?, avatarSeed: String?) async {
    guard get() == nil else { return }
    struct Body: Encodable { let deviceName: String }
    struct Response: Decodable {
        let familyCredential: FamilyCredentialResponse
        struct FamilyCredentialResponse: Decodable { let token: String; let subjectId: String; let displayName: String? }
    }
    let deviceName = currentFamilyDeviceName()  // 跨平台
    do {
        let res: Response = try await APIClient().post("v1/me/family-credential", body: Body(deviceName: deviceName))
        set(FamilyCredential(
            token: res.familyCredential.token,
            subjectId: res.familyCredential.subjectId,
            displayName: displayName ?? res.familyCredential.displayName,
            avatarSeed: avatarSeed
        ))
        log.info("family credential issued and stored")
    } catch {
        log.error("family credential issuance failed: \(String(describing: error), privacy: .public)")
    }
}
```

新增跨平台设备名 helper（放本文件底部）：
```swift
private func currentFamilyDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "Mac"
    #elseif os(iOS)
    return UIDevice.current.name
    #else
    return "Device"
    #endif
}
```
（iOS 需 `import UIKit`；文件顶部按平台 import。）

- [ ] **Step 2: AccountStore 调用点带上 profile + 去掉 macOS-only gate**

`refreshProfileFlags()` 里把（现 :154-159 的）`#if os(macOS) … syncIfNeeded() …#endif` 改成在拿到 `avatarSeed`/`profileDisplayName` 后无条件调用——但要放在已 `self.avatarSeed = …` / `self.profileDisplayName = …` 赋值之后，确保传的是刚读到的值：

```swift
// 放在 refreshProfileFlags 内、解析完 cf 之后（约 :182 之后）：
Task { await FamilyCredentialWriter.syncIfNeeded(displayName: self.profileDisplayName, avatarSeed: self.avatarSeed) }
```
删掉原 :154-159 那段 macOS-gated 的提前调用。登出清除（:108-110 `signOutLocally`、:253-259 `signOut`）把 `#if os(macOS)` 去掉，改为跨平台调用 `FamilyCredentialWriter.clear()`（iOS 也要清，否则换号后旧确认卡身份残留）。

- [ ] **Step 3: 编译验证（iOS + macOS）**

Run（iOS）：`cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Run（macOS）：`cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: 两端 `BUILD SUCCEEDED`。

- [ ] **Step 4: 提交**

```bash
git add apps/pendingbot/Sources/Storage/FamilyCredentialWriter.swift apps/pendingbot/Sources/Storage/AccountStore.swift
git commit -m "feat(pendingbot): 家族凭据写入带 profile + iOS 也写/登出也清"
```

---

## Task 3: Edge — `/v1/me/family-credential` 回包加 `displayName`

**Files:**
- Modify: `apps/edge/src/routes/me.ts:341-384`

- [ ] **Step 1: 读个人 subject 的 display_name 并回包**

现有处理器（:355-362）已读 `subjects` 取 `id`；把 select 改成 `'id, display_name'`，返回处（:383）带上：

```ts
const { data: personal, error: subjectErr } = await supa
  .from('subjects')
  .select('id, display_name')              // 加 display_name
  .eq('subject_type', 'user_account')
  .eq('user_id', userId)
  .eq('status', 'active')
  .maybeSingle();
// …（错误处理不变）…
return c.json({
  familyCredential: { token, subjectId: personal.id },
  displayName: personal.display_name ?? null,   // 新增：给直接登录路径 mint 后即时显示
});
```

> 客户端解码加 optional `displayName` 即可，老客户端忽略多余字段，无破坏。无 schema 改动 → 不需要 db push。

- [ ] **Step 2: typecheck**

Run: `bun --filter='@pendingbot/edge' run typecheck 2>&1 | tail -8`
Expected: 无错误。

- [ ] **Step 3: 提交**

```bash
git add apps/edge/src/routes/me.ts
git commit -m "feat(edge): /v1/me/family-credential 回包加 displayName"
```

---

## Task 4: PendingCrew `CrewLoginIdentity` — 从家族凭据派生确认卡模型（纯逻辑 + 单测）

**Files:**
- Create: `apps/pendingcrew/Sources/Services/CrewLoginIdentity.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/CrewLoginIdentityTests.swift`
- Modify: `apps/pendingcrew/project.yml`（test bundle source 列表加这两个文件 + 它依赖的 FamilyCredentialStore 已在列）

- [ ] **Step 1: 写失败测试**

```swift
// CrewLoginIdentityTests.swift
import XCTest
@testable import PendingCrew

final class CrewLoginIdentityTests: XCTestCase {
    func testFromCredentialWithProfile() {
        let id = CrewLoginIdentity(credential: FamilyCredential(
            token: "pfa", subjectId: "s", displayName: "阿狸", avatarSeed: "seed"))
        XCTAssertEqual(id.title, "阿狸")
        XCTAssertEqual(id.avatarSeed, "seed")
        XCTAssertFalse(id.isGeneric)
    }
    func testFromCredentialWithoutProfileFallsBackGeneric() {
        let id = CrewLoginIdentity(credential: FamilyCredential(token: "pfa", subjectId: "s"))
        XCTAssertEqual(id.title, "本机 PendingBot 账号")   // 通用降级文案
        XCTAssertEqual(id.avatarSeed, "s")                   // 头像 seed 退化到 subjectId
        XCTAssertTrue(id.isGeneric)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CrewLoginIdentityTests 2>&1 | tail -20`
Expected: 编译失败（`CrewLoginIdentity` 未定义）。

- [ ] **Step 3: 实现**

```swift
// apps/pendingcrew/Sources/Services/CrewLoginIdentity.swift
import Foundation

/// 确认卡展示模型 —— 从共享 keychain 的家族凭据派生。profile 缺失时降级到
/// 通用文案 + 用 subjectId 当头像 seed（mint 成功后 CrewStore.refreshSubjects
/// 会用 /v1/me/subject 的真实 display_name 回填真身份）。
struct CrewLoginIdentity: Equatable {
    let title: String
    let avatarSeed: String
    let isGeneric: Bool

    init(credential: FamilyCredential) {
        if let name = credential.displayName, !name.isEmpty {
            self.title = name
            self.avatarSeed = credential.avatarSeed ?? credential.subjectId
            self.isGeneric = false
        } else {
            self.title = "本机 PendingBot 账号"
            self.avatarSeed = credential.avatarSeed ?? credential.subjectId
            self.isGeneric = true
        }
    }

    /// nil = 共享组无凭据（不显示确认卡）。
    static func current() -> CrewLoginIdentity? {
        FamilyCredentialStore.get().map(CrewLoginIdentity.init)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CrewLoginIdentityTests 2>&1 | tail -20`
Expected: PASS（2 测试）。

- [ ] **Step 5: 提交**

```bash
git add apps/pendingcrew/Sources/Services/CrewLoginIdentity.swift \
        apps/pendingcrew/Tests/PendingCrewTests/CrewLoginIdentityTests.swift \
        apps/pendingcrew/project.yml
git commit -m "feat(pendingcrew): CrewLoginIdentity 确认卡展示模型 + 单测"
```

---

## Task 5: `AccountConfirmCard` 视图（头像 + 账号 + 继续/换号）

**Files:**
- Create: `apps/pendingcrew/Sources/Views/AccountConfirmCard.swift`

- [ ] **Step 1: 实现卡片（build-verify，不单测 SwiftUI）**

用已有的 vendored `BotAvatar`（`apps/pendingcrew/Sources/Chat/Vendored/BotAvatar.swift`）+ `Theme`。`onContinue`/`onUseOther` 回调由父视图注入（父视图负责 mint）。

```swift
// apps/pendingcrew/Sources/Views/AccountConfirmCard.swift
import SwiftUI

/// 同发布者「确认登录」卡：检测到本机 PendingBot 已登录时显示。
/// 头像 + 账号名 + 「继续使用此账号」（→ 家族 SSO mint）+ 「换其它账号」（→ 登录页）。
struct AccountConfirmCard: View {
    let identity: CrewLoginIdentity
    var isBusy: Bool
    var onContinue: () -> Void
    var onUseOther: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            BotAvatar(seed: identity.avatarSeed, size: 72)   // 复用 vendored 头像系统
            VStack(spacing: 4) {
                Text(identity.title)
                    .font(Theme.Fonts.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("已在本机登录 PendingBot")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Button(action: onContinue) {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(isBusy ? "正在登录…" : "继续使用此账号")
                }
                .frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            Button("换其它账号", action: onUseOther)
                .buttonStyle(.plain)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.accent)
                .disabled(isBusy)
        }
        .padding(28)
        .frame(maxWidth: 360)
    }
}
```

> 若 `BotAvatar` 的 init 签名不是 `(seed:size:)`，按其真实签名调整（执行时读 `BotAvatar.swift` 确认；它是 vendored 自 PendingBot 的确定性头像组件）。

- [ ] **Step 2: 编译验证（Mac + iPad）**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -5`
Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: 两端 `BUILD SUCCEEDED`。

- [ ] **Step 3: 提交**

```bash
git add apps/pendingcrew/Sources/Views/AccountConfirmCard.swift
git commit -m "feat(pendingcrew): AccountConfirmCard 同发布者确认卡"
```

---

## Task 6: iPad gate 接确认卡 + LoginView 视觉对齐

**Files:**
- Modify: `apps/pendingcrew/Sources/Views/WelcomeView.swift`
- Modify: `apps/pendingcrew/Sources/Views/LoginView.swift`（视觉对齐 PendingBot：BrandMark + Theme palette；逻辑不动——保留扫码 + 家族 SSO 按钮）

- [ ] **Step 1: WelcomeView 改成「确认卡优先」**

`WelcomeView` 持本地 `@State private var showingLogin = false` + `@State private var minting = false`，`@EnvironmentObject var model: AppModel`。body：

```swift
var body: some View {
    Group {
        if let identity = CrewLoginIdentity.current(), !showingLogin {
            AccountConfirmCard(
                identity: identity,
                isBusy: minting,
                onContinue: {
                    minting = true
                    Task {
                        let ok = await model.tryFamilySSO()   // 已存在
                        minting = false
                        if !ok { showingLogin = true }        // 凭据失效 → 落登录页
                    }
                },
                onUseOther: { showingLogin = true }
            )
        } else {
            LoginView()      // 现有扫码 + 家族 SSO 页（P2 会被 CrewWelcomeView 取代）
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

> `WelcomeView` 现有签名是 `var onLogin: () -> Void`（被 RootView 用作切到 LoginView 的触发）。本任务把它自包含化：删掉 `onLogin`，内部用 `showingLogin` 自管；RootView 相应简化（见 Step 2）。

- [ ] **Step 2: RootView 简化**

`apps/pendingcrew/Sources/PendingCrewApp.swift` 的 `RootView` 里 `!isConfigured` 分支当前是 `switch flow { case .welcome: WelcomeView { flow = .login }; case .login: LoginView() }`。改成直接 `WelcomeView()`（WelcomeView 内部自管确认卡↔登录页切换），删掉 `flow` 状态 + `Flow` 枚举。`.onChange(of: model.isConfigured)` 里清 `flow` 的逻辑一并删。

- [ ] **Step 3: LoginView 视觉对齐**

把 LoginView 的 `header` 从 SF Symbol 换成 `Image("BrandMark")`（PendingCrew Assets 若无 BrandMark，执行时确认资源名；退化保留 symbol 也可），文案/按钮配色走 `Theme.Palette`。**逻辑零改**（扫码 + 家族 SSO 流程不动）。

- [ ] **Step 4: 编译验证（Mac + iPad）**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: 两端 `BUILD SUCCEEDED`。

- [ ] **Step 5: 提交**

```bash
git add apps/pendingcrew/Sources/Views/WelcomeView.swift apps/pendingcrew/Sources/Views/LoginView.swift apps/pendingcrew/Sources/PendingCrewApp.swift
git commit -m "feat(pendingcrew): iPad 登录 gate 接确认卡 + LoginView 视觉对齐"
```

---

## Task 7: Mac 侧栏登录入口弹 sheet（确认卡 / LoginView）

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/MacRootView.swift`（或承载侧栏「登录」入口的视图——执行时 grep `tryFamilySSO`/`familySSOAvailable`/「登录」定位现有入口）

- [ ] **Step 1: 定位现有 Mac 登录入口**

Run: `grep -rn "tryFamilySSO\|familySSOAvailable\|用本机 PendingBot\|登录" apps/pendingcrew/Sources/Mac 2>/dev/null | head -20`
确认当前 Mac 上「登录」入口在哪个视图、长什么样（侧栏身份区菜单项）。

- [ ] **Step 2: 入口改为弹 sheet**

入口点击设 `@State private var showingLogin = false` → `.sheet(isPresented:)` 内：有家族凭据 → `AccountConfirmCard`（继续 = `model.tryFamilySSO()`，换号 = sheet 内切到 `LoginView`）；无凭据 → 直接 `LoginView`。登录成功（`model.isAuthenticated` 翻 true）后 `.onChange` 关闭 sheet。保持「登录是显式动作、不在启动静默 mint」——sheet 只在用户点入口时出现。

```swift
.sheet(isPresented: $showingLogin) {
    CrewLoginSheet(onDone: { showingLogin = false })   // 内部含确认卡↔LoginView 切换
        .frame(minWidth: 420, minHeight: 480)
}
```
（`CrewLoginSheet` 是个薄包装，逻辑同 Task 6 的 WelcomeView；可抽共享。若想省一个类型，直接在 sheet 里复用 `WelcomeView()`。）

- [ ] **Step 3: 编译验证（Mac）**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 提交**

```bash
git add apps/pendingcrew/Sources/Mac/Views/MacRootView.swift
git commit -m "feat(pendingcrew): Mac 侧栏登录入口弹确认卡/登录 sheet"
```

---

## Task 8: P1 整体验证 + 账本

- [ ] **Step 1: 全量编译 + 测试**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | tail -15`（PendingCrewTests 全过）
Run: iPad build（Task 6 Step 4 命令）。
Run: `cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build 2>&1 | tail -5` + iOS build。
Run: `bun --filter='@pendingbot/edge' run typecheck 2>&1 | tail -5`。

- [ ] **Step 2: 真机尾巴记 tech-debt**

`docs/tech-debt.md` 追加：① 共享 keychain 跨 app 真读（两个 Apple Development 签名 app）；② 确认卡端到端（Mac + iPad）；③ headless/ad-hoc 构建下 `-34018` 已知必失败。标注「需 Xcode GUI / 真机验，骨架 task 不提前关」。

- [ ] **Step 3: 账本 + 提交**

更新 `docs/progress.md` 顶部「最近对账」日期 + 本工作流状态。提交 docs。

---

# Phase 2 — 完整直接登录栈（Apple/Google/邮箱）

> **顺序约束：** 本阶段落地前**不要**移除/隐藏扫码路径（D3）。P2 完成后扫码作为第三胶囊保留。

## Task 9: PendingCrew SPM 依赖 + 配置面

**Files:**
- Modify: `apps/pendingcrew/project.yml`（加 Supabase + GoogleSignIn 依赖；Info.plist 加 GIDClientID + URL scheme）
- Create: `apps/pendingcrew/Sources/Services/CrewHostedConfig.swift`

- [ ] **Step 1: project.yml 加依赖**

`packages:` 加（版本对齐 PendingBot）：
```yaml
  Supabase:
    url: https://github.com/supabase/supabase-swift
    minVersion: 2.0.0
    maxVersion: 3.0.0
  GoogleSignIn:
    url: https://github.com/google/GoogleSignIn-iOS
    minVersion: 8.0.0
    maxVersion: 9.0.0
```
`targets.PendingCrew.dependencies:` 加 `- package: Supabase` + `- package: GoogleSignIn`。

- [ ] **Step 2: CrewHostedConfig（镜像 PendingBot 取值）**

```swift
// apps/pendingcrew/Sources/Services/CrewHostedConfig.swift
import Foundation
enum CrewHostedConfig {
    static let supabaseURL = URL(string: "https://zafhoiwwpanpuashtnxy.supabase.co")!
    static let supabasePublishableKey = "<对齐 PendingBot HostedConfig.environment.supabasePublishableKey>"
    static let turnstileSiteKey = "<对齐 PendingBot HostedConfig.environment.turnstileSiteKey>"
    static let turnstileHost = URL(string: "https://pendingname.com")!  // 对齐 PendingBot turnstileHost
}
```
> 执行时从 `apps/pendingbot/.../HostedConfig*.swift` 抄实际值（`.remote` 环境）。

- [ ] **Step 3: Info.plist 加 GIDClientID + reversed URL scheme**

`apps/pendingcrew/Info.plist` 加 `GIDClientID`（= PendingCrew 在 Google Cloud Console 的 iOS Client ID，bundle id `com.pendingname.pendingcrew`）+ `CFBundleURLTypes` 加 reversed client id scheme。

> **人工尾巴：** Google Cloud Console 要为 `com.pendingname.pendingcrew` 建一个新的 iOS OAuth Client ID，并把它加进 Supabase Auth → Google → Authorized Client IDs。记 tech-debt（需 user 在 console 操作）。

- [ ] **Step 4: xcodegen + 编译**

Run: `cd apps/pendingcrew && xcodegen && xcodebuild -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -8`
Expected: 依赖解析 + `BUILD SUCCEEDED`。

- [ ] **Step 5: 提交**

```bash
git add apps/pendingcrew/project.yml apps/pendingcrew/Info.plist apps/pendingcrew/Sources/Services/CrewHostedConfig.swift
git commit -m "feat(pendingcrew): 加 Supabase/GoogleSignIn 依赖 + CrewHostedConfig"
```

---

## Task 10: 内存态 Supabase 栈（session 不落 keychain）

**Files:**
- Create: `apps/pendingcrew/Sources/Services/InMemoryAuthStorage.swift`
- Create: `apps/pendingcrew/Sources/Services/CrewSupabaseStack.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/InMemoryAuthStorageTests.swift`
- Modify: `apps/pendingcrew/project.yml`（test bundle 加 InMemoryAuthStorage —— 但它依赖 supabase-swift 的 `AuthLocalStorage` 协议；若 test bundle 不便链 Supabase，则把协议方法用一个不依赖 Supabase 的内层 dict 类承载并测内层）

- [ ] **Step 1: 写失败测试（测内存 dict 语义，不依赖 Supabase 类型）**

```swift
// InMemoryAuthStorageTests.swift
import XCTest
@testable import PendingCrew

final class InMemoryAuthStorageTests: XCTestCase {
    func testStoreRetrieveRemove() throws {
        let s = InMemoryKeyValueStore()
        XCTAssertNil(s.get("k"))
        s.set("k", Data("v".utf8))
        XCTAssertEqual(s.get("k"), Data("v".utf8))
        s.remove("k")
        XCTAssertNil(s.get("k"))
    }
}
```

- [ ] **Step 2: 跑确认失败**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/InMemoryAuthStorageTests 2>&1 | tail -15`
Expected: 编译失败（`InMemoryKeyValueStore` 未定义）。

- [ ] **Step 3: 实现内存存储 + AuthLocalStorage 适配**

```swift
// apps/pendingcrew/Sources/Services/InMemoryAuthStorage.swift
import Foundation
import Supabase   // for AuthLocalStorage

/// 纯内存 KV（可单测，不依赖 Supabase 类型）。
final class InMemoryKeyValueStore: @unchecked Sendable {
    private var dict: [String: Data] = [:]
    private let lock = NSLock()
    func get(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return dict[key] }
    func set(_ key: String, _ value: Data) { lock.lock(); defer { lock.unlock() }; dict[key] = value }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; dict[key] = nil }
}

/// supabase-swift 的 AuthLocalStorage —— 内存实现。session 永不落 keychain/磁盘，
/// 进程退出即蒸发；PendingCrew 直接登录只需短暂持有 session 调一次
/// /v1/me/family-credential，用完 signOut。
struct InMemoryAuthStorage: AuthLocalStorage {
    let backing: InMemoryKeyValueStore
    func store(key: String, value: Data) throws { backing.set(key, value) }
    func retrieve(key: String) throws -> Data? { backing.get(key) }
    func remove(key: String) throws { backing.remove(key) }
}
```

```swift
// apps/pendingcrew/Sources/Services/CrewSupabaseStack.swift
import Foundation
import Supabase

/// PendingCrew 专用 Supabase client —— **内存态 auth storage**，session 不持久化。
/// 仅用于直接登录路径（Apple/Google/邮箱）拿一次性 session 兑换家族凭据。
enum CrewSupabaseStack {
    static let shared: SupabaseClient = {
        SupabaseClient(
            supabaseURL: CrewHostedConfig.supabaseURL,
            supabaseKey: CrewHostedConfig.supabasePublishableKey,
            options: SupabaseClientOptions(
                db: SupabaseClientOptions.DatabaseOptions(schema: "pendingbot"),
                auth: SupabaseClientOptions.AuthOptions(
                    storage: InMemoryAuthStorage(backing: InMemoryKeyValueStore())
                )
            )
        )
    }()
}
```
> 执行时核对 supabase-swift 当前版本 `AuthLocalStorage` 协议方法签名（`store/retrieve/remove`）—— 跟随官方类型，不凭印象（见 memory「接入服务必查官方文档」）。

- [ ] **Step 4: 跑测试通过 + 编译**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/InMemoryAuthStorageTests 2>&1 | tail -15`
Expected: PASS。
（若 test bundle 链 Supabase 困难：把 `InMemoryKeyValueStore` 单列进 test bundle，`InMemoryAuthStorage`/`CrewSupabaseStack` 只进 app target；测试只测 `InMemoryKeyValueStore`。）

- [ ] **Step 5: 提交**

```bash
git add apps/pendingcrew/Sources/Services/InMemoryAuthStorage.swift apps/pendingcrew/Sources/Services/CrewSupabaseStack.swift apps/pendingcrew/Tests/PendingCrewTests/InMemoryAuthStorageTests.swift apps/pendingcrew/project.yml
git commit -m "feat(pendingcrew): 内存态 Supabase 栈(session 不落盘)"
```

---

## Task 11: PendingCrewAPI 加 `issueFamilyCredential(accessToken:)`

**Files:**
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift`

- [ ] **Step 1: 加方法（session bearer 调 /v1/me/family-credential）**

仿现有 `mintGrant`/`createDeviceLoginChallenge` 的请求风格，新增：

```swift
struct CrewFamilyCredentialResponse: Decodable {
    struct Cred: Decodable { let token: String; let subjectId: String }
    let familyCredential: Cred
    let displayName: String?
}

func issueFamilyCredential(accessToken: String, deviceName: String = currentDeviceName()) async throws -> CrewFamilyCredentialResponse {
    struct Body: Encodable { let deviceName: String }
    // POST /v1/me/family-credential，Authorization: Bearer <accessToken>（session JWT）
    return try await postAuthed(path: "v1/me/family-credential", bearer: accessToken, body: Body(deviceName: deviceName))
}
```
> `postAuthed`：若现有 client 没有「带任意 bearer」的 POST helper，加一个（仿现有 `mintGrant` 里设 Authorization header 的写法）。错误走现有 `PendingCrewAPIError`。

- [ ] **Step 2: 编译验证**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: 提交**

```bash
git add apps/pendingcrew/Sources/Services/PendingCrewAPI.swift
git commit -m "feat(pendingcrew): PendingCrewAPI.issueFamilyCredential(session bearer)"
```

---

## Task 12: `CrewLoginExchange` — session→pfa_→mint→signOut 编排（TDD）

**Files:**
- Create: `apps/pendingcrew/Sources/Services/CrewLoginExchange.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/CrewLoginExchangeTests.swift`
- Modify: `apps/pendingcrew/project.yml`（test bundle 加这俩 + 依赖）

- [ ] **Step 1: 写失败测试（mock 注入，验证顺序 + teardown 必跑 + grant 落地）**

```swift
// CrewLoginExchangeTests.swift
import XCTest
@testable import PendingCrew

final class CrewLoginExchangeTests: XCTestCase {
    func testHappyPathMintsGrantThenTearsDownSession() async throws {
        var savedGrant: String?
        var savedFamily: FamilyCredential?
        var teardownCalled = false
        let exchange = CrewLoginExchange(
            issueFamily: { token in
                XCTAssertEqual(token, "jwt-123")
                return .init(token: "pfa_x", subjectId: "sid", displayName: "阿狸")
            },
            mintGrant: { fam, sid in
                XCTAssertEqual(fam, "pfa_x"); XCTAssertEqual(sid, "sid")
                return "pdg_ok"
            },
            saveGrant: { savedGrant = $0 },
            saveFamily: { savedFamily = $0 },
            teardown: { teardownCalled = true }
        )
        try await exchange.run(accessToken: "jwt-123")
        XCTAssertEqual(savedGrant, "pdg_ok")
        XCTAssertEqual(savedFamily?.token, "pfa_x")
        XCTAssertEqual(savedFamily?.displayName, "阿狸")
        XCTAssertTrue(teardownCalled, "session 必须在兑换后被清")
    }

    func testTeardownRunsEvenWhenMintFails() async {
        var teardownCalled = false
        let exchange = CrewLoginExchange(
            issueFamily: { _ in .init(token: "pfa_x", subjectId: "sid", displayName: nil) },
            mintGrant: { _, _ in throw CrewLoginExchange.Failure.mintFailed },
            saveGrant: { _ in XCTFail("不该存 grant") },
            saveFamily: { _ in },
            teardown: { teardownCalled = true }
        )
        do { try await exchange.run(accessToken: "jwt") ; XCTFail("应抛错") }
        catch {}
        XCTAssertTrue(teardownCalled, "失败路径也必须清 session（不留全权 session）")
    }
}
```

- [ ] **Step 2: 跑确认失败**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CrewLoginExchangeTests 2>&1 | tail -20`
Expected: 编译失败（`CrewLoginExchange` 未定义）。

- [ ] **Step 3: 实现（依赖全注入，纯编排）**

```swift
// apps/pendingcrew/Sources/Services/CrewLoginExchange.swift
import Foundation

/// 直接登录兑换：临时 session 的 access token → 家族凭据 pfa_ → mint pdg_ →
/// 写共享组 + 存 grant → 清 session（defer 保证失败也清）。
struct CrewLoginExchange {
    struct FamilyResult { let token: String; let subjectId: String; let displayName: String? }
    enum Failure: Error { case mintFailed }

    var issueFamily: (_ accessToken: String) async throws -> FamilyResult
    var mintGrant: (_ familyToken: String, _ subjectId: String) async throws -> String  // pdg_
    var saveGrant: (String) throws -> Void
    var saveFamily: (FamilyCredential) -> Void
    var teardown: () async -> Void

    func run(accessToken: String) async throws {
        // 无论成败，出口都清 session —— 守住「不持久化全权 session」。
        defer { Task { await teardown() } }
        do {
            let fam = try await issueFamily(accessToken)
            saveFamily(FamilyCredential(token: fam.token, subjectId: fam.subjectId, displayName: fam.displayName))
            let grant = try await mintGrant(fam.token, fam.subjectId)
            try saveGrant(grant)
        } catch {
            throw error
        }
    }
}
```
> `defer { Task { await teardown() } }` 在同步退出点调度清理；若要严格「await 完才返回」，把 teardown 改成同步关 + 之后再 await（执行时按 supabase-swift signOut 是否需 await 决定；测试用同步 flag 验证即可）。
>
> 生产装配（在视图/协调器里，把 Task 11 的 `CrewFamilyCredentialResponse` 显式映射成 `FamilyResult`）：
>
> ```swift
> let api = PendingCrewAPI(baseURL: URL(string: model.apiBaseURL)!)
> let exchange = CrewLoginExchange(
>     issueFamily: { token in
>         let r = try await api.issueFamilyCredential(accessToken: token)
>         return .init(token: r.familyCredential.token, subjectId: r.familyCredential.subjectId, displayName: r.displayName)
>     },
>     mintGrant: { fam, sid in
>         let resp = try await api.mintGrant(familyCredential: fam, subjectId: sid,
>             grantKind: "pendingcrew_control",
>             scopes: ["subject:read","crew:read","crew:write","runner:read","runner:write"])
>         guard let token = resp.deviceGrantToken else { throw CrewLoginExchange.Failure.mintFailed }
>         return token
>     },
>     saveGrant: { try model.saveDeviceGrantToken($0) },
>     saveFamily: { FamilyCredentialStore.set($0) },
>     teardown: { try? await CrewSupabaseStack.shared.auth.signOut(scope: .local) }
> )
> ```
> （`mintGrant` 的 scopes 与现有 `AppModel.tryFamilySSO` 完全一致，保持单一来源。）

- [ ] **Step 4: 跑测试通过**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CrewLoginExchangeTests 2>&1 | tail -20`
Expected: PASS（2 测试）。

- [ ] **Step 5: 提交**

```bash
git add apps/pendingcrew/Sources/Services/CrewLoginExchange.swift apps/pendingcrew/Tests/PendingCrewTests/CrewLoginExchangeTests.swift apps/pendingcrew/project.yml
git commit -m "feat(pendingcrew): CrewLoginExchange 兑换编排 + TDD(失败也清 session)"
```

---

## Task 13: Vendor 登录栈（EmailSignIn/AppleSignIn/GoogleSignIn/Turnstile/WelcomeViewModel）

**Files:**
- Create: `apps/pendingcrew/Sources/Auth/CrewEmailSignIn.swift`、`CrewAppleSignIn.swift`、`CrewGoogleSignIn.swift`、`CrewTurnstileWebView.swift`、`CrewWelcomeViewModel.swift`（vendor 自 PendingBot 对应文件）

- [ ] **Step 1: 复制 + repoint**

逐个复制 PendingBot 源文件到上述路径，做**确定的机械改动**：
- 全部 `SupabaseStack.shared` → `CrewSupabaseStack.shared`。
- `HostedConfig.environment.turnstileSiteKey/turnstileHost` → `CrewHostedConfig.turnstileSiteKey/turnstileHost`。
- 类型重命名避免与未来共享冲突：`enum EmailSignIn`→`CrewEmailSignIn`、`enum PendingGoogleSignIn`→`CrewGoogleSignIn`、`AppleSignIn`→`CrewAppleSignIn`、`final class WelcomeViewModel`→`CrewWelcomeViewModel`、`struct TurnstileWebView`→`CrewTurnstileWebView`。
- `CrewWelcomeViewModel` 的 `beginApple/beginGoogle/verifyCode` 成功分支：**不再依赖 AccountStore**；改为拿到 `Session` 后取 `session.accessToken` 交给注入的 `onAuthenticated: (String) async -> Void` 回调（由视图装配成 `CrewLoginExchange.run`）。即 VM 只负责拿 token，兑换在 exchange。
- `Haptics` 若 PendingCrew 无对应实现，复用 vendored `apps/pendingcrew/Sources/Chat/Vendored/Haptics.swift`（已存在）。

- [ ] **Step 2: 编译验证（Mac + iPad）**

Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -8`
Run: `cd apps/pendingcrew && xcodebuild -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -8`
Expected: 两端 `BUILD SUCCEEDED`（GoogleSignIn macOS target + iOS 都链上）。

- [ ] **Step 3: 提交**

```bash
git add apps/pendingcrew/Sources/Auth/
git commit -m "feat(pendingcrew): vendor 登录栈(email/apple/google/turnstile/VM)→内存兑换"
```

---

## Task 14: Vendor Welcome 渲染层 + 接「换其它账号」

**Files:**
- Create: `apps/pendingcrew/Sources/Views/CrewWelcomeView.swift`（iPad，vendor 自 PendingBot `WelcomeView`）
- Create: `apps/pendingcrew/Sources/Mac/Views/CrewMacWelcomeView.swift`（Mac，vendor 自 PendingBot `MacWelcomeView`）
- Modify: `apps/pendingcrew/Sources/Views/WelcomeView.swift`、`apps/pendingcrew/Sources/Mac/Views/MacRootView.swift`（「换其它账号」目标从旧 LoginView → 新 Crew*WelcomeView）

- [ ] **Step 1: 复制渲染层 + repoint VM + 扫码胶囊接现有 device-login**

复制 PendingBot 的 `WelcomeView`（iOS）→ `CrewWelcomeView`、`MacWelcomeView`（含 `PendingBotMacQRLoginView`、`MacLoginWindowStyler`、`MacTurnstileWebView`）→ `CrewMacWelcomeView`，机械改动：
- `@StateObject private var vm = WelcomeViewModel()` → `CrewWelcomeViewModel()`，装配 `onAuthenticated = { token in try await CrewLoginExchange(...).run(accessToken: token) }`（构造见 Task 12 Step 3）。
- `TurnstileWebView`/`MacTurnstileWebView` → `CrewTurnstileWebView`（iPad）/ 复用 vendored Mac twin。
- **扫码胶囊**：Mac 的 `PendingBotMacQRLoginView`（出 `pendingbot_macos` 码、换 session）**替换**为 PendingCrew 的扫码（复用现有 `LoginView` 的 device-login 逻辑：出 `pendingcrew_macos` 码、轮询拿 `pdg_`）。抽一个 `CrewQRLoginView` 承载现有 LoginView 的扫码流程，嵌进胶囊位。
- `Image("BrandMark")` → PendingCrew 的品牌资源（确认 Assets 名）。

- [ ] **Step 2: 把「换其它账号」目标切到新页**

Task 6 的 `WelcomeView` 与 Task 7 的 Mac sheet 里，`showingLogin == true` 分支从旧 `LoginView()` 改为 `CrewWelcomeView()`（iPad）/ `CrewMacWelcomeView()`（Mac）。旧 `LoginView.swift` 的扫码逻辑已被 `CrewQRLoginView` 吸收后即可删除（连同 RootView 里残余引用）。

- [ ] **Step 3: 编译验证（Mac + iPad）**

Run: macOS build + iOS Simulator build（同 Task 13 Step 2）。
Expected: 两端 `BUILD SUCCEEDED`。

- [ ] **Step 4: 提交**

```bash
git add apps/pendingcrew/Sources/Views/CrewWelcomeView.swift apps/pendingcrew/Sources/Mac/Views/CrewMacWelcomeView.swift apps/pendingcrew/Sources/Views/WelcomeView.swift apps/pendingcrew/Sources/Mac/Views/MacRootView.swift
git rm apps/pendingcrew/Sources/Views/LoginView.swift   # 若扫码已迁入 CrewQRLoginView
git commit -m "feat(pendingcrew): 搬来完整登录页(Apple/Google/邮箱/扫码)接内存兑换"
```

---

## Task 15: P2 整体验证 + 真机尾巴 + 账本

- [ ] **Step 1: 全量编译 + 测试**

Run: PendingCrew macOS `test`（全 PendingCrewTests 过）+ iPad build；PendingBot iOS/macOS build；`bun --filter='@pendingbot/edge' run typecheck`。

- [ ] **Step 2: GUI 冒烟（Xcode 构建装模拟器/本机）**

按 memory「iOS 改完进模拟器验证」+「模拟器没签名→Keychain -34018」：用 **Xcode GUI 正常签名**构建装机，走一遍：① 有家族凭据 → 确认卡显示头像+账号 → 继续登录拿 grant；② 换其它账号 → Apple/Google/邮箱 各通一遍 → 兑换出 `pdg_` → 进主界面；③ 扫码 → 手机 PendingBot 识别为 "PendingCrew" → 批准 → grant；④ 验证登录后 PendingCrew keychain 里**只有 `pdg_`、无 Supabase session token**（fail-loud 断言 + 手查）。headless/ad-hoc 构建会 `-34018`，不作数。

- [ ] **Step 3: 真机尾巴 + 账本**

`docs/tech-debt.md`：Google Cloud Console 新建 PendingCrew iOS Client ID + Supabase Authorized Client IDs（需 user）；R1 Port-Full 双依赖；R2 appKind 无 iPad 变体（iPad 复用 `pendingcrew_macos`）；R3 iOS 写凭据扩面。更新 `docs/progress.md`。提交 docs。

---

## 验证矩阵（汇总）

| 验证 | 命令 / 方式 | 阶段 |
|---|---|---|
| PendingCrew 单测 | `xcodebuild -scheme PendingCrew -destination 'platform=macOS' test` | P1/P2 |
| PendingCrew 编译 | macOS + `generic/platform=iOS Simulator` build | 每 task |
| PendingBot 编译 | iOS + macOS build | Task 2 |
| Edge typecheck | `bun --filter='@pendingbot/edge' run typecheck` | Task 3 |
| 共享 keychain 跨 app | Xcode GUI 正常签名，两 app 真读 | 真机尾巴 |
| 三登录路径 E2E | GUI 冒烟（确认卡/Apple/Google/邮箱/扫码） | 真机尾巴 |
| session 不落盘 | fail-loud 断言 + keychain 手查 | 真机尾巴 |

## 风险 / tech-debt（执行时落 docs/tech-debt.md）

- **R1** Port-Full 给 PendingCrew 引入 supabase-swift + GoogleSignIn 两个重依赖（仅为一次性 session）。
- **R2** `AppKind` 无 iPad 变体，iPad 复用 `pendingcrew_macos`（命名漂移，逻辑无碍）。
- **R3** PendingBot iOS 也写家族凭据 → iPhone-only 用户也落 `pfa_`（可撤销/90 天过期，可接受）。
- **R4** 人工尾巴：共享 keychain 真机验、OAuth 全链路、Google Console + Supabase client id 配置（需 user）。
