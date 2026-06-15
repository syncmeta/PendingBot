# 清除本机所有数据 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 PendingBot 与 PendingCrew 设置里各加「清除本机所有数据」破坏性选项;PendingCrew 顺带删除死的 BYOK provider-key 脚手架。

**Architecture:** 每个 app 一个 `LocalDataReset` 协调器,集中调用各自的 keychain/缓存/UserDefaults/文件清除原语;共享登录状态按 keychain presence 决定弹"保留/一并清除"二选一还是直接清。post-wipe:macOS 重启 app,iOS 原地回登录。

**Tech Stack:** Swift / SwiftUI、Keychain(SecItem)、SQLCipher(PendingBot LocalDatabase)、supabase-swift、NSWorkspace/NSApp(macOS 重启)。

**Spec:** `docs/superpowers/specs/2026-06-15-reset-local-data-design.md`

**Verification model:** 这些是带副作用的平台 API(keychain/文件系统/重启/SwiftUI),无自然单测面。每个 task 的验证 = 编译通过 + 关键路径人工实跑。

---

## File Structure

**PendingCrew(`apps/pendingcrew/Sources/`):**
- 删 `Stores/BYOKConfig.swift`
- 改 `Stores/AppModel.swift`(去 BYOK)、`Mac/Views/LocalSetupView.swift`(去 key 字段)、`Support/PendingCrewAuthCredential.swift`(去 `case byok`)、`Views/WelcomeView.swift`(陈旧文案)
- 新 `Stores/LocalDataReset.swift`(协调器)
- 改 `Mac/Views/CrewSettingsView.swift`(危险区入口)

**PendingBot(`apps/pendingbot/Sources/`):**
- 新 `Storage/LocalDataReset.swift`(协调器)
- 改 `Features/Me/MeTabView.swift`(危险区入口 + 确认流程)

**文档:** `docs/tech-debt.md`(BYOK 命名漂移)、roadmap/progress 视情况。

---

## Task 1: PendingCrew — 删死 BYOK provider-key 路径

**Files:**
- Delete: `apps/pendingcrew/Sources/Stores/BYOKConfig.swift`
- Modify: `apps/pendingcrew/Sources/Stores/AppModel.swift`
- Modify: `apps/pendingcrew/Sources/Mac/Views/LocalSetupView.swift`
- Modify: `apps/pendingcrew/Sources/Support/PendingCrewAuthCredential.swift`
- Modify: `apps/pendingcrew/Sources/Views/WelcomeView.swift`

- [ ] **Step 1: 删 BYOKConfig.swift** —— `git rm apps/pendingcrew/Sources/Stores/BYOKConfig.swift`

- [ ] **Step 2: AppModel.swift 去 BYOK**
  - 删 `@Published private(set) var byokConfig` 属性 + 其 doc。
  - init 里删 BYOK 加载段(`let loadedByok ...` / `self.byokConfig = ...`);`localModeSelected` 改为 `self.localModeSelected = cred == nil && defaults.bool(forKey: DefaultsKey.localModeSelected)`。
  - `saveDeviceGrantToken` 里删 `if credential != nil { BYOKConfig.clear(); byokConfig = nil }` 整块(改成无操作,token 写完即可)。
  - 删 `saveByokConfig(_:)`、`clearByokConfig()` 两个方法。
  - 删 `KeychainAccount.byokAnthropic/byokOpenAI/byokGemini` 三个常量。
  - 保留 `enterLocalMode()`、`localModeSelected`、`DefaultsKey.localModeSelected` 不动。

- [ ] **Step 3: LocalSetupView.swift 去 key 字段**
  - 删三个 `@State ... Key` 属性、`.task { BYOKConfig.load() ... }` 回填、`form` 里三个 `keyField` 与说明文案、`keyField(...)` 辅助、`save()` 里 `BYOKConfig(...)` 构造 + `model.saveByokConfig`(连同 `trimNil`)。
  - `save()` 简化为:`saving = true; model.enterLocalMode(); saving = false`(或直接让按钮调 `model.enterLocalMode()`)。header 文案保留(已是"无需 key"),去掉"未来 API-key 额度池"那段。

- [ ] **Step 4: PendingCrewAuthCredential.swift 去死 case**
  - 删 `enum Kind` 里的 `case byok`,doc 里删 byok 那条。enum 只剩 `case deviceGrant`。

- [ ] **Step 5: WelcomeView.swift 陈旧文案**
  - footnote(macOS 分支)与顶部 doc 里提"BYOK key / 凭据自己 own / 填 SecureField"的句子改成"本机模式:驱动本机已登录的 claude/codex,无需 key"。`Choice.localSetup` 名保留。

- [ ] **Step 6: 编译验证**
  - Run: `cd apps/pendingcrew && bash -lc 'xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination "platform=macOS" build 2>&1 | tail -20'`(若 project.yml 变动先 `xcodegen`;本 task 不动 project.yml)
  - Expected: BUILD SUCCEEDED,无 BYOK 残留报错。

- [ ] **Step 7: Commit**
  - `git add -A apps/pendingcrew/Sources && git commit -m "chore(pendingcrew): 删死 BYOK provider-key 路径(零消费/零调用)"`

---

## Task 2: tech-debt 记 BYOK 命名漂移

**Files:** Modify `docs/tech-debt.md`

- [ ] **Step 1:** 追加一条 🟢 条目:PendingCrew 里 "BYOK" 已是"本地模式"的过时别名 —— 活的标识符 `local-byok`/`local-byok-user`(已写进本地 JSON 存档)、machine `kind:"byok"`、`notSupportedInByok` 错误 case、大量注释仍用 BYOK 命名。改名需对持久化 id 做数据迁移,故延后;记录以免后人误读。
- [ ] **Step 2: Commit** —— `git add docs/tech-debt.md && git commit -m "chore(docs): tech-debt 记 BYOK→本地模式 命名漂移"`

---

## Task 3: PendingCrew — LocalDataReset + 设置入口

**Files:**
- Create: `apps/pendingcrew/Sources/Stores/LocalDataReset.swift`
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewSettingsView.swift`
- (按需)`apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift` 已含 `get()`/`clear()`,无需改。

- [ ] **Step 1: 写 LocalDataReset.swift**

```swift
import Foundation
import AppKit

/// PendingCrew「清除本机所有数据」协调器。仅本地清除,清完重启 app。
@MainActor
enum LocalDataReset {
    /// 共享登录状态(与 PendingBot 共享)是否存在 —— 决定是否给用户二选一。
    static var sharedLoginPresent: Bool { FamilyCredentialStore.get() != nil }

    /// 执行清除。`clearSharedLogin` 为 true 时连共享登录凭证一并删。
    static func performReset(clearSharedLogin: Bool) {
        // 1. 本 app 登录 token
        KeychainStore.delete(account: KeychainAccount.deviceGrant)
        // 2. 共享登录状态(按用户选择)
        if clearSharedLogin { FamilyCredentialStore.clear() }
        // 3. UserDefaults 整域
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // 4. 本地 crew 数据目录(local-crews / templates / whiteboards / approvals)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = support?.appendingPathComponent("PendingCrew", isDirectory: true) {
            try? FileManager.default.removeItem(at: dir)
        }
        // 5. 重启 app(绕开 isConfigured 恒 true + 内存单例/@State 缓存)
        relaunch()
    }

    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
```

> 注:确认 `KeychainStore.delete` / `KeychainAccount.deviceGrant` / `FamilyCredentialStore.get/clear` 的真实签名(读这几个文件)再落笔;Application Support 子目录名以 `LocalCrewStore` 实际用的为准(读 `LocalCrewStore.swift` 顶部确认是 "PendingCrew")。

- [ ] **Step 2: CrewSettingsView.swift 加危险区**
  - 底部加一个 section,红色按钮「清除本机所有数据」。
  - `@State private var showConfirm = false`。点按钮 → `showConfirm = true`。
  - `.confirmationDialog("清除本机所有数据?此操作不可恢复,仅清除本机。", isPresented: $showConfirm, titleVisibility: .visible)`:
    - 若 `LocalDataReset.sharedLoginPresent`:两个 destructive 按钮 ——
      - `Button("清除(保留与 PendingBot 共享的登录状态)", role: .destructive) { LocalDataReset.performReset(clearSharedLogin: false) }`
      - `Button("清除,并清除与 PendingBot 共享的登录状态", role: .destructive) { LocalDataReset.performReset(clearSharedLogin: true) }`
    - 否则单个:`Button("清除本机所有数据", role: .destructive) { LocalDataReset.performReset(clearSharedLogin: false) }`
    - `Button("取消", role: .cancel) {}`
  - 用现有 Theme/分区样式,不自绘。

- [ ] **Step 3: 编译验证** —— 同 Task 1 Step 6。Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit** —— `git add apps/pendingcrew/Sources && git commit -m "feat(pendingcrew): 清除本机所有数据(LocalDataReset + 设置入口)"`

---

## Task 4: PendingBot — LocalDataReset + 设置入口(独立于 Task 1-3)

**Files:**
- Create: `apps/pendingbot/Sources/Storage/LocalDataReset.swift`
- Modify: `apps/pendingbot/Sources/Features/Me/MeTabView.swift`

- [ ] **Step 1: 先读真实签名** —— 读 `AccountStore.swift`(signOut/signOutLocally、SupabaseStack 用法)、`LocalDatabase.swift`(`wipeForSignOut`)、`Telemetry.swift`(`reset`)、`FamilyCredentialWriter.swift`(`get/clear`,确认 `#if os(macOS)`)、`Keychain.swift`、`ProtectedURLCache`/`AvatarCache`。以真实 API 落笔,别照搬下面伪代码字段名。

- [ ] **Step 2: 写 LocalDataReset.swift**

```swift
import Foundation
#if os(macOS)
import AppKit
#endif

/// PendingBot「清除本机所有数据」协调器。仅本地清除(≠ 注销账号)。
@MainActor
enum LocalDataReset {
    /// 与 PendingCrew 共享的登录状态是否存在(macOS only)。
    static var sharedLoginPresent: Bool {
        #if os(macOS)
        return FamilyCredentialWriter.get() != nil
        #else
        return false
        #endif
    }

    static func performReset(clearSharedLogin: Bool) async {
        Telemetry.shared.reset()
        try? await SupabaseStack.shared.auth.signOut(scope: .local)  // session → nil → gate 回登录
        LocalDatabase.shared.wipeForSignOut()
        URLCache.shared.removeAllCachedResponses()
        #if os(iOS)
        AvatarCache.shared.clear()
        #endif
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        #if os(macOS)
        if clearSharedLogin { FamilyCredentialWriter.clear() }
        relaunch()
        #endif
        // iOS: session 已置空,RootView 自动回登录页;无需重启。
    }

    #if os(macOS)
    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif
}
```

- [ ] **Step 3: MeTabView.swift 加危险区 row**
  - 在已有「退出登录 / 注销账号」破坏性组里加红色 row「清除本机所有数据」。
  - `@State private var showResetConfirm = false`,点 row → true。
  - `.confirmationDialog`:逻辑同 PendingCrew,文案里"另一个 app"= **PendingCrew**;`sharedLoginPresent` 决定二选一 vs 单确认。两个 action 都 `Task { await LocalDataReset.performReset(clearSharedLogin: …) }`。
  - 用现有 `meGlassGroup()` 等样式。

- [ ] **Step 4: 编译验证**
  - Run: `cd apps/pendingbot && bash -lc 'xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination "generic/platform=iOS Simulator" build 2>&1 | tail -20'`
  - Expected: BUILD SUCCEEDED。
  - (再跑一次 `-destination "platform=macOS"` 确认 Mac 分支也过。)

- [ ] **Step 5: Commit** —— `git add apps/pendingbot/Sources && git commit -m "feat(pendingbot): 清除本机所有数据(LocalDataReset + 设置入口)"`

---

## Task 5: 实跑验证 + 账本(需人工)

- [ ] PendingCrew:Xcode GUI 构建运行(headless 回落 ad-hoc 签名会丢会话,验登录态必须 GUI)→ 设置点清除 → 确认 → app 重启 → crew 列表空、已登出、首启免责声明重现。
- [ ] PendingBot iOS 模拟器:装机运行 → 我 tab 危险区点清除 → 回登录页 → 重进确认消息缓存/会话空。
- [ ] PendingBot macOS:GUI 运行 → 清除 → 重启。
- [ ] 共享凭证两路径:Mac 双 app 都登录过(有共享凭证)→ 出二选一;否则单确认。
- [ ] 账本:Task 系统对应条目翻 completed(实跑通过后);progress 顶部"最近对账"日期 + 本 feature 一行。

---

## Self-Review

- **Spec 覆盖:** BYOK 删除(T1)、tech-debt(T2)、PendingCrew reset(T3)、PendingBot reset(T4)、共享登录二选一+presence(T3/T4 confirmationDialog)、post-wipe Mac 重启/iOS 回登录(T3/T4)、验证(T5)。✅ 全覆盖。
- **Placeholder:** 协调器给了具体代码 + "先读真实签名"约束;UI 给了具体 confirmationDialog 结构。无 TODO。
- **类型一致:** 两 app 协调器都用 `performReset(clearSharedLogin:)` + `sharedLoginPresent`,命名一致。
