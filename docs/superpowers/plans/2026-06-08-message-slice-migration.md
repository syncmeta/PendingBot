# 消息/会话 slice 跨平台迁移 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development。Steps 用 `- [ ]`。

**Goal:** 把消息/会话 slice(24 文件 / ~10k 行)跨平台化,让好友列表 + 会话在 iPhone/iPad/Mac 共用同一份 UI。语音通话(Call)、相机/相册、键盘 inputAccessoryView 是 iOS-only,用**内部 `#if os(iOS)` 围栏**(不是整文件锁),Mac 上干净缺失/降级。

**Architecture:** 先抽共享数据类型(零 UI 改动,iOS 不受影响)→ 补缺的跨平台垫片 → 给 Call/相机/键盘加内部围栏 → 摘各文件顶层 `#if os(iOS)`。iOS 全程保持绿;macOS 在整簇迁完时转绿。

**前置已完成(地基 + bot 管理片):** 垫片层(Haptics/PlatformImage/Clipboard/QRCode/inlineNavTitle/platformAutocapitalization/platformKeyboard/platformDetents/platformDragIndicator/platformListStyle)、`\.api`/`\.account` 环境键跨平台、SplitNav(useSidebarLayout/EmptyDetailHint)、ModelPicker(arena)/BotManagement/EnvelopeAPI 已解锁。WideRootView 三列壳 + FeatureSurface 契约 + Mac 菜单/设置已就位。

**验证范式:** 每步 iOS 模拟器 build 必须保持 `BUILD SUCCEEDED`;macOS build 在 Phase 5 整簇摘锁后转绿。无 Swift UI 测试 target,靠编译 + 模拟器实跑截图。

**编译命令:** `cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination '<DEST>' build`,DEST = `generic/platform=iOS Simulator` / `platform=macOS`。新增文件后 `xcodegen` 再编,且**提交 pbxproj**。

---

## 已知 iOS-only 面(来自依赖测绘)

- **Call slice(iOS-only 留存)**:`CallCenter`/`CallSession`/`GroupCallSession`/`IncomingCallStore`/`ActiveVoiceCallStore`。耦合点:ConversationView.swift:207、ConversationView+Realtime.swift:365-425、ConversationView.swift:836、MessageTabView.swift:39-42/97/111/119-130/1002。→ 全部内部 `#if os(iOS)` 围栏,Mac 无语音入口。
- **相机/相册/附件(iOS-only)**:PhotosUI/UIImagePickerController/UIImage 编码,见 ConversationView+Attachments.swift、ChatActionSheet.swift(CameraPicker)、ComposerView.swift、BubbleView.swift:317(存图)。→ 需 `AttachmentBridge` 垫片;Mac 退化为文件选择(无相机),`+` 面板隐藏相机/相册项。
- **键盘 inputAccessoryView(iOS-only UIKit)**:ChatComposerAccessory.swift 整 658 行 UIKit 键盘吸附。→ Mac 用 `.safeAreaInset(.bottom)` 渲染同款 composer 内容(失去交互拖拽同步,Mac 可接受)。
- **UIScreen/UIApplication**:ChatComposerAccessory.swift:528/617、ConversationView.swift:775、MessageTabView.swift:1248(`UIApplication.open` → `@Environment(\.openURL)`)。
- **新增垫片**:`platformTabBarVisibility()`、`platformFullScreenCover()`、`platformScrollKeyboardDismiss()`、`platformToolbarColorScheme()`、`AttachmentBridge`。

---

## Phase 1 — 抽共享数据类型 + 去重(零 UI 改动,iOS 不受影响)

把这些平台无关的数据类型从 iOS-fenced UI 文件里搬到 `Sources/Models/`(或 `Sources/Components/`),跨平台无围栏:

- `PendingPeer`(ConversationView.swift:22-42)→ `Sources/Models/PendingPeer.swift`
- `UserUserPeer`(MessageTabView.swift:896-903)→ `Sources/Models/UserUserPeer.swift`
- `BotPick`(FriendsTabView.swift:376)→ `Sources/Models/BotPick.swift`(BotManagement 引用 `FriendsTabView.BotPick` 改为 `BotPick`)
- `CrewProposalPayload`(CrewProposalCard.swift:30-64)→ `Sources/Models/CrewProposalPayload.swift`(视图 CrewProposalCard 留 iOS)
- `PermissionRequestPayload`(PermissionRequestCard.swift:37-71)→ `Sources/Models/PermissionRequestPayload.swift`
- `ToolTraceEvent`(ToolTraceView.swift:7-45)→ `Sources/Models/ToolTraceEvent.swift`
- `DeepLinkStore`(QRScannerView.swift:14-45)→ `Sources/Components/DeepLinkStore.swift`(摘围栏;QRScannerView 相机部分留 iOS-only)
- **去重** `FriendFilter` + `FriendSortField`(FriendsTabView.swift:1290-1362 与 Mac/Views/MacFriendsView.swift:737-879 字节级相同)→ `Sources/Models/FriendSort.swift`;两处引用改共享。`FriendFilter.fg`(颜色)合进共享。

每步:iOS build 必须 `SUCCEEDED`(iOS 仍 fenced,只是类型搬家)。新文件提交 pbxproj。逐类型一 commit 或合并相近的。完成后 macOS 仍 red(UI 未摘锁),但 BotManagement 不再依赖 FriendsTabView,且去重消除 Mac 冲突。

## Phase 2 — 补垫片(纯新增)

`Sources/Components/PlatformModifiers.swift` 增:`platformTabBarVisibility(_:)`、`platformScrollKeyboardDismiss()`、`platformToolbarColorScheme(_:)`、`platformFullScreenCover(isPresented:content:)`(iOS fullScreenCover / macOS sheet)。新建 `Sources/Components/AttachmentBridge.swift`:iOS 包 PhotosUI+UIImagePickerController+UIImage 编码;macOS 提供文件选择 + `NSImage→JPEG`,相机为 no-op。纯加法,两端编译过。

## Phase 3 — Call 内部围栏

按测绘的 8 个耦合点给语音入口加 `#if os(iOS)`(macOS 上 `canStartVoiceCall=false`、无电话按钮、无来电导航、不引用 CallCenter env)。此阶段文件仍顶层 fenced,改动只为 Phase 5 摘锁铺路;每步 iOS build 绿。

## Phase 4 — 相机/键盘围栏 + 用现有垫片

- 附件:ComposerView/ChatActionSheet/ConversationView+Attachments 改走 `AttachmentBridge`;Mac 隐藏相机/相册,留文件选择。`UIImageWriteToSavedPhotosAlbum`(BubbleView:317)→ `#if os(iOS)`。
- 键盘:ConversationView body 在 macOS 用 `.safeAreaInset(.bottom)` 渲染 composer 内容,iOS 保留 ChatComposerAccessory inputAccessoryView 路径(`#if os(iOS)`/`#else`)。ComposerView 焦点:iOS 保留手动 UIKit 焦点,macOS 走 `@FocusState`。
- 替换:`UIPasteboard`→`Clipboard.copy`;`.presentationDetents/.presentationDragIndicator`→垫片;`.scrollDismissesKeyboard(.interactively)`→`platformScrollKeyboardDismiss()`;`.toolbar(.hidden,for:.tabBar)`→`platformTabBarVisibility()`;`.fullScreenCover`→`platformFullScreenCover()`;`UIApplication.open`→`@Environment(\.openURL)`;`UIScreen.main`→`GeometryReader`/sizeClass。ToolbarItem `.topBarTrailing` 等 → `#if os(iOS)` 或 `platformToolbarColorScheme`。

## Phase 5 — 摘各文件顶层 `#if os(iOS)` → macOS 转绿

内部围栏齐了后,逐个摘 ConversationView.swift(+全部 `ConversationView+*.swift`)、MessageTabView.swift、ComposerView.swift、BubbleView.swift、ChatActionSheet.swift、ToolTraceView.swift、ConversationSettingsView.swift、SubConversationView.swift、CrewProposalCard.swift、PermissionRequestCard.swift、BubbleSplitter.swift 的顶层围栏。每摘几个跑 macOS build,逐个清编译错。最终 macOS `BUILD SUCCEEDED`。FriendsTabView 此时也能编(其详情列 ConversationView 已跨平台)。

## Phase 6 — FriendsTabView/MessageTabView 拆 FeatureSurface + 接两端壳 + 删 Mac 平行实现

- FriendsTabView、MessageTabView 各 conform `FeatureSurface`(拆 list/detail/compact)。
- WideRootView(Mac)friends+messages tab 接共享 surface,取代 `#if os(macOS)` Mac 列 fallback;删 `Mac/Views/MacFriendsView.swift`、`MacMessagesView.swift`、`MacBotManagement.swift`(阉割版)、`MacRootView.swift`(若全替代)。
- iPad `PendingBotRegularRootView` 对应 tab 改消费共享 surface。

## Phase 7 — 三端实跑验证 + 账本

Mac GUI 构建 + iPad 模拟器 + iPhone 不回归:好友列表、进会话、发消息、选模型(arena)、附件(Mac 文件选择)三端实测截图。语音按钮 Mac 上确认干净缺失。记 tech-debt(Mac composer 用 safeAreaInset 失交互拖拽、Mac 无相机等已知降级),更 progress + roadmap。

---

## 风险

- **ConversationView 2770 行 + 9 个扩展**:最复杂的面,Call/相机/键盘三股 iOS-only 交织。Phase 3/4 围栏要细,漏一个 macOS 就编不过或行为错。
- **键盘 inputAccessoryView**:Mac 无对应,safeAreaInset 是降级;记 tech-debt,别假装等价。
- **附件**:Mac 无相机是硬缺失(用户已认可硬件 gap);相册→文件选择是体验降级,记账本。
- **顺序**:Phase 1 数据抽取若漏改某引用点,iOS 会红——每步必须 iOS build 绿才进下一步。
