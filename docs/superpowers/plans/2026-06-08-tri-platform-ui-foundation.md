# 三端共享 UI 地基 + 好友片 实施 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建跨平台 UI 地基(垫片层 + 统一三列宽屏壳 + 壳↔feature 接口契约 + Mac 原生外壳),并以"好友/Bot 管理/选模型"为第一片把 iOS-only 锁解掉,让 iPhone/iPad/Mac 共用同一份业务 UI。

**Architecture:** 默认全三端共享含 UI;宽屏(Mac+iPad)走统一 Mac 式三列(边栏 tab + 列表列 + 详情列),iPhone compact 保持底部 tab + push。`Features/*` 当年整体 `#if os(iOS)` 是省力一刀切,实际 iOS-only 面是一小撮薄 shim;把这撮 shim 补成跨平台,feature 文件即可摘锁。真三列(Option I),不许退化。

**Tech Stack:** SwiftUI(iOS 17 / macOS 14 单 target,`supportedDestinations: [iOS, macOS]`)、xcodegen(改 `project.yml` 后跑)、xcodebuild。

**验证范式(本仓库现实):** iOS 端无 Swift 单元测试 target,UI 正确性靠 **编译通过 + 模拟器/GUI 实跑截图** 验证(对齐用户 memory:Mac 必须 Xcode GUI 构建,headless CLI 回落 ad-hoc 签名会挂;iOS 改完进模拟器截图看效果)。因此每个任务的"验证"步是 build,关键节点加实跑截图,而非 XCTest。

**编译命令速查:**
- iOS 模拟器:`cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build`
- macOS:`cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build`
- 改了 `project.yml` 后先 `cd apps/pendingbot && xcodegen` 再编译。

**两端都要过:** 每个解锁任务结束都必须 iOS 模拟器 build **和** macOS build 同时通过 —— 摘 `#if os(iOS)` 的意义就是 Mac 也得编进去。

---

## 文件结构(决定在哪、放什么)

**新增(地基):**
- `Sources/Components/PlatformModifiers.swift` — 跨平台 View 修饰符垫片(nav 标题、键盘、autocaps、detents、drag indicator)
- `Sources/Components/Clipboard.swift` — 剪贴板垫片(UIPasteboard / NSPasteboard)
- `Sources/Components/QRCode.swift` — 二维码位图生成(CoreImage → PlatformImage)
- `Sources/Features/Root/WideRootView.swift` — 共享三列宽屏壳(由 `Mac/MacRootView.swift` 抽象升级而来)
- `Sources/Features/Root/FeatureSurface.swift` — 壳↔feature 接口契约协议 + 列宽/空态约定
- `Sources/Features/Root/AppCommands.swift` — Mac 菜单栏 commands(⌘N/⌘F…)
- `Sources/Features/Root/SettingsScene.swift` — Mac ⌘, 设置场景容器

**修改(地基接线):**
- `Sources/PendingBotApp.swift` — macOS @main 接 `WideRootView` + `Settings` scene + `.commands`;iOS RootView 的 regular 分支指向 `WideRootView`
- `Sources/Components/PlatformImage.swift` — 补 `UserAvatar` 需要的 NSImage 解码/缓存路径
- `Sources/Components/UserAvatar.swift` — `UIImage` → `PlatformImage`

**解锁(好友片,摘 `#if os(iOS)` + 换垫片):**
- 叶子组件:`BotAvatar.swift`、`UserAvatar.swift`、`BotVisibilityTag.swift`、`SwipeRevealRow.swift`、`EmptyHint.swift`、`TabHeaderBar.swift`、`SidebarTabBar.swift`
- `Components/ModelPicker.swift`(含 `ArenaModelPickerSheet` / `ArenaModelPoolEditor`)
- `Features/Friends/BotManagement.swift`
- `Features/Friends/FriendsTabView.swift`(拆 list/detail/compact)

**删除(好友片落地后,平行实现连根拔):**
- `Sources/Mac/Views/MacBotManagement.swift`(整文件:MacBotPick / MacModelPickerSheet / MacCreateBotSheet / MacManageBotSheet)
- `Sources/Mac/Views/MacFriendsView.swift`
- `Sources/Mac/MacRootView.swift` 的 friends 分支改指共享 surface(其余 tab 仍 placeholder,等各自 slice)

---

## Phase A — 地基(Slice 0)

### Task A1: 跨平台 View 修饰符垫片

**Files:**
- Create: `apps/pendingbot/Sources/Components/PlatformModifiers.swift`

- [ ] **Step 1: 写垫片文件**

内容覆盖好友片实测用到的全部 iOS-only 修饰符(计数来自勘查:`navigationBarTitleDisplayMode` ×17、`textInputAutocapitalization` ×11、`keyboardType` ×1、`presentationDetents` ×1、`presentationDragIndicator` ×9)。每个在 macOS 上 no-op,签名与 iOS 行为一致:

```swift
import SwiftUI

extension View {
    /// iOS: inline 导航标题;macOS: no-op(桌面无大标题模式)。
    @ViewBuilder func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// 文本框首字母大写策略。macOS no-op。
    @ViewBuilder func platformAutocapitalization(_ never: Bool = true) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(never ? .never : .sentences)
        #else
        self
        #endif
    }

    enum PlatformKeyboard { case url, `default` }
    @ViewBuilder func platformKeyboard(_ kind: PlatformKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .url: self.keyboardType(.URL)
        case .default: self
        }
        #else
        self
        #endif
    }

    /// sheet detents。macOS sheet 自适应,no-op。
    @ViewBuilder func platformDetents(_ detents: Set<PresentationDetent>) -> some View {
        #if os(iOS)
        self.presentationDetents(detents)
        #else
        self
        #endif
    }

    @ViewBuilder func platformDragIndicator() -> some View {
        #if os(iOS)
        self.presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}
```

- [ ] **Step 2: 编译两端**

Run: macOS build + iOS Simulator build(见速查)。
Expected: 两端都 PASS(新文件本身不被任何人引用,纯加法)。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Components/PlatformModifiers.swift
git commit -m "ios+mac: 跨平台 View 修饰符垫片(nav 标题/键盘/detents)"
```

### Task A2: 剪贴板垫片

**Files:**
- Create: `apps/pendingbot/Sources/Components/Clipboard.swift`

- [ ] **Step 1: 写垫片**

```swift
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 跨平台剪贴板。替换 BotManagement 里的 `UIPasteboard.general.string = x`。
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
```

- [ ] **Step 2: 编译两端** — 速查命令,Expected PASS。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Components/Clipboard.swift
git commit -m "ios+mac: Clipboard 跨平台剪贴板垫片"
```

### Task A3: 二维码位图垫片

**Files:**
- Create: `apps/pendingbot/Sources/Components/QRCode.swift`

- [ ] **Step 1: 写垫片** — 用 CoreImage `CIQRCodeGenerator` 出 `CGImage`,再包成 `PlatformImage`(已有 typealias)。替换 BotManagement 里 `qrImage(for:) -> UIImage?` 那段(`CIFilterBuiltins` + `UIImage`)。

```swift
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#endif

enum QRCode {
    /// 生成二维码位图;失败返回 nil。跨平台 → PlatformImage(UIImage/NSImage)。
    static func image(_ payload: String, scale: CGFloat = 10) -> PlatformImage? {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        guard let cg = ctx.createCGImage(output, from: output.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #elseif os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
        #endif
    }
}
```

- [ ] **Step 2: 编译两端** — Expected PASS。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Components/QRCode.swift
git commit -m "ios+mac: QRCode 跨平台二维码位图垫片"
```

### Task A4: PlatformImage 补 UserAvatar 解码/缓存路径

**Files:**
- Modify: `apps/pendingbot/Sources/Components/PlatformImage.swift`
- Modify: `apps/pendingbot/Sources/Components/UserAvatar.swift`

- [ ] **Step 1: 在 PlatformImage.swift 加 Data→PlatformImage 解码 helper**

```swift
extension PlatformImage {
    /// 跨平台从 Data 解码。iOS: UIImage(data:);macOS: NSImage(data:)。
    static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }
}
```

- [ ] **Step 2: UserAvatar.swift 把 7 处 `UIImage` 换成 `PlatformImage`**

`@State private var image: UIImage?` → `PlatformImage?`;`UIImage(data:)` → `PlatformImage.decode(_:)`;内存缓存 map `[String: UIImage]` → `[String: PlatformImage]`;`Image(uiImage:)` → `Image(platformImage:)`(已有 init)。摘掉文件顶层 `#if os(iOS)`(若有)与 `import UIKit`。

- [ ] **Step 3: 编译两端** — Expected PASS。
- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Components/PlatformImage.swift apps/pendingbot/Sources/Components/UserAvatar.swift
git commit -m "ios+mac: PlatformImage.decode + UserAvatar 跨平台位图"
```

### Task A5: 共享三列宽屏壳 WideRootView

**Files:**
- Create: `apps/pendingbot/Sources/Features/Root/WideRootView.swift`
- Reference: `apps/pendingbot/Sources/Mac/MacRootView.swift`(把它的三列骨架 + `pendingConversationJump` selection 状态机抽出来,去掉 `#if os(macOS)` 改成跨平台)

- [ ] **Step 1: 写 WideRootView** — 跨平台(无 `os()` 守卫),`NavigationSplitView { 侧边栏 tab } content: { 当前 tab 列表列 } detail: { 当前 tab 详情列 }`。tab 用现有 `TopTab` 枚举(对齐 iOS,不再用 Mac 私有 `MacTab`)。selection 状态机沿用 MacRootView 的确定性 `pendingConversationJump` 写法(切 tab 清 selection,程序跳转例外)。此刻除好友外的 tab 先复用 MacRootView 现有 placeholder 列(`MacEmptyColumn` 抽成共享 `EmptyDetailHint`,已存在于 SplitNav.swift)。

- [ ] **Step 2: 编译两端**(WideRootView 暂未被接,纯加法)— Expected PASS。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Features/Root/WideRootView.swift
git commit -m "ios+mac: WideRootView 共享三列宽屏壳(抽自 MacRootView)"
```

### Task A6: 壳↔feature 接口契约 FeatureSurface

**Files:**
- Create: `apps/pendingbot/Sources/Features/Root/FeatureSurface.swift`

- [ ] **Step 1: 定协议** — 每个 feature 暴露三种装配,覆盖三类形态(列表+详情型 / feed+正文型 / 无列表型如「我」):

```swift
import SwiftUI

/// 一个 feature 向壳暴露的三种装配。宽屏壳取 list/detail 拼三列;
/// compact 取 compactRoot 自包含 push。Selection 由壳持有并下传。
protocol FeatureSurface {
    associatedtype Selection: Hashable
    associatedtype ListColumn: View
    associatedtype DetailColumn: View
    associatedtype CompactRoot: View

    @ViewBuilder func listColumn(selection: Binding<Selection?>) -> ListColumn
    @ViewBuilder func detailColumn(selection: Selection?) -> DetailColumn
    @ViewBuilder func compactRoot() -> CompactRoot
}
```

并在文件内写清三类形态的约定注释(列表+详情:list 选中驱动 detail;feed:同构;无列表型:list 给空态、detail 给主内容,如「我」)。

- [ ] **Step 2: 编译两端** — Expected PASS。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Features/Root/FeatureSurface.swift
git commit -m "ios+mac: FeatureSurface 壳↔feature 接口契约"
```

### Task A7: Mac 原生外壳 — 菜单栏 + 设置场景

**Files:**
- Create: `apps/pendingbot/Sources/Features/Root/AppCommands.swift`
- Create: `apps/pendingbot/Sources/Features/Root/SettingsScene.swift`

- [ ] **Step 1: AppCommands** — `Commands` 集合:文件菜单加「新建机器人 ⌘N」「新建会话 ⇧⌘N」,编辑/视图菜单加「搜索 ⌘F」。这些通过 `@FocusedValue` / NotificationCenter 触发到当前 tab(先发一个 app 级 `AppCommand` enum 的通知,壳订阅;好友片 B5 接 ⌘N→建机器人)。

- [ ] **Step 2: SettingsScene** — macOS `Settings { SettingsRootView() }` 场景(⌘, 自动绑定)。`SettingsRootView` 此刻先包现有 `MacSettingsView`(已存在),Slice 5「我」迁移时再换成共享设置内容。「我」tab 里的设置入口通过 `SettingsLink`(macOS 14+)或 `NSApp.sendAction(Selector(("showSettingsWindow:")))` 打开同一窗口。

- [ ] **Step 3: 编译 macOS**(这两个文件 macOS-only 包 `#if os(macOS)`)— Expected PASS。
- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Features/Root/AppCommands.swift apps/pendingbot/Sources/Features/Root/SettingsScene.swift
git commit -m "mac: 原生菜单栏 commands + ⌘, 设置场景骨架"
```

### Task A8: 接线根视图

**Files:**
- Modify: `apps/pendingbot/Sources/PendingBotApp.swift`

- [ ] **Step 1: macOS @main 改接 WideRootView + Settings + commands** — `MacRootGate` 登录后渲染 `WideRootView` 取代 `MacRootView`;`Scene` body 加 `Settings { ... }` 和 `.commands { AppCommands() }`。保留 `.windowStyle(.hiddenTitleBar)` / `.windowResizability(.contentSize)`。

- [ ] **Step 2: iOS regular 分支指向 WideRootView** — `TabRoot` 的 `if sidebarLayout { PendingBotRegularRootView(...) }` 改为 `WideRootView(...)`;compact 分支 `TabView` 不动。`PendingBotRegularRootView` 暂留(下一步被 WideRootView 取代后删)。

- [ ] **Step 3: 编译两端 + 实跑** — macOS GUI build 跑起来,确认登录后是三列壳(中右列暂 placeholder,好友 tab 待 B5);iPad 模拟器跑起来确认 regular 进三列;iPhone 模拟器确认 compact 底部 tab 不变。三端各截一张图。
- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/PendingBotApp.swift apps/pendingbot/Sources/Features/Root/TabRoot.swift
git commit -m "ios+mac: 根视图接 WideRootView + Mac Settings/commands;iPad regular 收敛三列"
```

---

## Phase B — 好友/Bot 管理/选模型(Slice 1 样板)

### Task B1: 解锁好友片叶子组件

**Files:**
- Modify: `BotAvatar.swift`、`UserAvatar.swift`(A4 已动)、`BotVisibilityTag.swift`、`SwipeRevealRow.swift`、`EmptyHint.swift`、`TabHeaderBar.swift`、`SidebarTabBar.swift`(均在 `Sources/Components/`)

- [ ] **Step 1: 逐个摘锁 + 换垫片** — 每个文件:删首尾 `#if os(iOS)`/`#endif`、删 `import UIKit`;`Haptics.*` 保留(Mac 已有空操作孪生);`SwipeRevealRow.swift` 里 inline 的 `UINotificationFeedbackGenerator().notificationOccurred(.success)` 换成 `Haptics.success()`。`SwipeRevealRow` 的 `DragGesture` 是跨平台,留;若引用 `UIScrollView` 仅在注释里则无碍。

- [ ] **Step 2: 编译两端** — Expected PASS(叶子无业务依赖,先过)。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Components/{BotAvatar,BotVisibilityTag,SwipeRevealRow,EmptyHint,TabHeaderBar,SidebarTabBar}.swift
git commit -m "ios+mac: 解锁好友片叶子组件跨平台(摘 #if + 换 Haptics 垫片)"
```

### Task B2: 解锁 ModelPicker(含 arena 竞技场)

**Files:**
- Modify: `apps/pendingbot/Sources/Components/ModelPicker.swift`

- [ ] **Step 1: 摘锁 + 换垫片** — 删首尾 `#if os(iOS)`/`#endif`;`.navigationBarTitleDisplayMode(.inline)` ×2 → `.inlineNavTitle()`;`.textInputAutocapitalization` ×2 → `.platformAutocapitalization()`;`presentationDragIndicator` ×1 → `.platformDragIndicator()`;`Haptics.*` 保留。`ArenaModelPickerSheet` / `ArenaModelPoolEditor` / `PriceRangeSlider`(自定义 DragGesture 滑块,跨平台)随文件一起解锁。

- [ ] **Step 2: 编译两端** — Expected PASS。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Components/ModelPicker.swift
git commit -m "ios+mac: 解锁 ModelPicker 跨平台(含 arena 竞技场选模型)"
```

### Task B3: 解锁 BotManagement

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Friends/BotManagement.swift`

- [ ] **Step 1: 摘锁 + 换垫片 + 去 UIKit** — 删首尾 `#if os(iOS)`、删 `import UIKit`、删 `import CoreImage.CIFilterBuiltins`(收进 QRCode 垫片);`navigationBarTitleDisplayMode` ×9 → `.inlineNavTitle()`;`textInputAutocapitalization` ×6 → `.platformAutocapitalization()`;`keyboardType(.URL)` ×1 → `.platformKeyboard(.url)`;`presentationDragIndicator` ×2 → `.platformDragIndicator()`;`UIPasteboard.general.string = x` → `Clipboard.copy(x)`;`qrImage(for:) -> UIImage?`(用 CIFilterBuiltins+UIImage)整段 → `QRCode.image(_:)`,返回类型 `PlatformImage?`,展示处 `Image(platformImage:)`。`Haptics.*` 保留。

- [ ] **Step 2: 编译两端** — Expected PASS。
- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Features/Friends/BotManagement.swift
git commit -m "ios+mac: 解锁 BotManagement 跨平台(Clipboard/QRCode 垫片 + 摘 UIKit)"
```

### Task B4: FriendsTabView 拆 list/detail/compact 并 conform FeatureSurface

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Friends/FriendsTabView.swift`
- 可能 Create: `apps/pendingbot/Sources/Features/Friends/FriendsSurface.swift`(若拆出独立 surface 类型更清晰)

- [ ] **Step 1: 摘锁 + 换垫片** — 删首尾 `#if os(iOS)`;`navigationBarTitleDisplayMode` ×6 → `.inlineNavTitle()`;`textInputAutocapitalization` ×3 → `.platformAutocapitalization()`;`presentationDetents` ×1 → `.platformDetents(...)`;`presentationDragIndicator` ×6 → `.platformDragIndicator()`。

- [ ] **Step 2: 把内部 `NavigationSplitView` 拆成 list/detail 两半** — 现状:`FriendsTabView` 在 `sidebarLayout` 时自带 `NavigationSplitView`(list=好友/bot 列表,detail=选中项);compact 时 `NavigationStack` push。重构:抽出 `friendsListColumn(selection:)`(原 split 的 sidebar 内容)和 `friendDetailColumn(selection:)`(原 split 的 detail 内容),selection 类型 = 现有的 peer 选中标识(`kind:id` 组合,定成 `FriendSelection: Hashable`)。`compactRoot()` = 现有 `NavigationStack(path:)` 分支。让类型 conform `FeatureSurface`。

- [ ] **Step 3: 编译两端 + iPhone compact 实跑回归** — Expected PASS;iPhone 模拟器进好友 tab,确认 compact push 行为没回归(列表→点进→push,跟改前一致),截图。
- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Features/Friends/
git commit -m "ios+mac: FriendsTabView 拆 list/detail/compact 并 conform FeatureSurface"
```

### Task B5: 好友片插进 WideRootView + 删 Mac 平行实现

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Root/WideRootView.swift`
- Modify: `apps/pendingbot/Sources/Mac/MacRootView.swift`(friends 分支移除,改走共享 surface;或整体被 WideRootView 取代后删)
- Delete: `apps/pendingbot/Sources/Mac/Views/MacBotManagement.swift`
- Delete: `apps/pendingbot/Sources/Mac/Views/MacFriendsView.swift`
- Modify: `apps/pendingbot/project.yml` 若有显式文件引用(一般 xcodegen 按目录 glob,删文件后跑 `xcodegen` 即可)

- [ ] **Step 1: WideRootView 的 friends tab 接共享 surface** — content 列 = `FriendsSurface.listColumn(selection:)`,detail 列 = `FriendsSurface.detailColumn(selection:)`;⌘N(A7 的通知)在 friends tab 时触发建机器人 sheet(`CreateBotSheet`)。

- [ ] **Step 2: 删平行实现** — 删 `MacBotManagement.swift`、`MacFriendsView.swift`;`MacRootView` 若已全被 `WideRootView` 取代则连同删除(确认无其他 tab 仍依赖它的 placeholder 列;若依赖,保留 MacRootView 仅作其余 tab 的临时壳直到它们各自 slice —— 但 friends 分支必须改指共享 surface)。跑 `xcodegen`。

- [ ] **Step 3: 编译两端 + 三端实跑** —
  - macOS GUI build 跑起来:好友 tab → 看到真好友/bot 列表 → 建机器人 → **arena 竞技场选模型可用**(多模型池 + 价格/日期筛选),管理机器人、公开 slug、邀请链接/二维码都在。截图。
  - iPad 模拟器:同样进到三列 + arena 选模型,与 Mac 一致。截图。
  - iPhone 模拟器:compact 下建机器人/选模型/arena 不回归。截图。
- [ ] **Step 4: Commit**

```bash
git add -A apps/pendingbot/Sources/Mac/ apps/pendingbot/Sources/Features/Root/WideRootView.swift apps/pendingbot/project.yml
git commit -m "ios+mac: 好友片接 WideRootView;删 Mac 单模型阉割版平行实现"
```

### Task B6: 三端验证总检 + 账本

**Files:**
- Modify: `docs/progress.md`(顶部"最近对账"日期 + 本片状态)
- Modify: `docs/tech-debt.md`(若有 Option-II 退化或 Mac 上垫片 no-op 导致的体验缺口)
- Modify: 内置 Task 系统:更新 #212(方向已改为三端共享,标注好友片完成)

- [ ] **Step 1: 三端验收清单逐项过** — Mac/iPad/iPhone 三张选模型截图齐;arena 在三端都实测可用;iPhone 无回归。任一不过 → 回对应 task 修,不进账本。
- [ ] **Step 2: 记缺口** — 若某垫片 no-op 在 Mac 上造成可见体验缺失(如键盘类型、detents),或某处临时退 Option II,写进 `docs/tech-debt.md`(🟡)。
- [ ] **Step 3: 更账本 + Commit**

```bash
git add docs/progress.md docs/tech-debt.md
git commit -m "docs: 三端共享地基 + 好友片对账(progress/tech-debt)"
```

---

## Self-review(已对 spec 核过)

- **Spec 覆盖:** D1 真三列→A5/A6/B4;D2 宽屏统一+iPad 收敛→A8;D3 iOS-only 留单独→好友片不含 Call/扫码,QR 是"生成"(跨平台)非"扫描"(留 iOS);D4 Mac 设置窗口+「我」入口→A7;D5 菜单栏快捷键→A7;D6 Haptics 空操作→B1。垫片层覆盖勘查到的全部 iOS-only 计数(nav 标题/autocaps/键盘/detents/drag/剪贴板/QR/UIImage)。
- **占位扫描:** 无 TBD;每个换垫片步带了具体计数与目标符号。
- **类型一致:** `PlatformImage`(已有)、`PlatformImage.decode`(A4 定义,UserAvatar/B3 用)、`Clipboard.copy`(A2 定义,B3 用)、`QRCode.image`(A3 定义,B3 用)、`.inlineNavTitle()/.platformAutocapitalization()/.platformKeyboard(.url)/.platformDetents()/.platformDragIndicator()`(A1 定义,B2/B3/B4 用)、`FeatureSurface`(A6 定义,B4 conform)、`WideRootView`(A5 定义,A8/B5 用)、`TopTab`(复用现有)— 前后名一致。
- **顺序依赖:** A1–A4 垫片 → A5/A6 壳与契约 → A7/A8 接线 → B1 叶子 → B2/B3 解锁 → B4 拆分 → B5 接线删平行 → B6 验收。无前向引用未定义符号。
