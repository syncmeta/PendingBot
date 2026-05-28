# PendingCrew

PendingBot 协作平台的 coding agent 编排客户端，Mac + iPad 双端 SwiftUI Multiplatform 工程。

**定位**：独立、可开源、Codex Desktop 类比、本地 + 云端 crew 载体。可不登录 PendingBot 账号直接使用（BYOK 模式，只支持本地 crew）。

详细设计见 [`docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md`](../../docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md)，实施路线见 [`docs/superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md`](../../docs/superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md)。

## 平台分布

| 平台 | 能力 |
|---|---|
| **Mac** | 全功能：本地 crew（`local_host`）+ 云端 crew（`peer_device` / `fly_machine`） |
| **iPad** | 仅云端 crew：`peer_device`（遥控同账户 Mac）+ `fly_machine`（v1.1） |
| iOS | 不做。iOS 用户通过 PendingBot Crew Tab 遥控 |

## 工程结构

```
apps/pendingcrew/
├── project.yml                     # XcodeGen spec
├── Info.plist                      # 混合 iOS/macOS 配置
├── PendingCrew.xcodeproj           # 由 XcodeGen 生成（已 commit）
└── Sources/
    ├── PendingCrewApp.swift        # @main + 三栏/iPad 占位
    ├── Stores/                     # AppModel 等（Phase 1+ 加）
    ├── Services/                   # API client（Phase 1+ 加）
    ├── Support/                    # KeychainStore / Auth / DeepLink
    ├── Views/                      # 各栏的实际 View（Phase 2+ 加）
    └── Mac/LocalRunner/            # 本地 coding agent 子进程封装
                                    # #if os(macOS) 隔离（Phase 3 实装）
```

## Build

工程通过 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 维护。每次改 `project.yml` 后跑 `xcodegen` 重新生成 `PendingCrew.xcodeproj`。

```bash
cd apps/pendingcrew

# 重新生成 xcodeproj（改完 project.yml 后）
xcodegen

# Build Mac
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew \
    -destination 'platform=macOS' build

# Build iPad (simulator)
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build
```

## 当前进度

- [x] **T0.2 Scaffold**（本工程结构 + 双端 build 通 + 老工程砍掉）
- [ ] T1.x 身份地基
- [ ] T2.x Crew 核心
- [ ] T3.x 本地 crew 闭环
- [ ] T4.x 通信 + Bot 扩展
- [ ] T5.x BYOK + 整合

详见 [roadmap §3-§8](../../docs/superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md)。

## 老工程

`apps/macos/PendingCrew/`（老 SPM + 单 Mac target）在 T0.2 中已删。可复用代码（KeychainStore / PendingCrewAuthCredential / PendingCrewDeepLinkRoute）已迁过来；其余按 spec v2 在 Phase 1-5 重写。
