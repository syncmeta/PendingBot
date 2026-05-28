# PendingBot

PendingBot IM 主客户端 —— iPhone + iPad + macOS 三端 SwiftUI Multiplatform 单工程。

详细设计见 [`docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md`](../../docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md)。

## 平台分布

| 平台 | 状态 |
|---|---|
| **iPhone** | 完整功能（v1.0 主目标） |
| **iPad** | scaffold 完成；regular size class 三栏 view（`PendingBotRegularRootView`）已带过来，待后续 Phase 把"机组"以外的 tab 也接进共享大屏壳 |
| **macOS** | scaffold —— 占位 View；Mac 端 UI 在 Phase 2+ 实装 |

## 工程结构

```
apps/pendingbot/
├── project.yml                     # XcodeGen spec（三 destination: iOS + macOS）
├── Info.plist                      # 混合 iOS / macOS keys
├── PendingBot.xcodeproj            # 由 XcodeGen 生成（已 commit）
├── ExportOptions.plist             # TestFlight upload
├── scripts/                        # 资源抓取脚本
└── Sources/
    ├── PendingBotApp.swift         # @main，#if os(iOS) 和 #if os(macOS) 分支
    ├── Log.swift                   # 跨平台
    ├── Shared/                     # 跨平台 model + big-screen shell view
    ├── Components/                 # iOS UI 组件（整体 #if os(iOS) 包住）
    ├── Features/                   # iOS feature views（整体 #if os(iOS) 包住）
    ├── Models/                     # iOS-only API models（#if os(iOS) 包住）
    ├── Networking/                 # 网络层（#if os(iOS) 包住 —— 引用 UIKit/Supabase 流程）
    ├── Storage/                    # 本地存储（#if os(iOS) 包住）
    └── Resources -> ../Resources   # Assets.xcassets / xcstrings / xcprivacy
```

T0.1 的目标是**工程结构对齐 spec v2 的三端 multiplatform 方案**，把代码从老的 `apps/ios/` + `apps/macos/PendingBot/`（占位）+ `apps/shared/PendingBotShared/`（共享一小段）合到一个单 xcodeproj。

iOS 完整 code base 整体 `#if os(iOS)` 隔离，不在 scaffold 阶段重写跨平台。Mac 端 UI 在 Phase 2+ 实装（看 spec §3 「跨设备 SwiftUI」+ §12 三栏布局）。

## Build

工程通过 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 维护。每次改 `project.yml` 后跑 `xcodegen` 重新生成 `PendingBot.xcodeproj`。

```bash
cd apps/pendingbot

# 重新生成 xcodeproj（改完 project.yml 后）
xcodegen

# Build iPhone / iPad Simulator
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
    -destination 'generic/platform=iOS Simulator' build

# Build macOS
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
    -destination 'platform=macOS' build
```

## 老工程已删

- `apps/ios/PendingBot.xcodeproj` —— 老 iOS xcodeproj
- `apps/ios/PendingBot/` —— 老 iOS source（整体迁过来了）
- `apps/ios/PendingBotTests/` —— 老 iOS 测试（scaffold 阶段砍掉,后续按需重建）
- `apps/macos/PendingBot/` —— 老 Mac 占位 SPM 包
- `apps/shared/PendingBotShared/` —— 老共享 SPM（已并入 `Sources/Shared/`）

## 当前进度

- [x] **T0.1 Scaffold**（本工程结构 + 三端 build 通 + 老工程砍掉）
- [ ] T1+ Subject 模型 / Crew / 跨设备 SwiftUI 适配 / Mac UI（看 roadmap）

详见 [roadmap §3 T0.1](../../docs/superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md#t01-pendingbot-swiftui-multiplatform-工程脚手架)。
