# PendingBot

PendingBot IM 主客户端 —— iPhone + iPad + macOS 三端 SwiftUI Multiplatform 单工程。

跑起来 / 配置的完整步骤见仓库根的 [`README.md`](../../README.md) 和 [`docs/self-hosting.md`](../../docs/self-hosting.md)。

> 详细的产品设计文档没有随代码一起公开。

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
    ├── Components/                 # 复用 UI 组件，平台差异用 #if 隔离
    ├── Features/                   # 业务 feature views
    ├── Mac/                        # macOS-only 入口与视图
    ├── Models/                     # API / 本地 model
    ├── Networking/                 # API、缓存、实时与登录服务
    ├── Storage/                    # 本地存储、Keychain、账号状态
    ├── Stores/                     # 小型状态/字典 store
    └── Resources -> ../Resources   # Assets.xcassets / xcstrings / xcprivacy
```

T0.1 已把代码从老的 `apps/ios/` + `apps/macos/PendingBot/`（占位）+ 老共享 SPM 合到一个单 xcodeproj。

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
- 老共享 SPM —— 已并入当前单工程并删除
