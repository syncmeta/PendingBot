# PendingCrew 群聊对齐 PendingBot + iPad 外壳 — 设计

- 日期:2026-06-13
- 分支:`feat/crew-chat-align`
- 状态:设计已批准,待转 writing-plans

## 背景与问题

PendingCrew 的群聊页(`CrewChatView` + `Sources/Mac/Views/Chat/` 下的 `CrewBubbleRow`/`CrewAvatar`/`CrewComposer`/`CrewTimeSeparator`/`CrewTheme` 等)是当年照着**旧版 PendingBot** 手画的一套**平行实现**。结构上已经很像(非对称气泡、头像+名、胶囊 composer、时间分隔 pill),但已对齐到旧版本,主要缺口:

- `CrewTheme` 是**纯硬编码 hex、无 `Color.adaptive`** → PendingBot 刚落地的**深色模式**(#296–301)完全没跟上。这是"旧版本"最大的视觉差距。
- 气泡用纯 `Text`(PendingBot 现在是 `MarkdownText` + 流式光标);composer 缺 PendingBot 的 morphing 发送钮 / `floatingComposerSurface` / 字体预缩放等细节。

两个目标:
1. **群聊视觉重新对齐到当前 PendingBot**,并让这种对齐**可持续**(不要又一轮逐项手工追平 —— `#212`「逐屏另画对齐版」已被判作废)。
2. **iPad 版**:PendingCrew 的 iOS target(`TARGETED_DEVICE_FAMILY: "2"`,iPad-only)目前只有 `IPadPlaceholderView` 占位,所有聊天代码都在 `#if os(macOS)` 里 —— iPad 上等于没有群聊。

## 决策(已与用户确认)

- **两个 app 保持独立,不抽共享 Swift package**(PendingCrew 将来要独立开源,不能与闭源 PendingBot 在代码上耦死)。
- **对齐方式 = vendor 一份拷贝**(把 PendingBot 当前跨平台聊天视图原样拷进 PendingCrew,削掉 PendingBot 包袱,写 adapter)。成本压成"一次性搬运 + 以后重拷",而非"每次小修 + 永久手工追平"。
- **Markdown 保真 = MarkdownUI + SwiftMath 都加**,`MarkdownText` 逐字拷不改 → 渲染与 PendingBot 逐字节一致、以后重拷最干净。
- **iPad = 连可导航的 iPad 外壳一起做**(登录 → crew 列表 → 群聊)。

## 现状事实(探针实证)

PendingBot 聊天视图分两类:

- **纯视图、无 auth/网络耦合、本就跨平台**(iOS/macOS 双路径俱全):`Theme` / `ColorHex`(`Color.adaptive` 定义处)/ `ColorHash` / `Platform` / `PlatformImage` / `Haptics` / `BotAvatar` / `BlinkingCursor` / `BubbleView`(内含 `AttachmentGrid`)/ `ComposerView`(内含 `ComposerTextField` iOS+macOS 双实现、`floatingComposerSurface`)/ `ChatActionSheet` / `MarkdownText` / `MathRendering`。
- **耦合 auth/网络的 3 个**:`ServerImage`、`UserAvatar`(拉上传头像)、`FileAttachmentChip`(下载文件)—— reach 进 `SupabaseStack.shared` / `HostedConfig` / `APIClient`,**不能直接搬**。

PendingCrew 侧已有的等价基础设施:

- `CrewImageLoader` / `CrewRemoteImage` / `CrewImageCache`:鉴权图加载,读 `appModel.imageAuth`(device-grant `pdg_*` token + baseURL)。
- `CrewSenderResolver`:从 `CrewWhiteboardEntry` + roster + `captainBotId` + `localUserId` 算出 `CrewSender`(kind / displayName / avatarSeed / isCaptain / sessionStatus / isMine)。
- 头像**全是本地生成**(ColorHash 色 + emoji/首字母),从不拉远程头像 → PendingBot 的 `UserAvatar` 远程照片路径用不上。
- bot 消息当前是**纯 `Text`**,无 markdown 渲染。

App 壳 / 登录 / 导航事实:

- `AppModel.backend`:macOS 恒 `localBackend`;**iOS 只有 `credential != nil` 时返回 `edgeBackend`,否则 nil**(iOS 无本地 backend,必须登录)。
- `WelcomeView` / `LoginView` **已跨平台**:QR 扫码登录,iOS 隐藏 BYOK 按钮;登录产出 device-grant token 存 Keychain,置 `isAuthenticated`。
- macOS 壳 = `MacThreePaneView`(侧栏 `CrewSidebarView` crew 列表 + 中栏 `CrewChatView` + 右栏 `CrewSessionWindowView` 终端);iOS `authenticatedRoot` = `IPadPlaceholderView`。
- session/终端/右栏(`CrewSessionWindowView` / `AgentTerminalSession` / `Sources/Mac/LocalRunner/*`)**全部 `#if os(macOS)`** → iPad 无本地 session,壳只需 登录 → crew 列表 → 群聊。
- `CrewChatView` 依赖 `@EnvironmentObject sessionRunner: CrewSessionRunner`(macOS-only),用于"点 session 跳右栏";其余(白板轮询 / 发消息 / ask 卡片 / 附件)平台无关。

## 架构

核心模式:**逐字拷贝纯视图 + 三个 shim 顶住 auth 缝 + 一个 adapter store**。

```
PendingCrew CrewChatView (壳保留)
  ├─ 时间线 → 每行 vendored BubbleView
  │            ↑ message: CrewChatMessage (本地精简型)  ← adapter
  │            ↑ groupSender: GroupBubbleSender         ← CrewSenderResolver 复用
  │            ↑ 图片/文件加载 → ServerImage shim → CrewRemoteImage
  ├─ composer → vendored ComposerView (+ 广播/@提示 + 跨平台 picker)
  ├─ roster   → CrewRosterBar(re-theme)
  ├─ 时间分隔 → CrewTimeSeparator(re-theme)/TimeSeparatorPill
  └─ ask/审批 → CrewInteractionCard / SessionApprovalCardsView(re-theme,贴 PendingBot 卡片)

vendored 纯视图(逐字拷,编译不改一行):
  Theme/ColorHex/ColorHash/Platform/PlatformImage/Haptics/BotAvatar/
  BlinkingCursor/BubbleView/ComposerView/ChatActionSheet/MarkdownText/MathRendering

PendingCrew-authored shim(API 同名同签,顶住 auth 缝):
  ServerImage  → 走 CrewRemoteImage
  UserAvatar   → 人类头像也走本地生成(BotAvatar/ColorHash),不拉远程照片
  文件下载     → 走 PendingCrew 的鉴权下载
```

**为什么这样切**:把"会随 PendingBot 演进"的大文件保持成**逐字拷贝**(再对齐 = 重拷),把"PendingCrew 特有的 auth/数据"收进**几个小 shim + 一个 adapter**(PendingCrew 自己维护)。drift 面最小化。

## 组件设计

### Phase A — 群聊对齐(跨平台就绪)

**A1. 逐字 vendor 纯视图 + 加 SPM 包**
- 把上列纯视图文件拷进 PendingCrew(建议落在 `Sources/Chat/Vendored/` 一类目录,标注来源 commit 便于重拷)。
- `project.yml` `packages:` 加 `MarkdownUI`(swift-markdown-ui)+ `SwiftMath`,target `dependencies` 挂上;`xcodegen` 重生。
- 验收:这批文件在 PendingCrew target 下编译通过(配合 A2 的 shim)。

**A2. 三个 shim(API 同名同签)**
- `ServerImage`:同 PendingBot 的初始化签名(按 attachmentId / 相对路径加载鉴权图),内部委托 `CrewRemoteImage`/`CrewImageCache`,token 取 `appModel.imageAuth`。
- `UserAvatar`:同签,但内部直接退化到本地生成头像(`BotAvatar` + `ColorHash`),不引远程照片(PendingCrew 无上传头像)。
- 文件下载缝(`FileAttachmentChip` 用到的下载):走 PendingCrew 鉴权下载;附件区在 iPad 上能显示图片网格 + 文件 chip。
- 验收:`BubbleView` 内的 `AttachmentGrid` / 文件 chip 在 PendingCrew 下渲染鉴权图。

**A3. adapter:`CrewWhiteboardEntry` → `CrewChatMessage` + `GroupBubbleSender`**
- 定义 PendingCrew 本地的精简 `CrewChatMessage`(只含 `BubbleView` 读取的字段:id、content/displayText、sender 侧别(isMine)、attachments、status(sending/failed)、isStreaming),**不引** PendingBot 的 `ChatMessage`(避免拖 citations/arena/recall/MessageStore 包袱)。
  - 注:`BubbleView` 是 `BubbleView<Menu: View>` 且 `let message: ChatMessage` —— 因此需要 vendored `BubbleView` 引用的是 PendingCrew 本地的 `CrewChatMessage` 类型名,或在 vendor 时把类型别名对齐(`typealias`/同名本地型)。以"`BubbleView` 不改源"为最高优先级选具体手法。
- `GroupBubbleSender`:用现成 `CrewSenderResolver` 的产物映射(kind→bot/user、displayName、avatarSeed、avatarPath=nil)。captain 用 `BotAvatar` 的徽标/或保留星标语义(视觉贴当前 PendingBot 群聊)。
- 验收:补纯 Swift 单测覆盖映射(自己消息右对齐 / 他人左对齐带头像名 / ask 条目走卡片不走气泡 / relay 消息不误判 isMine)。

**A4. CrewChatView 换叶子 + re-theme + 删旧件**
- `CrewBubbleRow` → vendored `BubbleView`(经 adapter)。
- `CrewComposer` → vendored `ComposerView`;保留 PendingCrew 语义:占位"发消息…(不 @ = 广播给所有 session)"、`@session/@captain` 提示与 staged、`onSend` 仍调 `backend.postCrewMessage(crewId, text, mentions, attachmentIds)`;附件 picker 接 A5 的跨平台分支。
- `CrewTheme` → vendored `Theme` **全局替换**(`CrewTheme.Palette/Fonts/Metrics` 的所有引用点改 `Theme.*`)→ 深色模式到位。
- `CrewRosterBar` / `CrewTimeSeparator` / `CrewInteractionCard` / `SessionApprovalCardsView` 改用 `Theme` token,视觉贴 PendingBot(ask 卡片对标 `PermissionRequestCard` 观感)。
- 删被取代的 `CrewBubbleRow` / `CrewComposer` / `CrewAvatar` / `CrewTheme`(确认无其他引用后)。
- 验收:macOS GUI 构建,装进去看深色 + 浅色群聊,气泡/composer/头像/时间分隔/卡片全部对齐当前 PendingBot。

**A5. 解平台门 + composer picker iOS 分支**
- 聊天视图去 `#if os(macOS)`(`CrewChatView` 及被复用的子视图)。
- composer 附件 picker:macOS `fileImporter` ↔ iOS `PhotosUI`(图片)/`UIDocumentPicker`(文件);缩略图 `NSImage` ↔ `UIImage` 走 vendored `PlatformImage`。
- `CrewChatView` 对 `sessionRunner` 的依赖(点 session 跳右栏)包进 `#if os(macOS)`,使 iPad 不需要 `CrewSessionRunner`/LocalRunner。
- 验收:iPad 模拟器构建绿;macOS 构建仍绿。

### Phase B — iPad 外壳

**B1. iPad authenticatedRoot**
- `PendingCrewApp` 的 iOS `authenticatedRoot` 从 `IPadPlaceholderView` 换成 `NavigationSplitView`:侧栏 = crew 列表;详情 = `CrewChatView(crewId:crewTitle:)`。
- 删 `IPadPlaceholderView`(或保留为未登录/空态)。

**B2. 跨平台 crew 列表**
- 基于平台无关的 `CrewStore`(`backend.listCrews()` / `selectCrew`),做 iPad 版列表;可由 `CrewSidebarView` 跨平台化或新写一份 iPad-native 列表。选择 crew → 详情区 `CrewChatView`。

**B3. CrewChatView iPad 宿主**
- 确认 iPad 路径不触达任何 `Mac/LocalRunner` / `CrewSessionWindowView`;session 相关交互全在 `#if os(macOS)`(随 A5)。
- ask 卡片回答(`answerInteraction`)/ 附件上传(`uploadAttachment`)走 `loggedAPIClient`(iPad 恒登录,满足)。

**B4. 登录链路**
- 复用现成跨平台 `WelcomeView`(iOS 隐藏 BYOK)→ `LoginView`(QR)→ device-grant → `isAuthenticated` → 进 B1 壳。无需新登录 UI。

**B5. iPad 验证**
- iPad 模拟器构建 + 视图渲染(可用 Preview / 模拟器空态)。
- 真机 / 真账号端到端(扫码登录 → 见 crew 列表 → 进群聊 → 发消息 → 看 bot 回)记为**真机尾巴**(模拟器无登录态进不到壳,与 #290 同款约束),记进 tech-debt / progress。

## 跨平台与平台分支清单

- 已天然跨平台、直接可用:`Theme` / `Haptics` / `PlatformImage` / `BotAvatar` / `ColorHash` / `BlinkingCursor` / `ComposerTextField`(双实现)/ `floatingComposerSurface` / `MarkdownText`(macOS 无 code-run 工具条,已 gated)。
- 需 iOS 分支:composer 附件 picker(A5)。
- macOS-only 保留:session 跳转、右栏终端、LocalRunner —— iPad 不触达。

## 验证策略

- **每个小单元**:macOS GUI 构建 + iPad 模拟器构建双绿(改 `project.yml` 后先 `xcodegen`)。
- **单测**:adapter 映射 + 任意纯逻辑走 `PendingCrewTests`(自包含 Foundation,编进 bundle)。
- **视觉**:macOS 装进去看深/浅色群聊全要素对齐;iPad 模拟器看渲染。
- **真机尾巴**:iPad 真账号端到端 E2E(记 tech-debt,不在骨架阶段关 task)。

## 范围之外(本设计不做)

- iPad 上的本地 session / 终端 / 遥控(那是 Mac 形态;遥控 v1 见 #242)。
- PendingBot 侧任何改动(纯拷贝出方向,PendingBot 不动)。
- 群聊功能性扩展(citations / arena / recall / 群钱包入口等 PendingBot 专属)。

## 风险与权衡

- **vendored MarkdownText 拖 SwiftMath**:体量略增;换来逐字拷不改、重拷最干净(已选)。
- **`BubbleView` 的 `message:` 类型耦合**:需让 vendored `BubbleView` 吃 PendingCrew 本地精简型而非 PendingBot `ChatMessage`;以"vendor 大文件尽量不改源"为准绳决定具体手法(同名本地型 / 极小改 / typealias),并在重拷指引里记下这唯一的接缝。
- **重拷指引**:vendored 目录顶部标注来源文件 + commit,日后"再对齐"= 对照 PendingBot 重拷这批文件 + 复核 shim/adapter 接缝。
