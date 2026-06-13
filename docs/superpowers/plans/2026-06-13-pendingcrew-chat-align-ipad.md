# PendingCrew 群聊对齐 PendingBot + iPad 外壳 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PendingCrew 群聊视觉重新对齐到当前 PendingBot(含深色模式、markdown、composer 细节),做法是逐字 vendor PendingBot 跨平台聊天视图 + 三个 auth shim + 一个 adapter;并补一个可导航的 iPad 外壳(登录 → crew 列表 → 群聊)。

**Architecture:** 逐字拷贝 PendingBot 纯视图(随其演进、再对齐=重拷)→ 三个 PendingCrew-authored shim 顶住 auth/网络缝 → adapter 把 `CrewWhiteboardEntry` 翻成本地精简 `CrewChatMessage` + `GroupBubbleSender` → `CrewChatView` 换叶子并全局 `CrewTheme`→`Theme`,crew 徽标(captain 星标/session 状态点/终端图标)作为 overlay 重做到 vendored 头像上 → 解 `#if os(macOS)` 门让 iPad 渲染 → iPad `NavigationSplitView` 外壳。PendingBot 不动。

**Tech Stack:** Swift / SwiftUI / xcodegen(`project.yml`)/ xcodebuild(macOS + iOS Simulator)/ SPM:`MarkdownUI`、`SwiftMath`(新增)、`SwiftTerm`(现有)/ `PendingCrewTests`(macOS XCTest bundle)。

**关键参考(执行时按这些源文件逐字拷/对照,不要凭印象重写)**

PendingBot 源(`apps/pendingbot/Sources/`):
- 纯视图(逐字拷):`Components/Theme.swift`、`Components/ColorHex.swift`(`Color.adaptive` 定义)、`Components/ColorHash.swift`、`Components/Platform.swift`、`Components/PlatformImage.swift`、`Components/PlatformModifiers.swift`、`Components/Haptics.swift`、`Components/BotAvatar.swift`、`Components/BlinkingCursor.swift`、`Components/MarkdownText.swift`、`Components/MathRendering.swift`、`Features/Message/BubbleView.swift`(内含 `AttachmentGrid`/`FileAttachmentChip`)、`Features/Message/ComposerView.swift`(内含 `ComposerTextField` iOS+macOS 双实现、`floatingComposerSurface`)、`Features/Message/ChatActionSheet.swift`
- auth-耦合(**不拷,写 shim**):`Components/ServerImage.swift`、`Components/UserAvatar.swift`、`Features/Message/BubbleView.swift` 里的文件下载(`APIClient().download()`)
- 外观开关:`AppearanceMode.swift`(#299 三态机制)+ `@main` 的 `preferredColorScheme` 接线

PendingCrew 现状(`apps/pendingcrew/Sources/`):
- adapter 复用:`Mac/Views/Chat/CrewSenderResolver.swift`(产 `CrewSender`)、`Services/PendingCrewAPI.swift`(`CrewWhiteboardEntry`/`CrewAttachment`/`Payload`)
- 鉴权图:`Mac/Support/CrewImageLoader.swift`(`CrewRemoteImage`/`CrewImageCache`,读 `appModel.imageAuth`)
- 被取代:`Mac/Views/Chat/CrewBubbleRow.swift`、`CrewComposer.swift`、`CrewAvatar.swift`、`Mac/Design/CrewTheme.swift`、`Mac/Design/CrewColorHash.swift`
- 壳:`PendingCrewApp.swift`(`IPadPlaceholderView`、`RootView`、`authenticatedRoot`)、`Stores/AppModel.swift`(`backend`/`isAuthenticated`/`imageAuth`)、`Stores/CrewStore.swift`(`listCrews`/`selectCrew`)、`Mac/Views/CrewSidebarView.swift`、`Mac/Views/CrewChatView.swift`、`Views/WelcomeView.swift`/`LoginView.swift`(已跨平台)

**验证命令(全程复用)**

```bash
# 改 project.yml 后必跑
cd apps/pendingcrew && xcodegen

# macOS 构建
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build

# iPad(iOS Simulator)构建
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build

# 单测(macOS XCTest bundle;若本环境 PTY 耗尽跑不起,用 swiftc-driver 兜底编真实源文件断言)
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test
```

每个 Task 末尾的 commit 走小单元;改 `project.yml`/迁移类不触发(本计划无迁移)。commit message 用仓库前缀(`pendingcrew:` / `ios:` 等)。

---

## Phase A — 群聊对齐(跨平台就绪)

### Task A1: 加 SPM 依赖 MarkdownUI + SwiftMath

**Files:**
- Modify: `apps/pendingcrew/project.yml`(`packages:` 段 + target `dependencies`)

- [ ] **Step 1: 加包声明**

在 `apps/pendingcrew/project.yml` 的 `packages:` 段(现有 `SwiftTerm` 下)补:

```yaml
  MarkdownUI:
    url: https://github.com/gonzalezreal/swift-markdown-ui
    minVersion: 2.4.0
    maxVersion: 3.0.0
  SwiftMath:
    url: https://github.com/mgriebling/SwiftMath
    minVersion: 1.0.0
    maxVersion: 2.0.0
```

在 `targets.PendingCrew.dependencies` 段(现有 `- package: SwiftTerm` 下)补:

```yaml
      - package: MarkdownUI
      - package: SwiftMath
```

- [ ] **Step 2: regen + 构建(验证包能解析)**

Run: `cd apps/pendingcrew && xcodegen && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED(包解析成功;此时还没用到这两个包)。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/project.yml
git commit -m "pendingcrew: 加 MarkdownUI + SwiftMath SPM 依赖(为 vendor MarkdownText)"
```

---

### Task A2: vendor 无依赖的叶子件(Theme / 色彩 / 平台 / 头像 / 光标)

逐字拷这批"不 import 第三方、不碰 auth、本就跨平台"的文件到 PendingCrew。它们彼此可独立编译。

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Vendored/Theme.swift`(← `apps/pendingbot/Sources/Components/Theme.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/ColorHex.swift`(← `Components/ColorHex.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/ColorHash.swift`(← `Components/ColorHash.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/Platform.swift`(← `Components/Platform.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/PlatformImage.swift`(← `Components/PlatformImage.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/PlatformModifiers.swift`(← `Components/PlatformModifiers.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/Haptics.swift`(← `Components/Haptics.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/BotAvatar.swift`(← `Components/BotAvatar.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/BlinkingCursor.swift`(← `Components/BlinkingCursor.swift`)

- [ ] **Step 1: 逐字拷贝**

把每个源文件**逐字**拷到对应 dest 路径。在每个文件**顶部加一行来源注释**(便于将来重拷),例如:
```swift
// VENDORED from PendingBot apps/pendingbot/Sources/Components/Theme.swift @ <copy 时的 main 短 hash>
// 再对齐 = 对照源文件重拷。PendingCrew 侧勿手改主体,差异收进 shim/adapter。
```
注:`Sources/Chat/` 是新目录,`project.yml` 的 `sources: - path: Sources` 已递归纳入,无需改 project.yml。

- [ ] **Step 2: 处理潜在符号冲突**

PendingCrew 已有 `Mac/Design/CrewColorHash.swift`(独立件,不冲突,保留至 Task A9 删 `CrewTheme` 时一并评估)。确认 vendored `Theme`/`ColorHash` 等的类型名(`Theme`、`Palette`、`ColorHash`)在 PendingCrew 现有代码中无同名定义(grep 验证):

Run: `cd apps/pendingcrew && grep -rn "enum Theme\b\|struct Theme\b\|enum Palette\b" Sources --include=*.swift | grep -v Chat/Vendored`
Expected: 仅 `Mac/Design/CrewTheme.swift` 里是 `enum CrewTheme`(不同名),无 `Theme`/`Palette` 裸名冲突。若有冲突,记下、在 Task A9 替换阶段解决。

- [ ] **Step 3: macOS 构建**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: iPad 构建**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Chat/Vendored
git commit -m "pendingcrew: vendor PendingBot 无依赖叶子件(Theme/色彩/平台/BotAvatar/光标)"
```

---

### Task A3: 本地精简消息模型 `CrewChatMessage` + auth shim(ServerImage / UserAvatar / 文件下载)

`BubbleView` 是 `BubbleView<Menu: View>` 且 `let message: ChatMessage`。我们不拷 PendingBot 的 `ChatMessage`(避免拖 citations/arena/recall/MessageStore 包袱),而是定义 PendingCrew 本地的同名/可替换精简型,只含 `BubbleView`/`AttachmentGrid` 读取的字段;并给 auth-耦合的 3 个件写 shim。

**先读源确定契约**:执行时打开 `apps/pendingbot/Sources/Features/Message/BubbleView.swift`,列出它从 `message:` 上读取的**全部属性**(如 `id`、`content`、`sender_type`、`isMine(_:)`、`status`、`attachments`、`isStreaming`、`isFailed` 等)和从 `ServerImage`/`UserAvatar` 用到的**初始化签名**。`CrewChatMessage` 必须覆盖这些读取点。

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Adapter/CrewChatMessage.swift`
- Create: `apps/pendingcrew/Sources/Chat/Shims/ServerImage.swift`
- Create: `apps/pendingcrew/Sources/Chat/Shims/UserAvatar.swift`

- [ ] **Step 1: 写 `CrewChatMessage`(契约由 BubbleView 读取点决定)**

按上面读到的读取点定义本地精简型。骨架(执行时按真实读取点补齐字段,字段名/方法签名**逐一对齐** BubbleView 的用法):

```swift
import Foundation

/// PendingBot BubbleView 吃的消息契约的 PendingCrew 本地精简实现。
/// 只含 BubbleView/AttachmentGrid 读取的字段,不引 citations/arena/recall。
struct CrewChatMessage: Identifiable, Equatable {
    let id: String
    let content: String
    /// 对齐 BubbleView 的 sender_type 语义(决定左右与头像分支)
    let senderType: String          // "user" | "bot" | ...(按 BubbleView 期望取值)
    let attachments: [CrewChatAttachment]
    let status: CrewChatStatus      // .sent / .sending / .failed(对齐 BubbleView 三态读取)
    let isStreaming: Bool
    // ↑ 执行时补齐 BubbleView 实际读取的其余字段

    func isMine(_ currentUserId: String?) -> Bool { /* 由 adapter 预置,见 Task A6 */ fatalError("set via adapter") }
}

struct CrewChatAttachment: Identifiable, Equatable {
    let id: String
    let mime: String
    let filename: String?
    let isImage: Bool
}

enum CrewChatStatus: Equatable { case sent, sending, failed }
```

> 重要:若 BubbleView 直接调 `message.isMine(currentUserId)` 这类方法,`CrewChatMessage` 要提供同名同签方法;`isMine` 的真值在 adapter(Task A6)里由 `CrewSenderResolver` 算好后注入(可改成存储属性 `let mine: Bool` + `func isMine(_:) -> Bool { mine }`)。以"让 vendored BubbleView 源不改"为最高优先级。

- [ ] **Step 2: 写 `ServerImage` shim(同名同签,内走 CrewRemoteImage)**

先读 `apps/pendingbot/Sources/Components/ServerImage.swift` 的**公开初始化签名与对外 View 形态**,以及 `apps/pendingcrew/Sources/Mac/Support/CrewImageLoader.swift` 的 `CrewRemoteImage` API。写一个同名 `ServerImage`,公开签名与 PendingBot 一致,body 委托 `CrewRemoteImage`(token 取 `appModel.imageAuth`)。骨架:

```swift
import SwiftUI

/// SHIM: 顶替 PendingBot Components/ServerImage.swift 的公开 API。
/// 内部走 PendingCrew 的 CrewRemoteImage(device-grant 鉴权)。
/// 公开签名必须与 BubbleView/AttachmentGrid 的调用点逐字匹配。
struct ServerImage: View {
    // ↓ 字段/init 按 PendingBot ServerImage 的调用点对齐(attachmentId / 相对路径 / 尺寸等)
    let attachmentId: String
    var body: some View {
        CrewRemoteImage(path: "/v1/uploads/\(attachmentId)")  // 按 CrewRemoteImage 真实 API 调整
    }
}
```

- [ ] **Step 3: 写 `UserAvatar` shim(退化到本地生成头像)**

PendingCrew 无远程上传头像。写同名 `UserAvatar`,签名对齐 PendingBot 调用点,但 body 直接渲染 `BotAvatar`(本地 ColorHash 生成):

```swift
import SwiftUI

/// SHIM: 顶替 PendingBot Components/UserAvatar.swift。
/// PendingCrew 无上传头像 → 人类头像也走本地生成(BotAvatar/ColorHash)。
/// 签名对齐 BubbleView 调用点(seed / attachmentId / size)。
struct UserAvatar: View {
    let seed: String
    var attachmentId: String? = nil
    var size: CGFloat = 30
    var body: some View {
        BotAvatar(emojiSeed: seed, colorSeed: seed, size: size)  // 按 BotAvatar 真实 init 调整
    }
}
```

- [ ] **Step 4: macOS + iPad 构建**

Run: 两条 build 命令(macOS + iOS Simulator)。
Expected: BUILD SUCCEEDED(此时 shim/模型可独立编译;BubbleView 尚未拷)。

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Chat/Adapter apps/pendingcrew/Sources/Chat/Shims
git commit -m "pendingcrew: 本地精简 CrewChatMessage + ServerImage/UserAvatar shim"
```

---

### Task A4: vendor 文件下载缝 + BubbleView + ChatActionSheet

`BubbleView` 内含 `AttachmentGrid` 和 `FileAttachmentChip`,后者用 `APIClient().download()`(PendingBot 网络层)。先把下载缝抽成 PendingCrew 实现,再拷 BubbleView。

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Shims/AttachmentDownload.swift`(PendingCrew 鉴权下载,供文件 chip 用)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/BubbleView.swift`(← `Features/Message/BubbleView.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/ChatActionSheet.swift`(← `Features/Message/ChatActionSheet.swift`)

- [ ] **Step 1: 读 BubbleView 的下载/保存调用点**

打开 `apps/pendingbot/Sources/Features/Message/BubbleView.swift`,定位 `FileAttachmentChip` 调 `APIClient().download(...)` 的签名,以及 iOS-only 的"存相册/分享"(`UIImageWriteToSavedPhotosAlbum`/`UIActivityViewController`,已 `#if os(iOS)` gated)。

- [ ] **Step 2: 写 PendingCrew 鉴权下载 helper**

```swift
import Foundation

/// 顶替 BubbleView 里 FileAttachmentChip 用的 APIClient().download()。
/// 走 PendingCrew 的 device-grant 鉴权拉 /v1/uploads/<id>。
enum CrewAttachmentDownload {
    static func data(forPath path: String, auth: (baseURL: URL, token: String)) async throws -> Data {
        var req = URLRequest(url: auth.baseURL.appendingPathComponent(path))
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
```

- [ ] **Step 3: 逐字拷 BubbleView + ChatActionSheet,改下载调用点**

逐字拷两文件到 dest(顶部加来源注释)。**唯一允许的改动**:把 `FileAttachmentChip` 里 `APIClient().download(...)` 调用点替换为 `CrewAttachmentDownload.data(forPath:auth:)`(auth 取 `appModel.imageAuth`);其余(`AttachmentGrid` 用 `ServerImage`、头像用 `BotAvatar`/`UserAvatar` shim、`MarkdownText`、`BlinkingCursor`、`Theme`)保持原样 —— 它们已被 A2/A3 满足或将由 A5 满足。把每处偏离原文件的改动在该处加 `// PENDINGCREW SHIM:` 注释。

> 此时 BubbleView 引用 `MarkdownText`(A5 才拷)→ 暂不会编译通过。**本 Task 不单独 build**,与 A5 连续完成后统一 build。

- [ ] **Step 4: Commit(暂不 build,标注)**

```bash
git add apps/pendingcrew/Sources/Chat/Shims/AttachmentDownload.swift \
        apps/pendingcrew/Sources/Chat/Vendored/BubbleView.swift \
        apps/pendingcrew/Sources/Chat/Vendored/ChatActionSheet.swift
git commit -m "pendingcrew: vendor BubbleView/ChatActionSheet + 文件下载缝(待 MarkdownText 后编译)"
```

---

### Task A5: vendor MarkdownText + MathRendering + ComposerView(收口编译)

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Vendored/MarkdownText.swift`(← `Components/MarkdownText.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/MathRendering.swift`(← `Components/MathRendering.swift`)
- Create: `apps/pendingcrew/Sources/Chat/Vendored/ComposerView.swift`(← `Features/Message/ComposerView.swift`)

- [ ] **Step 1: 逐字拷三文件**

逐字拷(顶部来源注释)。`MarkdownText` 依赖 `MarkdownUI` + `SwiftMath`(A1 已加);`ComposerView` 含 `ComposerTextField`(iOS `UITextView` + macOS `TextField` 双实现)+ `floatingComposerSurface`,无第三方/auth 依赖。

- [ ] **Step 2: 处理 ComposerView 的 `PendingAttachment` 类型**

`ComposerView` 用 `@Binding var pending: [PendingAttachment]`。读 PendingBot `ComposerView.swift` 的 `PendingAttachment` 定义:若是该文件内/小范围类型,一并拷;若引 PendingBot 网络层,改成 PendingCrew 现有的 `PendingComposerAttachment`(见 `CrewComposer.swift`)或在 vendored 文件内定义等价精简型。以"ComposerView 主体不改"为先,必要时加 `typealias PendingAttachment = PendingComposerAttachment`。

- [ ] **Step 3: macOS + iPad 构建(全链路收口)**

Run: 两条 build 命令。
Expected: BUILD SUCCEEDED。BubbleView/MarkdownText/ComposerView 全链路在 PendingCrew 下编译通过(尚未接入 CrewChatView)。
若失败:逐个解符号(多半是 shim/精简型某字段没对齐 BubbleView/ComposerView 的读取点)→ 调 `CrewChatMessage`/shim,**不改 vendored 主体**。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Chat/Vendored/MarkdownText.swift \
        apps/pendingcrew/Sources/Chat/Vendored/MathRendering.swift \
        apps/pendingcrew/Sources/Chat/Vendored/ComposerView.swift
git commit -m "pendingcrew: vendor MarkdownText/MathRendering/ComposerView,聊天视图链路编译通过"
```

---

### Task A6: adapter — `CrewWhiteboardEntry` → `CrewChatMessage` + `GroupBubbleSender`

复用 `CrewSenderResolver`,把白板条目翻成 vendored BubbleView 吃的两个型。

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Adapter/CrewChatAdapter.swift`
- Create: `apps/pendingcrew/Sources/Chat/Adapter/GroupBubbleSender.swift`(若 vendored BubbleView 引用 PendingBot 的 `GroupBubbleSender`,则把它一并 vendor 进来;否则本地定义)
- Test: `apps/pendingcrew/Tests/PendingCrewTests/CrewChatAdapterTests.swift`
- Modify: `apps/pendingcrew/project.yml`(把 adapter + resolver + 模型源编进 `PendingCrewTests` 的 `sources`,纯逻辑可单测)

- [ ] **Step 1: 确定 GroupBubbleSender 来源**

读 vendored `BubbleView.swift` 引用的 `GroupBubbleSender` 定义处(PendingBot `BubbleView.swift` 末尾有 `struct GroupBubbleSender`)。**逐字拷**进 `Sources/Chat/Vendored/` 或 `Adapter/`(它是纯值类型,无依赖),保持字段:`kind(.bot/.user)`、`id`、`displayName`、`avatarPath`、`avatarSeed`。**扩展**(PendingCrew 加的 crew 信息,供 A7 徽标用):加 `isCaptain: Bool`、`sessionStatus: String?`、`isSession: Bool`,默认值不破坏 vendored BubbleView 用法。

- [ ] **Step 2: 写 failing test**

```swift
import XCTest
@testable import PendingCrew  // 或按 test bundle 编入源的方式直接引

final class CrewChatAdapterTests: XCTestCase {
    func testOwnMessageIsMine() {
        let entry = makeEntry(senderKind: "user", senderUserId: "u1", text: "hi")
        let (msg, sender) = CrewChatAdapter.adapt(entry, members: [], captainBotId: nil, localUserId: "u1")
        XCTAssertTrue(msg.isMine("u1"))
        XCTAssertNil(sender, "自己的消息右对齐,不给 groupSender")
    }
    func testPeerBotHasSenderWithName() {
        let entry = makeEntry(senderKind: "bot", senderBotId: "b1", text: "yo")
        let (_, sender) = CrewChatAdapter.adapt(entry, members: [bot("b1","小绿")], captainBotId: "b1", localUserId: "u1")
        XCTAssertEqual(sender?.kind, .bot)
        XCTAssertEqual(sender?.displayName, "小绿")
        XCTAssertTrue(sender?.isCaptain ?? false)
    }
    func testInteractionEntryNotBubble() {
        let entry = makeInteraction(question: "继续?")
        XCTAssertTrue(CrewChatAdapter.isInteraction(entry))
    }
    // makeEntry/makeInteraction/bot 为测试夹具,按 CrewWhiteboardEntry 真实 init 写
}
```

- [ ] **Step 3: 跑测试确认 fail**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: 编译失败 / 测试失败("CrewChatAdapter not found")。

- [ ] **Step 4: 实现 adapter**

```swift
import Foundation

enum CrewChatAdapter {
    static func isInteraction(_ e: CrewWhiteboardEntry) -> Bool { e.isInteraction }

    /// 把白板条目翻成 (BubbleView 消息, groupSender)。
    /// groupSender == nil ⇒ 自己的消息(右对齐,无头像名)。
    static func adapt(_ e: CrewWhiteboardEntry,
                      members: [CrewMember],
                      captainBotId: String?,
                      localUserId: String?) -> (CrewChatMessage, GroupBubbleSender?) {
        let s = CrewSenderResolver.resolve(entry: e, members: members,
                                           captainBotId: captainBotId, localUserId: localUserId)
        let msg = CrewChatMessage(
            id: e.id,
            content: e.displayText,
            senderType: s.isMine ? "user" : (s.kind == .bot ? "bot" : "user"),
            attachments: (e.attachments ?? []).map {
                CrewChatAttachment(id: $0.id, mime: $0.mime, filename: $0.filename, isImage: $0.isImage)
            },
            status: .sent,
            isStreaming: false,
            mine: s.isMine                       // CrewChatMessage.isMine(_:) 读这个
        )
        guard !s.isMine else { return (msg, nil) }
        let sender = GroupBubbleSender(
            kind: s.kind == .bot ? .bot : .user,
            id: e.senderBotId ?? e.senderUserId ?? e.senderSessionId ?? e.id,
            displayName: s.displayName,
            avatarPath: nil,
            avatarSeed: s.avatarSeed,
            isCaptain: s.isCaptain,
            sessionStatus: s.sessionStatus,
            isSession: s.kind == .session
        )
        return (msg, sender)
    }
}
```

> 注:`CrewChatMessage` 的 `isMine(_:)` 改为读存储属性 `mine`(Task A3 Step 1 的注释提到的手法)。按 `CrewSenderResolver.resolve` 的真实签名调用(若它是实例方法/不同参数名,对齐)。

- [ ] **Step 5: 把纯逻辑源编进 test bundle**

在 `project.yml` 的 `PendingCrewTests.sources` 段补(对齐现有"自包含编进 bundle"做法):
```yaml
      - path: Sources/Chat/Adapter
      - path: Sources/Mac/Views/Chat/CrewSenderResolver.swift
```
(若 `CrewSenderResolver`/`CrewWhiteboardEntry` 牵更多源,按编译报错补最小集;`CrewWhiteboardEntry` 在 `Services/PendingCrewAPI.swift`,若过重则在测试里造等价夹具型。)

- [ ] **Step 6: regen + 跑测试确认 pass**

Run: `cd apps/pendingcrew && xcodegen && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: 三个测试 PASS。(本环境若 PTY 耗尽致 xctest 起不来,用 swiftc 编 `CrewChatAdapter.swift`+`CrewSenderResolver.swift`+夹具的 driver 跑断言兜底。)

- [ ] **Step 7: Commit**

```bash
git add apps/pendingcrew/Sources/Chat/Adapter apps/pendingcrew/Sources/Chat/Vendored/GroupBubbleSender.swift \
        apps/pendingcrew/Tests/PendingCrewTests/CrewChatAdapterTests.swift apps/pendingcrew/project.yml
git commit -m "pendingcrew: CrewWhiteboardEntry→CrewChatMessage+GroupBubbleSender adapter + 单测"
```

---

### Task A7: crew 徽标 overlay — `CrewAvatarBadges`(在 vendored 头像位置重做)

captain 橙星标、session 状态点、session 终端图标 —— 作为薄 overlay 套在 vendored `BotAvatar` 外。逻辑从旧 `CrewAvatar.swift` 迁来。

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Adapter/CrewAvatarBadges.swift`
- 参考(迁逻辑后删):`apps/pendingcrew/Sources/Mac/Views/Chat/CrewAvatar.swift`

- [ ] **Step 1: 写 overlay 包装**

```swift
import SwiftUI

/// 在 vendored BotAvatar 之上叠 crew 徽标:
///  - captain → 右上橙色 star.fill
///  - session 运行态 → 右下绿/黄状态点
///  - session 类型 → 头像主体用终端图标(否则 BotAvatar 的 emoji/首字母)
struct CrewAvatarBadges: View {
    let sender: GroupBubbleSender
    var size: CGFloat = 30
    var body: some View {
        ZStack(alignment: .topTrailing) {
            base
            if sender.isCaptain {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.34))
                    .foregroundStyle(.orange)
                    .padding(2)
                    .background(Circle().fill(Theme.Palette.canvas))
                    .offset(x: 2, y: -2)
            }
        }
        .overlay(alignment: .bottomTrailing) { statusDot }
    }
    @ViewBuilder private var base: some View {
        if sender.isSession {
            // 终端图标头像(绿底),迁 CrewAvatar 的 session 分支视觉
            ZStack {
                Circle().fill(Theme.Palette.accentBg)
                Image(systemName: "terminal.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Theme.Palette.accent)
            }.frame(width: size, height: size)
        } else {
            BotAvatar(emojiSeed: sender.avatarSeed, colorSeed: sender.id, size: size)  // 对齐 BotAvatar init
        }
    }
    @ViewBuilder private var statusDot: some View {
        if let st = sender.sessionStatus {
            Circle()
                .fill(st == "running" ? Color.green : (st == "queued" ? Color.yellow : Color.gray))
                .frame(width: size * 0.28, height: size * 0.28)
                .overlay(Circle().stroke(Theme.Palette.canvas, lineWidth: 1.5))
        }
    }
}
```
(色值/尺寸对照旧 `CrewAvatar.swift` 与当前 PendingBot 头像观感微调。)

- [ ] **Step 2: 构建(overlay 可独立编译)**

Run: macOS build。Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Chat/Adapter/CrewAvatarBadges.swift
git commit -m "pendingcrew: CrewAvatarBadges — captain/session 徽标叠在 vendored 头像上"
```

---

### Task A8: CrewChatView 换叶子 — 气泡行接 vendored BubbleView

把 `CrewChatView` 时间线里渲染 `CrewBubbleRow` 的地方,改成"adapter → vendored BubbleView(+ 头像换 CrewAvatarBadges)"。

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`(行渲染分支)
- 参考:`apps/pendingbot/Sources/Features/Crew/CrewMessageListView.swift`(PendingBot 怎么把 row 喂 BubbleView)

- [ ] **Step 1: 在 CrewChatView 里建 row 渲染**

把每条非 interaction 的 `entry` 经 `CrewChatAdapter.adapt(...)` 得 `(msg, sender)`,渲染 vendored `BubbleView(message: msg, botName: sender?.displayName ?? "机组", ..., groupSender: sender, menu: {})`。BubbleView 内部头像槽:若需把头像替换成 `CrewAvatarBadges`,有两条路 ——(a)若 BubbleView 暴露头像构造点,最小改;(b)否则在 `groupSender` 透传 crew 字段,**在 vendored BubbleView 的头像分支加一处** `// PENDINGCREW SHIM:` 用 `CrewAvatarBadges(sender:)` 取代 `BotAvatar`/`UserAvatar`(这是允许的极小接缝,记进重拷指引)。interaction 条目仍走 `CrewInteractionCard`(A10 re-theme)。

- [ ] **Step 2: 删 CrewBubbleRow 引用**

`CrewChatView` 不再调 `CrewBubbleRow`。`CrewBubbleRow.swift` 暂留(Task A11 统一删),先确保编译走新路径。

- [ ] **Step 3: macOS 构建 + GUI 自查**

Run: macOS build。Expected: BUILD SUCCEEDED。
GUI(执行者本机):Xcode 跑起来进一个 crew,确认消息以 PendingBot 气泡渲染(markdown / 流式 / 左右分布 / 头像带徽标)。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift apps/pendingcrew/Sources/Chat/Vendored/BubbleView.swift
git commit -m "pendingcrew: CrewChatView 气泡行接 vendored BubbleView + 徽标头像"
```

---

### Task A9: 全局 `CrewTheme`→`Theme` 替换(深色模式到位)

**Files:**
- Modify: PendingCrew 所有引用 `CrewTheme.*` 的文件
- Delete(本 Task 末):`apps/pendingcrew/Sources/Mac/Design/CrewTheme.swift`

- [ ] **Step 1: 列出所有引用点**

Run: `cd apps/pendingcrew && grep -rln "CrewTheme" Sources --include=*.swift`
Expected: 一组文件(roster/timeseparator/interaction card/approval card/sidebar 等)。

- [ ] **Step 2: 逐文件把 `CrewTheme.Palette/Fonts/Metrics` 映射到 `Theme.*`**

按 token 对照(`CrewTheme.Palette.accent`→`Theme.Palette.accent`,字体/metrics 同理)。`CrewTheme` 里 PendingBot `Theme` 没有的 token(如 `amber`/`amberBg`)→ 用 `Theme` 对应语义 token(`gold`/`dangerBg` 等)或在 vendored `Theme` 不动的前提下,于 PendingCrew 侧加一个小扩展 `Theme.Palette` 补这俩(放 `Sources/Chat/Adapter/ThemeCrewExtras.swift`,不改 vendored Theme 主体)。

- [ ] **Step 3: 删 CrewTheme,构建**

```bash
git rm apps/pendingcrew/Sources/Mac/Design/CrewTheme.swift
```
Run: macOS + iPad build。Expected: BUILD SUCCEEDED(无残留 `CrewTheme` 符号)。

- [ ] **Step 4: GUI 深/浅色自查**

GUI:macOS 切系统深色/浅色,确认群聊整屏(气泡/composer/roster/卡片)自适应、无裸白/黑。

- [ ] **Step 5: Commit**

```bash
git add -A apps/pendingcrew/Sources
git commit -m "pendingcrew: CrewTheme→vendored Theme 全局替换(深色模式到位)+ 删 CrewTheme"
```

---

### Task A10: composer 换 vendored ComposerView + re-theme 卡片/roster/分隔

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`(composer 区)
- Modify: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewRosterBar.swift`、`CrewTimeSeparator.swift`、`CrewInteractionCard.swift`、`SessionApprovalCardsView.swift`(已在 A9 改 token;此处对齐 PendingBot 卡片观感 + roster 改用 `CrewAvatarBadges`)

- [ ] **Step 1: composer 接 vendored ComposerView**

把 `CrewChatView` 的 `CrewComposer` 换成 vendored `ComposerView`,绑定 `input`(draft)、`pending`(附件)、`onSend`(仍调 `backend.postCrewMessage(crewId:text:mentions:attachmentIds:)`)。保留 PendingCrew 语义:占位 "发消息…(不 @ = 广播给所有 session)"、`@session/@captain` 提示。附件 picker 接 A12 的跨平台分支(本 Task 先在 macOS 用现有 `fileImporter` 路径接通)。`showsAttachments: true`(PendingCrew 保留附件能力)。

- [ ] **Step 2: roster 用 CrewAvatarBadges + 卡片对齐观感**

`CrewRosterBar` 成员头像改用 `CrewAvatarBadges`(从 `CrewMember` 构 `GroupBubbleSender`)。`CrewInteractionCard`/`SessionApprovalCardsView` 视觉贴 PendingBot 卡片(对照 `apps/pendingbot/Sources/Features/Message/PermissionRequestCard.swift` 的圆角/间距/按钮样式),逻辑/回调不变。

- [ ] **Step 3: macOS 构建 + GUI**

Run: macOS build。Expected: BUILD SUCCEEDED。GUI:composer 是 PendingBot 胶囊态(morphing 发送钮 / floating surface),发消息/附件正常;roster 头像带徽标;卡片观感对齐。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views
git commit -m "pendingcrew: composer 换 vendored ComposerView + roster/卡片/分隔对齐 PendingBot"
```

---

### Task A11: 删被取代的旧件 + 清引用

**Files:**
- Delete: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewBubbleRow.swift`、`CrewComposer.swift`、`CrewAvatar.swift`
- 评估:`Mac/Design/CrewColorHash.swift`(若仅旧件用,删;若 `CrewImageLoader`/别处用,留)

- [ ] **Step 1: 确认无引用**

Run: `cd apps/pendingcrew && for s in CrewBubbleRow CrewComposer CrewAvatar; do echo "== $s =="; grep -rn "$s" Sources --include=*.swift | grep -v "Chat/$s.swift"; done`
Expected: 无外部引用(空)。`CrewAvatarBadges` 不同名,不受影响。

- [ ] **Step 2: 删 + 构建**

```bash
git rm apps/pendingcrew/Sources/Mac/Views/Chat/CrewBubbleRow.swift \
       apps/pendingcrew/Sources/Mac/Views/Chat/CrewComposer.swift \
       apps/pendingcrew/Sources/Mac/Views/Chat/CrewAvatar.swift
```
Run: macOS + iPad build。Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add -A apps/pendingcrew/Sources
git commit -m "pendingcrew: 删被 vendored 件取代的 CrewBubbleRow/CrewComposer/CrewAvatar"
```

---

### Task A12: 解 `#if os(macOS)` 门 + composer picker iOS 分支

让聊天视图在 iPad 上编译/渲染。

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`(去顶层 `#if os(macOS)`;session 跳转包进 `#if os(macOS)`)
- Modify: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewRosterBar.swift`、`CrewTimeSeparator.swift`、`CrewInteractionCard.swift`、`SessionApprovalCardsView.swift`(去 `#if os(macOS)`,保留 macOS-only 子功能各自 gated)
- Modify: composer 附件 picker(iOS `PhotosUI`/`UIDocumentPicker` 分支)
- 注:`CrewChatView` 现位于 `Sources/Mac/`,但 `sources: -path: Sources` 是按内容编译非按目录 gate,文件名/位置不影响;**只解代码里的 `#if os(macOS)`**。建议把跨平台化后的 `CrewChatView.swift` 及其聊天子视图移出 `Mac/`(可选,降认知负担),移动用 `git mv`,保持引用。

- [ ] **Step 1: CrewChatView 去门 + session 交互 gate**

去掉文件顶层 `#if os(macOS)`/`#endif`。`@EnvironmentObject sessionRunner: CrewSessionRunner` 及"点 session 跳右栏"逻辑包进 `#if os(macOS)`(iPad 不注入 `CrewSessionRunner`)。读 `CrewChatView.swift` 找到所有 `sessionRunner` 用点逐一 gate。

- [ ] **Step 2: 聊天子视图去门**

对上列子视图去顶层 `#if os(macOS)`。各自内部 macOS-only 件(若有 AppKit 调用)单独 gated。

- [ ] **Step 3: composer picker 跨平台**

附件选择:macOS `fileImporter`(现有)↔ iOS `PhotosUI`(图片)+ `UIDocumentPicker`(文件);缩略图 `NSImage`↔`UIImage` 走 vendored `PlatformImage`。把 picker 触发抽成跨平台,平台差异用 `#if os(iOS)/#elseif os(macOS)`。

- [ ] **Step 4: macOS + iPad 构建**

Run: 两条 build。Expected: 双 BUILD SUCCEEDED。(iPad 此时还无壳触达,仅验证视图层跨平台编译。)

- [ ] **Step 5: Commit**

```bash
git add -A apps/pendingcrew/Sources
git commit -m "pendingcrew: 聊天视图解 macOS-gate + composer picker iOS 分支(iPad 渲染就绪)"
```

---

### Task A13: 三态外观开关(跟随/浅/深)

**Files:**
- Create: `apps/pendingcrew/Sources/Chat/Vendored/AppearanceMode.swift`(← PendingBot `AppearanceMode.swift`,逐字拷)
- Modify: `apps/pendingcrew/Sources/PendingCrewApp.swift`(`@main` 注入 `preferredColorScheme`)
- Modify: PendingCrew 设置/inspector 入口(暴露 跟随/浅/深 切换)

- [ ] **Step 1: 逐字拷 AppearanceMode**

读 PendingBot `AppearanceMode.swift`(三态枚举 + `@AppStorage` 偏好 + `colorScheme` 映射),逐字拷(顶部来源注释)。`@AppStorage` 键可沿用或换 PendingCrew 专属键。

- [ ] **Step 2: @main 接线**

读 PendingBot `@main` 怎么用 `AppearanceMode` 算 `preferredColorScheme`,在 `PendingCrewApp.swift` 的 `WindowGroup { RootView()... }` 上加 `.preferredColorScheme(appearance.colorScheme)`(`appearance` 用 `@AppStorage`/`AppearanceMode.current`)。

- [ ] **Step 3: 设置 UI 暴露切换**

在 PendingCrew 设置/inspector 加一个三态 `Picker`(跟随系统/浅色/深色)绑 `AppearanceMode`。找现有设置面板(inspector / 应用菜单),放进去。

- [ ] **Step 4: macOS + iPad 构建 + GUI**

Run: 两条 build。Expected: BUILD SUCCEEDED。GUI:切三态,群聊深浅随之变,"跟随系统"跟系统走。

- [ ] **Step 5: Commit**

```bash
git add -A apps/pendingcrew/Sources
git commit -m "pendingcrew: 三态外观开关(跟随/浅/深)对齐 PendingBot #299"
```

---

## Phase B — iPad 外壳

### Task B1: 跨平台 crew 列表

**Files:**
- Create: `apps/pendingcrew/Sources/Views/CrewListView.swift`(跨平台 crew 列表,基于 `CrewStore`)
- 参考(不直接复用,因其 macOS-gated 且带 session 列):`apps/pendingcrew/Sources/Mac/Views/CrewSidebarView.swift`

- [ ] **Step 1: 写跨平台列表**

基于平台无关的 `CrewStore`(`crews: [CrewSummary]`、`refreshList()`、`selectCrew(_:)`、`selectedCrewId`)写一个 `List(selection:)`,行渲染 crew 标题 + 头像(用 `CrewAvatarBadges` 或简单 `BotAvatar`)。选择驱动 `crewStore.selectCrew(id)`。读 `CrewStore.swift` 对齐真实属性/方法名。

```swift
import SwiftUI

struct CrewListView: View {
    @EnvironmentObject var crewStore: CrewStore
    @Binding var selection: String?
    var body: some View {
        List(crewStore.crews, selection: $selection) { crew in
            HStack(spacing: 10) {
                BotAvatar(emojiSeed: crew.id, colorSeed: crew.id, size: 28)  // 对齐 BotAvatar init
                Text(crew.title).font(Theme.Fonts.body)   // 对齐 CrewSummary 字段名
            }.tag(crew.id)
        }
        .task { await crewStore.refreshList() }            // 对齐 CrewStore 真实方法
    }
}
```

- [ ] **Step 2: macOS + iPad 构建**

Run: 两条 build。Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Views/CrewListView.swift
git commit -m "pendingcrew: 跨平台 CrewListView(基于平台无关 CrewStore)"
```

---

### Task B2: iPad authenticatedRoot — NavigationSplitView

**Files:**
- Modify: `apps/pendingcrew/Sources/PendingCrewApp.swift`(iOS `authenticatedRoot` 分支)
- Delete/改:`IPadPlaceholderView`(改成空态或删)

- [ ] **Step 1: 读现有 RootView/authenticatedRoot 结构**

打开 `PendingCrewApp.swift`,定位 `#if os(iOS)` 的 `authenticatedRoot` 现返回 `IPadPlaceholderView()` 处,以及环境对象注入(`AppModel`、`CrewStore` 等)。

- [ ] **Step 2: 换成 NavigationSplitView**

```swift
#if os(iOS)
private struct IPadShell: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var crewStore: CrewStore
    @State private var selectedCrewId: String?
    var body: some View {
        NavigationSplitView {
            CrewListView(selection: $selectedCrewId)
                .navigationTitle("机组")
        } detail: {
            if let detail = crewStore.selectedDetail {       // 对齐 CrewStore 字段
                CrewChatView(crewId: detail.crew.id, crewTitle: detail.crew.title)
            } else {
                ContentUnavailableView("选择一个机组", systemImage: "person.3")
            }
        }
        .onChange(of: selectedCrewId) { _, id in
            if let id { Task { await crewStore.selectCrew(id) } }   // 对齐 CrewStore
        }
    }
}
#endif
```
把 iOS `authenticatedRoot` 改返回 `IPadShell()`。确保 `CrewChatView` 所需环境对象在 iOS 分支已注入(`AppModel`、`CrewStore`;**不注入** `CrewSessionRunner` —— 已在 A12 gated)。

- [ ] **Step 3: iPad 构建**

Run: iOS Simulator build。Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/PendingCrewApp.swift
git commit -m "pendingcrew: iPad authenticatedRoot 换 NavigationSplitView(crew 列表→群聊)"
```

---

### Task B3: CrewChatView iPad 环境对象核对

确认 iPad 路径不触达 `CrewSessionRunner`/LocalRunner,且登录态满足 `answerInteraction`/`uploadAttachment`。

**Files:**
- Modify(按需):`apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`

- [ ] **Step 1: 核对环境依赖**

Run: `cd apps/pendingcrew && grep -n "EnvironmentObject\|sessionRunner\|loggedAPIClient\|isAuthenticated" Sources/Mac/Views/CrewChatView.swift`
检查:除 `appModel` 外的 `@EnvironmentObject` 是否都在 `#if os(macOS)` 后;`answerInteraction`/`uploadAttachment` 走 `loggedAPIClient`(iPad 恒登录满足)。

- [ ] **Step 2: 修补 iPad 不需要的强依赖**

若 `sessionRunner` 仍是 iPad 路径必需(非 gated),改成 `#if os(macOS)` 注入 + 用点 gate。iPad 群聊不显示 session 跳转/右栏。

- [ ] **Step 3: iPad 构建**

Run: iOS Simulator build。Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift
git commit -m "pendingcrew: CrewChatView iPad 环境依赖核对(session 交互 macOS-gated)"
```

---

### Task B4: 登录链路 iPad 核对

确认 iPad 走现成跨平台登录进壳。

**Files:**
- 核对:`apps/pendingcrew/Sources/Views/WelcomeView.swift`、`LoginView.swift`、`PendingCrewApp.swift`(`RootView` 路由)

- [ ] **Step 1: 核对 RootView iOS 路由**

读 `PendingCrewApp.swift` 的 `RootView`:iOS 未登录 → `WelcomeView`(BYOK 已 `#if os(macOS)` 隐藏)→ `LoginView` QR → `saveDeviceGrantToken` → `isConfigured`(iOS=`localModeSelected`?需确认 device-grant 登录把 iOS 推进 `isConfigured`/`isAuthenticated`)→ `IPadShell`。

> 关键核对:iOS `isConfigured` = `localModeSelected`。device-grant 登录是否置 `localModeSelected` 或另有 iOS 进壳判据?若 iOS 登录后 `isConfigured` 仍 false 会进不去壳。读 `AppModel.isConfigured`/`saveDeviceGrantToken`,必要时让 iOS 登录成功也置位进壳(最小改 `AppModel`)。

- [ ] **Step 2: 按需最小修 AppModel iOS 进壳判据**

若上一步发现 gap:在 `AppModel` 让 iOS `isConfigured` 在 `credential != nil` 时为 true(iOS 无本地模式,登录即配置完成)。

- [ ] **Step 3: iPad 构建**

Run: iOS Simulator build。Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add -A apps/pendingcrew/Sources
git commit -m "pendingcrew: iPad 登录→进壳链路核对(iOS 登录即 isConfigured)"
```

---

### Task B5: iPad 验证 + 账本

**Files:**
- Modify: `docs/progress.md`、`docs/tech-debt.md`

- [ ] **Step 1: iPad 模拟器渲染自查**

执行者本机:iPad 模拟器跑起来,确认 未登录→Welcome→(扫码登录需真账号,模拟器可走到登录页)。登录态进壳的视觉验证记为真机尾巴(模拟器无登录态,与 #290 同款约束)。可用 SwiftUI Preview 给 `IPadShell`/`CrewChatView` 喂假数据看渲染。

- [ ] **Step 2: 双端最终构建**

Run: macOS + iOS Simulator build + `xcodebuild ... test`(或 swiftc 兜底)。Expected: 全绿。

- [ ] **Step 3: 记账本**

`docs/progress.md` 顶部加"最近对账"条:本分支落地内容 + **真机尾巴**(iPad 真账号端到端:扫码登录→见 crew 列表→进群聊→发消息→看 bot 回)。`docs/tech-debt.md` 记:① vendored 文件的重拷指引(来源 commit + 接缝清单:`CrewChatMessage`/3 shim/BubbleView 头像那处 `// PENDINGCREW SHIM`);② iPad 真机 E2E 未验。

- [ ] **Step 4: Commit**

```bash
git add docs/progress.md docs/tech-debt.md
git commit -m "pendingcrew: progress/tech-debt 记群聊对齐+iPad 外壳落地与真机尾巴"
```

---

## Self-Review 结论(写计划者自查)

- **Spec 覆盖**:A1(SPM)/A2-A5(vendor 闭包)/A3(shim+模型)/A6(adapter)/A7(徽标)/A8-A11(换叶子+替 theme+删旧)/A12(跨平台)/A13(三态开关)对应 spec Phase A 全部;B1-B5 对应 Phase B 全部 + 验证/账本。两条新决策(crew 徽标在 vendored 头像位置重做 = A7+A8;三态开关 = A13)各有任务。
- **接缝可控**:vendored 主体不改的原则下,允许的偏离仅:文件下载调用点(A4)、ComposerView `PendingAttachment` typealias(A5)、BubbleView 头像槽换 `CrewAvatarBadges`(A8)—— 三处都打 `// PENDINGCREW SHIM` 并进 tech-debt 重拷指引。
- **类型一致**:`CrewChatMessage`(A3)/`GroupBubbleSender` 扩展字段(A6)/`CrewAvatarBadges` 读 `sender` 字段(A7)三处字段名贯通一致。
- **真实签名待对齐**:多处标注"按真实源签名对齐"(`CrewSenderResolver.resolve`、`CrewStore`、`BotAvatar`/`CrewRemoteImage` init、`AppModel.isConfigured`)—— 执行时读源对齐,不凭印象。这是 Swift 跨 app vendor 的固有性质,故采用 subagent-driven 执行(每任务读真实源 + 构建即验证)。
