# PendingBot

PendingBot IM 主客户端 —— iPhone + iPad + macOS 三端 SwiftUI Multiplatform 单工程。

详细设计文档（`docs/superpowers/specs/…`）是内部的，没有公开。源码注释里偶尔会引用
它们，读到断链的引用不必当成缺失。

## 平台分布

| 平台 | 状态 |
|---|---|
| **iPhone** | 完整功能（v1.0 主目标） |
| **iPad** | regular size class 三栏 view（`PendingBotRegularRootView`）已接入；还没把全部 tab 都搬进共享大屏壳 |
| **macOS** | 真实现，不是占位 —— `Sources/Mac/` 下是活的视图，作者自用级 |

> 这张表说的是**客户端各端的完成度**，跟功能本身跑没跑通是两回事。
> 后者见仓库根 README 的「状态」一节。

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

代码是从老的 `apps/ios/` + `apps/macos/PendingBot/`（占位）+ 老共享 SPM 合到这一个
单 xcodeproj 的。

iOS-only 的业务文件在自己顶部包 `#if os(iOS)`，让纯 Foundation / SwiftUI 的
Models / Storage / 部分 Networking / 部分 Components 自然进入 Mac build，
给 `Sources/Mac/` 的真实视图提供数据底座。

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

## 后端坐标

`Sources/Networking/HostedConfig.swift`。**后端不在这个仓库里**，
怎么填见 [`docs/building.md`](../../docs/building.md)。
