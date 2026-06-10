# 三端共享 UI 地基 — 设计 spec

**日期**: 2026-06-08
**分支**: `feat/tri-platform-ui`
**状态**: 设计已与用户对齐,待落实施 plan

## 背景与问题

PendingBot 是 iPhone / iPad / Mac 三端单 target(`supportedDestinations: [iOS, macOS]`)。当前实际共享情况:

- **逻辑底座全共享**:Networking / Storage / Models / `ModelCatalog` 等无平台守卫,三端同一份。
- **iPhone 与 iPad 已共享 UI**:整个 `Features/*` 锁在 `#if os(iOS)`;iPad 走 regular size class,直接复用同一批 `MessageTabView` / `FriendsTabView` / … 并在每个 tab 内部用 `NavigationSplitView` 自带分栏。
- **Mac 是另起炉灶的平行重写**:`Sources/Mac/*`(`MacRootView` + `MacBotManagement` + `MacConversationListColumn` + `MacChatView` + …),功能是 iOS 的阉割子集(典型:建机器人只能选单模型,没有 arena 竞技场)。

**根因不是技术约束,是当年省力一刀切**。`Features/*` 当初被整体包进 `#if os(iOS)`(project.yml 注释印证),并非真的离不开 iOS;实际 iOS-only 依赖面很小、很集中,全是薄 shim(haptics、导航标题模式、剪贴板、键盘类型、二维码位图、`presentationDetents`)。Mac 因此被迫平行重写,留下"两套 UI、Mac 永远慢一拍且功能缩水"的烂摊子。

**用户明确定调**:不计成本、一次性打好地基。默认全部三端共享(含 UI),只有 Mac 硬件/能力真没有的才单独留。不许省力优先 —— 当年就是省力才欠的债。

## 目标

1. 建一层完整的跨平台地基,让 `Features/*` 能逐个摘掉 `#if os(iOS)`,三端共用同一份业务 UI。
2. 宽屏(Mac + iPad)统一到"Mac 式三列":左侧边栏 tab + 中列表 + 右详情;窄屏(iPhone)保持底部 tab 栏 + push。
3. 以"好友 + Bot 管理 + 选模型"为第一片样板,验证地基,并让 Mac 立刻拿到与 iPhone/iPad 一字不差的能力(含 arena)。
4. Mac 拿到原生桌面外壳:菜单栏 + 快捷键 + ⌘, 设置窗口。

**非目标(本 spec 不含)**:消息/Crew/来信/我 各 feature 的迁移(各自后续独立 spec);语音通话上 Mac。

## 关键决策(已与用户拍定)

| # | 决策 | 取舍理由 |
|---|---|---|
| D1 | **真三列(Option I)**,每个 feature 拆出独立 list/详情列交给全局壳,不许退化成"窄轨 + 各 feature 自带分栏"(Option II) | 用户:不省力。Option II 的 Mac 原生度差一档(标题栏统一/列折叠)。若某大 feature 拆分代价过高,允许临时退 Option II 但必须记 tech-debt,不是默认 |
| D2 | **宽屏统一 Mac 式三列**;iPad 从现有"微信式底部嵌入 tab"收敛成桌面式左边栏。iPhone compact 不变 | 用户选定。预发布无存量用户,改导航无迁移成本 |
| D3 | **iOS-only 留单独**:语音通话 `Call/*`(Mac 先不做)、扫码/相机 `QRScannerView`、推送/VoIP。三端壳里以"Mac 不显示入口 / 空操作"处理,且必须是因为 Mac 真没这能力,而非图省事 | 用户:纯按功能划,Mac 没有的才留 |
| D4 | **Mac 设置 = 原生 ⌘, 独立窗口**;「我」里也有入口,两者指向同一个独立窗口 | 用户:要 Mac 原生习惯,但保留「我」入口 |
| D5 | **Mac 菜单栏 + 快捷键(⌘N 新建、⌘F 搜索等)在地基里一并做** | 用户:地基一并做了,别拖成尾巴 |
| D6 | **Haptics 类垫片在 Mac 上是空操作** —— 共享调用、Mac 空实现,而非排除整块 UI | 已有先例(`Haptics` macOS 孪生) |

## 架构

### 地基三件套

**1. 垫片层(扩展已有模式)**
项目已有 `Haptics`(Mac 空操作)/ `PlatformImage` / `Platform.isMac`。补齐剩余 iOS-only 面的跨平台垫片(导航标题模式、剪贴板、二维码位图生成、键盘类型、`presentationDetents`),全部归入 `Components/Platform*.swift`。feature 文件的改动 = 摘掉首尾 `#if os(iOS)` + 把零散 iOS-only 调用点换成垫片。

**2. 统一宽屏壳 `WideRootView`**
把现成、已验证的 `MacRootView` 三列骨架抽成跨平台共享壳,Mac 与 iPad-regular 共用;iPhone-compact 继续 `TabRoot` 的 `TabView`。三列 = 侧边栏 tab / 当前 tab 的列表列 / 当前 tab 的详情列。跨 tab 跳转沿用 `MacRootView` 现有的确定性 selection 状态机(无竞态)。

**3. 壳 ↔ feature 接口契约**
每个 feature 不再自带内部 `NavigationSplitView`,改为暴露三种装配:宽屏"列表列""详情列"(交给壳拼三列)+ 窄屏"compact 自包含 push 根"。宽屏选中态 hoist 到壳。一份业务 UI,两种装配。

### Mac 原生外壳

- **设置窗口**:⌘, 打开原生 Settings 场景;「我」里的设置入口指向同一窗口。「我」作为内容面仍在(账号/钱包/资料),设置/偏好抽进该窗口。
- **菜单栏 + 快捷键**:标准 Mac 菜单 + ⌘N(新建机器人/会话)、⌘F(搜索)等常用项。

## 拆解与顺序

整 app 范围,拆成地基 + 若干 feature 纵切,各自走 spec→plan→实现:

- **Slice 0 — 地基**(本 spec):垫片层 + `WideRootView` + 接口契约 + Mac 原生外壳。
- **Slice 1 — 好友/Bot 管理/选模型**(本 spec,样板):跨平台化 + 插三列壳 + 删 `MacBotManagement` 平行实现。Mac 拿到真·选模型(含 arena)、建/管机器人、公开 slug、邀请链接/二维码。
- **Slice 2 — 消息/会话**(后续 spec):`MessageTabView` + `ConversationView` 全家桶,最大一块。
- **Slice 3 — Crew**(后续 spec)。
- **Slice 4 — 来信 Envelope**(后续 spec)。
- **Slice 5 — 我/设置/钱包**(后续 spec):把设置内容真正搬进 D4 的原生窗口。
- **留 iOS-only**:语音 `Call/*`、扫码、推送/VoIP(D3)。

## 验证(不走捷径)

Slice 0 + Slice 1 "完成"的定义 = **三端实测**,不是"编译过":

1. Mac GUI 构建(Xcode,非 headless CLI —— 见用户 memory:headless 回落 ad-hoc 签名会挂)跑起来,进到好友 tab + 选模型界面截图,arena 可用。
2. iPad 模拟器跑起来,确认桌面式三列边栏 + 选模型一致。
3. iPhone 不回归:compact 底部 tab + push + 选模型照常。
4. 地基若有 Mac 上行为没对齐的(某垫片 no-op 导致体验缺失),记 `docs/tech-debt.md`。

## 风险

- **大 feature 拆 list/详情的工作量**:`MessageTabView`(~1500 行)、`FriendsTabView`(~2400 行)把分栏逻辑揉在内部,拆分是真功夫。好友片是第一次踩这条路,踩出来的拆法要沉淀成后续 slice 的模板。
- **接口契约定早了可能不贴后续 feature**:好友片只覆盖"列表+详情"型 feature;来信(feed→正文)、我(无可枚举列表)形态不同,契约要预留这两类,Slice 1 落地时一并验证形态覆盖。
- **退化成 Option II 的诱惑**:大 feature 拆分难时容易想走窄轨省力。纪律:退化必须记 tech-debt + 用户可见,不是默认。
