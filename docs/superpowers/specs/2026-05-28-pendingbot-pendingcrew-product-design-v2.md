# PendingBot 与 PendingCrew 产品落地设计 v2

日期：2026-05-28
状态：对齐完成，待 implementation
替换：`2026-05-27-pendingbot-pendingcrew-product-design.md`（老 spec 同步废弃）

---

## 0. 为什么是 v2

老 spec（v1，2026-05-27）跟实际产品意图差距很大，主要漏掉/写错以下决策：

1. PendingBot 是**主 IM 客户端**（三端 SwiftUI multiplatform），不是 crew 浏览器
2. PendingCrew 是**独立可开源**的 Codex Desktop 类客户端，**双端**（Mac + iPad）而非仅 Mac
3. PendingCrew 支持**未登录 BYOK 路径**，开源软件不能强制登录
4. **Subject 系统**（user + group_account）是核心，群账号轻量化、可临时
5. **Captain 机长**有四种来源（bot 发起自动当 / 用户已有 bot / 系统生成 / captain 派生子 crew 继承，见 §6.3.1）
6. **Crew DAG 责任比例**遵循"认父时定死、不允许相同、永远有拍板方"
7. **Fly Machine 云端 crew** 是 v1.1 完整做，不是永久预留
8. Runner v1 = Claude Code + Codex（**砍掉 Kilo**，砍掉 opencode）
9. **工作目录 / 标签 / 所在地** 是三个分离概念，老 spec 混成 "workspace"
10. **Bot 可以主动发起 crew**（新原子能力 + 人类确认）
11. **Session ↔ 群聊**通信规则细化（统一 @、整白板注入、tool 发群、世界观系统提示）

v2 是这一路决策对齐的 source of truth。后续任何 implementation 都以此 spec 为准；和这份冲突的老 spec / 老 plan 必须修订或废弃。

---

## 1. 顶层定位

### PendingBot

**人与 AI 协作的平台。**

类比：ChatGPT / Claude iOS 那一档 —— 三端 IM 主客户端，普通用户的日常入口。

形态：iOS / iPadOS / macOS 三端，SwiftUI Multiplatform 单工程。

### PendingCrew

**独立的、准备开源的、本地 crew 载体的专业工作台。**

类比：Codex Desktop / Claude Code Desktop 那一档 —— 给"想用 AI 写代码/干事"的开发者用的桌面客户端。

形态：macOS（全功能）+ iPadOS（仅云端 crew）—— iOS 不做 PendingCrew。

### 两者关系

**主 + 辅**：

- PendingBot 是"看见 crew"的入口（在群聊里看到 session 状态卡）
- 用户想深度看/操作 crew → **跳转**到 PendingCrew
- PendingBot **不做** runner 控制、DAG 索引、machine 管理
- PendingCrew **不做**普通 IM（除了 crew 内部群聊）

---

## 2. 平台分布

| | iOS | iPad | Mac |
|---|---|---|---|
| **PendingBot** | ✅ 完整 IM + Crew Tab | ✅ 完整 IM + Crew Tab | ✅ 完整 IM + Crew Tab |
| **PendingCrew** | ❌ 不做 | ✅ 仅云端 crew | ✅ 全功能（本地 + 云端） |

**关键约束**：iPad 不能跑本地 coding agent（无 `Process` API + 沙盒限制）→ iPad PendingCrew 只能玩云端 crew，本地 runner 模块用 `#if os(macOS)` 隔离。

**iOS 用户**想看 session 详情：通过 **PendingBot Crew Tab 的遥控器能力**（@session 发指令、看状态卡、批权限请求），不需要独立 PendingCrew iOS。

---

## 3. 技术基座

### SwiftUI Multiplatform 单工程

PendingBot 和 PendingCrew **各一个 SwiftUI multiplatform 工程**：

- **PendingBot**: 三端共一套 code base，destination = iOS + iPadOS + macOS
- **PendingCrew**: 双端共一套 code base，destination = iPadOS + macOS，本地 runner 模块用 `#if os(macOS)` 隔离

### Layout 策略

- **iPhone**: `TabView`，单栏
- **iPad / Mac**: `NavigationSplitView`，三栏（PendingCrew）或两栏（PendingBot）
- size class 自适应，不写"if iOS / if Mac"二分支

### 现状 → 目标改造

当前代码：

- `apps/ios/` — iOS xcodeproj
- `apps/macos/PendingBot/` — 独立 SwiftPM 包（占位）
- `apps/macos/PendingCrew/` — 独立 SwiftPM 包
- `apps/shared/PendingBotShared/` — 共享一小段

目标代码：

- `apps/pendingbot/` — 单 xcodeproj，三 destination
- `apps/pendingcrew/` — 单 xcodeproj，双 destination
- 共享 model / 协议放 SwiftPM 包，UI 直接共享

**v1.0 第一步就是这个重构**。先把架子打对，再写新功能 —— 不然每加一个功能都要在两套工程里重复。

---

## 4. 身份与 Subject 模型

### 4.1 Subject 双类

- **`user_account`** —— 个人账号
- **`group_account`** —— 群账号

每个 crew / temporary group / session / runner host / fly machine 都绑唯一 `responsible_subject_id`。这个字段决定**谁付钱、谁能看、谁能批权限请求**。

### 4.2 群账号定位

**轻量化、可临时。**

跟 Notion workspace 那种重资产**完全不同**。具体表现：

- 出门旅游临时建一个群账号都行（几个朋友 + 一个 captain bot 整理旅游信息）
- 家里就一台电脑共享 → 登录群账号最合适
- 公司团队/项目组 → 同样模型，没有特殊处理

PendingBot 定位 = **人与 AI 协作的平台**。任何协作平台都需要组织账号，但 PendingBot 的组织账号**比业界主流轻量得多**，因为协作群体可能是非常临时的。

### 4.3 群账号权限矩阵（α 简化版）

三级 role：`owner` / `admin` / `member`。**默认权限固定，v1 不允许自定义**。

| 操作 | owner | admin | member |
|---|---|---|---|
| 在群下任一 crew 里对话/看摘要 | ✅ | ✅ | ✅ |
| 创建群下的 crew | ✅ | ✅ | ✅ |
| 删除群下的 crew | ✅ | ✅ | 仅自己创建的 |
| **群钱包充值** | ✅ | ✅ | ✅ |
| 加 member / 踢 member | ✅ | ✅ | ❌ |
| 启动 / 销毁 Fly machine | ✅ | ✅ | ❌ |
| 创建 / 删除 captain bot | ✅ | ✅ | ❌ |
| **批准外部 crew 认本群下 crew 为父** | ✅ | ✅ | ❌ |
| **接受跨主体协作邀请**（本群被拉进别人 crew） | ✅ | ✅ | ❌ |
| **登录代表群账号**（扫码到 PendingCrew Mac/iPad） | ✅ | ✅ | ❌ |
| 加/踢 admin、转让 ownership、解散群 | ✅ | ❌ | ❌ |

**约束**：

- **单 owner**（v1 不做 multi-owner，转让足够解决继承场景）
- **无提现**：充进群钱包不能提出来。规避"金融服务"性质合规风险，简化产品
- **群账号 = 永远 unified billing**：群账号没有 BYOK 概念，BYOK 只活在 PendingCrew 未登录场景

### 4.4 Subject 扫码登录

- 用户在 PendingBot 本人账号已登录
- 在 PendingCrew Mac/iPad 上扫码 → 选择"**代表哪个 subject**"（本人 / 我有权限的某个群账号）
- Edge 校验权限 → 颁发 device grant token（含 subject scope）
- token 存 Keychain；后续所有请求带这个 token

**登录代表群账号需 owner/admin 权限**（见 4.3 表）。member 即使知道群存在也不能扫码代表群登录 PendingCrew 跑本机 agent。

---

## 5. PendingCrew 双轨配置

### 5.1 登录态

- 走 PendingBot **unified billing**（CF Unified Billing 主路径 + OpenRouter fallback）
- 可用 fly machine（云端 crew）
- 所有 crew 的费用从 `responsible_subject_id` 钱包扣
- captain bot 复用用户已有 bot 库

### 5.2 未登录态（BYOK）

- 用户自己填 **API key**（Anthropic / OpenAI / Gemini，各家 native key）
- **只能跑本地 crew**，不能开 Fly machine
- captain bot 从 PendingCrew 本机 captain 池里选 / 或新建
- 所有 LLM 调用直接用用户的 key 走原生端点

**这是 PendingCrew 作为"准备开源软件"的必要条件** —— 类比 Claude Code 的 "登订阅 or BYOK 二选一"。开源版本必须能不登录 PendingBot 就用。

### 5.3 双轨的边界

| | 登录态 | 未登录态 |
|---|---|---|
| 计费 | unified billing → subject 钱包 | BYOK 直扣用户 API key |
| Fly machine | ✅ 可用 | ❌ 禁用 |
| 云端 crew | ✅ | ❌ |
| 本地 crew | ✅ | ✅ |
| Captain bot | 用户已有 bot / 新建 | 本机 captain 池 / 新建 |
| 跨设备同步 | ✅ | ❌（本地 db） |

---

## 6. Crew 核心模型

### 6.1 Crew 定义

**Crew = 一组群聊 + coding agent 的权限边界。**

没有 crew 就不能启动 agent。crew 是人类显式创建的 `conversation_type = 'crew'` 的对话。

### 6.2 Crew 属性

每个 crew 有：

- `responsible_subject_id`（责任主体，可能是 user 或 group）
- **所在地**：本地 / 云端（fly machine id）
- **标签**：分类标签（轻量字符串，类似 Linear/Notion 的 tag。**注意：老 spec 叫"项目"，重命名为"标签"以避免和"工作目录"混淆**）
- **工作目录**：crew 默认 cwd（本地路径 / fly machine 内路径）
- captain bot id
- 父 crew 列表（DAG 边）
- 子 crew 列表（DAG 边）

### 6.3 Captain（机长）

每个 crew **必须有一个 captain bot**。captain 是 crew 的"代理人格"和"对父 crew 的代表"。

#### 6.3.1 Captain 来源

| 创建路径 | Captain 来源 |
|---|---|
| **Bot 在 PendingBot 群聊里主动发起 crew** | 发起的 bot 自动当 captain |
| **PendingCrew 直接建 crew（登录态）** | 创建面板选：从用户的 bot 好友里选 / 系统生成新 bot |
| **PendingCrew 直接建 crew（未登录态）** | 创建面板选：从已有 captain 选 / 系统生成新 bot |
| **某 crew 的 captain 主动创建子 crew**（`spawned_by_captain`） | 子 crew 的 captain 默认 = 父 crew 的 captain（父 captain 直接担任子 captain；走 `create_child_crew_inheriting_responsibility_*` RPC，迁移 `20260527090000`） |

> 注：第 4 种来源 `spawned_by_captain` 是 DAG 责任继承链路的实装结果（2026-06-01 对照代码补入，见 `docs/decisions.md` D4）。原 spec 只列了前三种。

#### 6.3.2 Captain 模型与计费

| 场景 | 模型 | 计费 |
|---|---|---|
| 用 PendingBot 已有 bot 当 captain | 跟该 bot 自己的模型配置 | 从 crew responsible_subject 钱包扣（PendingBot 现有 unified billing） |
| PendingCrew 新建的 captain（登录态） | 创建时选模型 | 从 crew responsible_subject 钱包扣 |
| PendingCrew 新建的 captain（未登录态） | 创建时选模型 | **BYOK，用用户填的 API key**，不能用 Fly |

#### 6.3.3 Captain 职责

- 接收本 crew 群聊消息
- 在父 crew 中作为成员存在（`member_kind='captain'`, `represents_crew_id=child_id`），代表本 crew
- 拆解父 crew 来的指令
- 向父 crew 发摘要（**不发完整聊天记录、不发完整 session 日志**）
- 创建子 crew
- 启动 session

#### 6.3.4 Captain 在 UI 中的呈现

- 头像旁有 captain 标识（小标签 / 角色色）
- 名字默认 = `<crew 名>的机长`，用户可改
- 可被 `@captain` mention 触发拆解/转述

### 6.4 Bot 主动发起 crew

**新原子能力（新 bot tool）**：`start_crew(name, scope, ...)`

- bot 在跟用户对话过程中判断"这事得拉个 crew 干"，调用此 tool
- **必须经过人类确认**才真正创建 crew（避免滥用扣钱）
- bot 发起的 crew 的 `responsible_subject_id`：
  - 1v1 对话：对面的用户
  - 群聊：该群（如果群对应一个 group_account） / 群里所有 user_account 中的发起方
- 发起的 bot 自动成为该 crew 的 captain

---

## 7. Crew DAG 与责任比例

### 7.1 DAG 结构

- **多父多子**，有向无环图
- 环检测：**数据库层 + 服务层双保险**（拒绝创建会形成环的边）

类比：公司多部门 + 小组可隶属多部门。

### 7.2 父子消息路由

- **父 → 子**：不自动进入子 crew。父说的话**留在父 crew 群聊白板**，子 captain 自己读、自己判断要不要拆解给子组
- **子 → 父**：由子 crew 的 captain 在父 crew 群聊里发**摘要**，不发完整聊天记录
- **父成员/人类可直接进子 crew 跟成员说话**（权限来自 DAG 边，不来自消息同步）

### 7.3 责任比例规则（v2 核心）

#### 规则 1 —— 责任比例**认父时定死**，不是事后协商

- crew C 当前由 subject X 100% 控制
- 现在 X 想把 C 认作 D 的父 crew（让 D 参与 C 的责任分配）
- **认父这一刻，X 自己决定保留多少比例**（>50% → X 仍是拍板方；<50% → D 拍板）
- 之后不能"协商重分配"，要改必须明确发起一次"修改责任比例"动作

#### 规则 2 —— **不允许相同 / 不允许平均**

- 任意两个 subject 在同一 crew 的比例**不允许相等**
- bot 协商比例时只能在"非均等合法解空间"内挑
- 这条规则的产品意图：**保证 crew 永远有一个明确的"占多数"的责任主体（拍板方）**，避免 captain 之间扯皮 / 模型幻觉时跟错指令

#### 规则 3 —— 同主体合并

- crew C 多父：父 A 责任主体 = X(40%) + Y(60%)，父 B 责任主体 = X(70%) + Z(30%)
- 合并到 C 时：X = 40+70 = 110，Y = 60，Z = 30
- 归一化到 100%：X(55%) + Y(30%) + Z(15%)

#### 规则 4 —— 跨主体确认

- 多父的责任主体集合**不同**时，**各方人类必须批准**
- 多父的责任主体集合**相同**时，**bot 自己协商无需人类**
- 群账号场景下"人类批准" = **走群权限矩阵**（admin+ 批，不需要全员）
  - 不会出现"旅游群有人手机没电卡住所有人"的情况
  - 因为内部权限由群主配置 admin 名单
- 个人账号场景下 = 本人批准

#### 规则 5 —— 拍板原则

- 每个 crew 永远有一个"占多数"的责任主体（**拍板方**）
- 当 captain 之间出现指令冲突 / 模型在多父消息里幻觉跟错时，**听拍板方的**
- 这是 bot 系统提示里必须强调的规则

### 7.4 跨主体协作场景

跨主体只出现于"**我创建/拥有的 crew，需要请别的人/群参与协作**"。

- 我把 crew C 认作 D 的父，但 D 属于另一个主体
- → 这是请别的主体来"领养" C 当子
- → 异步等对方人类批准（走对方主体的权限矩阵）
- → 不在线就等，这是产品本意的同步语义，**不是 bug**

---

## 8. Runner 模型

### 8.1 v1 支持的 runner kind

- ✅ **Claude Code**
- ✅ **Codex**
- ❌ ~~Kilo Code~~（不熟，砍掉降低复杂度，留 v1.x 再加）
- ❌ ~~opencode~~（同上）

### 8.2 Runtime Location（统一抽象）

每个 crew 有一个 `runtime_location` 字段，决定 agent 实际跑在哪台机器上。

#### 三种 location

| | `local_host` | `peer_device` | `fly_machine` |
|---|---|---|---|
| 跑在 | 当前设备本身（PendingCrew 所在机器） | 同账户的另一台设备（主要是 Mac） | Fly cloud machine |
| 适用场景 | Mac PendingCrew 直接跑本机 agent | iPad PendingCrew 把同账户 Mac 当云端 / Mac PendingCrew 遥控另一台 Mac | 任意端用云机器跑 agent |
| 工作目录 | 本机路径 | peer 设备本地路径（peer 端配） | Fly machine 内路径，自动 `mkdir` + 持久卷 |
| 算力计费 | 免费（用户自己的设备） | 免费（用户自己的设备） | Fly 时长走 `responsible_subject_id` 钱包 |
| 模型 token | unified billing 或 BYOK | unified billing（必须登录态） | unified billing（必须登录态） |
| 通信路径 | 本机 IPC | **edge 中转**（同 §9.6） | **edge 中转**（同 §9.6） |
| 未登录可用 | ✅ | ❌（需要账号同步） | ❌ |
| 阶段 | v1.0 | v1.0 | v1.1 |

#### 关键洞察：`peer_device` 和 `fly_machine` 是同一种东西

两者本质都是"**远程一台有 Process 能力的机器，本机只是控制面**"。复用同一套架构：

- 身份验证（账号同步 / device grant）
- 指令转发（edge channel + DO 或 realtime）
- 状态同步（session 进度 / mailbox / 事件）
- permission request 通道
- 白板注入

唯一区别：

- **计费**：peer 算力免费 / Fly 按时长扣钱包
- **机器生命周期**：peer 由用户开/关自己的 Mac / Fly 由用户在 PendingCrew 里开/关 machine

→ **v1.0 做完 `peer_device` 时，`fly_machine` 的架构基础也铺好了**。v1.1 主要剩 Fly API 集成 + 按秒计费 + machine 管理 UI，通信层是现成的。这是 v1.0 → v1.1 过渡非常自然的根本原因。

#### 选择 location 的产品入口

创建 crew / 创建 session 时，用户在面板上选 location：

- **Mac PendingCrew 用户**：默认 `local_host`，可选某台同账户 peer Mac 或（v1.1）`fly_machine`
- **iPad PendingCrew 用户**：默认 `peer_device`（选哪台同账户 Mac），或（v1.1）`fly_machine`
- **未登录 PendingCrew（BYOK）**：只能 `local_host`

### 8.3 工作目录模型

#### 8.3.1 三层

- **crew-level 默认工作目录**：crew 创建时绑定一个目录
- **session-level 可覆盖**：每个 session 创建面板可选：
  - 是否从新 worktree 起（勾上自动 `git worktree add` 临时分支目录）
  - 选哪个分支
  - 临时覆盖目录路径
- **不做自动 worktree 隔离**：用户自己用 git 管，PendingCrew 不操心

#### 8.3.2 类比

Claude Code Desktop 的"new conversation"面板 + Codex Desktop 的 session 配置 —— PendingCrew 要做出**相当于这两者的 session 设置面板**。

#### 8.3.3 云端工作目录

- 用户开一台 Fly machine → PendingCrew 在 machine 内 `/workspace/<crew-id>/` 自动 mkdir + 挂载持久卷
- machine 内可装多个 crew，各自独立子目录
- 用户不用手动选路径

### 8.4 本机子进程安全模型

**完全信任 + 最小 env 卫生**。

#### 8.4.1 完全信任

PendingCrew **不做沙盒**。跟用户自己开终端跑 `claude code` 一样。

**逻辑**：本机 agent 默认拥有用户登录账户的所有权限（能读 ssh key、能 git push、能调任何 API）。权限管理是 Claude Code / Codex **自己**关心的事（它们各自有 `--dangerously-skip-permissions` 之类的开关）。PendingCrew 只是一个遥控器，不在系统层强加 sandbox-exec / seatbelt。

明确告知用户："本机 agent = 你的完整登录用户权限。"

#### 8.4.2 最小 env 卫生

但有一条底线：**子进程的 env 不继承 PendingCrew 自己的 secret**：

- ❌ 不传：PendingBot device grant token、Keychain 里的 PendingCrew 凭据、任何 PendingBot 服务自己的 secret
- ✅ 透传：`PATH` / `HOME` / `SHELL` / `LANG` / 用户在 PendingCrew 设置里**自己配的 API key**（Anthropic_API_KEY 等，给 claude code/codex 用）

这不是沙盒，只是"别多此一举地把 PendingCrew 自己的 token 泄给子进程"。

#### 8.4.3 不设 timeout，但 Cancel 标配

- **不设 timeout**：大任务可能跑几十分钟，timeout 是 claude code/codex 自己关心的事
- **Cancel 必做**：用户在 PendingCrew 里点"停止" → 标准 `SIGTERM` + 几秒 grace + `SIGKILL` 兜底
- 这是 coding agent UI 标配，不算额外功能

### 8.5 Fly Machine 模型（v1.1）

- 用户级管理：用户可在 PendingCrew 里**开/关/销毁 machine**，看到自己的 machine 列表 + 配额 + 用量
- **一台 machine 可装多个 crew**（"云电脑"心智，几个 crew 共享一台机器）
- machine 规格用户选（CPU/RAM）
- Fly 计费按秒 → 转成对 subject 钱包的实时扣款
- machine 冷启动 / 休眠唤醒 UX 需打磨
- machine 上的 agent 调 LLM 走 unified billing（不暴露用户 API key 到云端 machine）

---

## 9. Session ↔ 群聊通信

### 9.1 群聊的定位

**沟通渠道 + 白板。**

群聊**不是** IO 日志倾倒地。详细工作交接在 session 窗口里做（"私聊"），不在群里占用空间。

### 9.2 用户 → Session 的指令投递

#### 统一 @ 体验

用户在群聊里 `@<session>` 发指令，**不论 session 是否在运行**：

| Session 状态 | 行为 |
|---|---|
| **运行中** | 消息进 session 的 prompt 队列（Claude Code / Codex 本身就有的 "queued prompt" 机制），当前轮结束后下一轮 session 看到 |
| **未运行** | 消息暂存，**下次启动 session 时自动注入** |

PendingCrew **不需要自己做"手动发指令"机制**，直接对接 claude code / codex 的 queue prompt CLI。

#### 整个群聊白板都注入 session 上下文

- 每次 session 进入新轮次时，**整个群聊白板**（不只是 `@self` 的部分）都注入到 prompt context
- → "在群聊里随便说一句"等同于"留在白板上"，session 下次轮次自然看到
- → 还要 `@session` 的意义：给一个**明确的"必看"信号**，防止 session 这一轮跑完就结束错过白板里关键指令

### 9.3 Session → 群聊

- session **只能通过专用 tool 主动发关键节点**：`post_to_crew(message)` 或类似
- 详细 IO（stdout/stderr/工具调用日志）**只在右侧 session 窗口**看，**不进群聊**
- 类比："工作中的具体细节在 IDE 里看，向群里同步只发关键节点"

### 9.4 Session 接收消息的过滤规则

每个 session 只接收：

- `@self` 的消息
- 没有明确 `@` 任何人的消息（视为广播给所有 session）

不接收：

- `@` 别的 session 的消息
- `@captain` 的消息（除非该 session 就是 captain）
- `@人类` 的消息

### 9.5 Session 系统提示（v1 必交付）

session 启动时注入的 system prompt 必须给一套**完整世界观**。最低交付内容：

1. **你是谁**：你是这个 crew 里的一个 session，运行在 Codex / Claude Code 里
2. **你的 IO 去哪了**：你的 stdout/stderr 显示在用户的 PendingCrew session 窗口右栏，**不会进群聊**
3. **群聊是什么**：群聊是 crew 的白板 + 沟通渠道，**不是你的 IO log**
4. **谁是人类**：当前 crew 里的人类成员有谁、各自 user_id
5. **谁是 captain**：本 crew 的 captain bot 是谁
6. **父/子 crew 关系**：有哪些父 crew、子 crew，各自责任主体是谁
7. **拍板方是谁**：本 crew 的责任比例分布，**冲突时听谁的**
8. **你怎么发消息到群里**：调 `post_to_crew(...)` tool，**只发关键节点**
9. **你怎么读群聊白板**：白板内容会在每轮 prompt 里自动注入，不用主动拉
10. **Permission Request 模式**：当前是自动还是手动模式，你能/不能做哪些动作要先请示

这份 system prompt 模板**是 v1 必交付物**，不能糊弄。

### 9.6 跨端遥控

> 📐 **概念合并**：本节描述的"跨端遥控"，和 §8.2 中的 `peer_device` runtime location 是**同一件事的两个面**：
>
> - 从 PendingBot / iPad 的角度看：「我在遥控同账户 Mac」
> - 从 crew 的角度看：「我跑在 `peer_device` 这个 location 上」
>
> v2 把这两种表达合并为同一个抽象，共享同一套 edge 通信架构。Fly Machine（`fly_machine` location）在 v1.1 复用这套架构，只多加 Fly API 集成和按时长计费。

PendingBot 和 PendingCrew 是**账号同步**的关系。同一账号登录后，所有端的 crew/session 视图共享同一个事实源（后端 edge 服务 + 数据库）。

#### 跨端能力矩阵

- **PendingBot 任意一端**（iPhone / iPad / Mac）可以遥控**同账号**登录的 PendingCrew（Mac / iPad）上的 crew：
  - 在群聊里 `@session` 发指令 → 后端推送到对应 PendingCrew → PendingCrew 转给本机 agent 队列
  - 批 permission request → 任意端按按钮，推送回 Mac PendingCrew 解锁 session
  - 看 session 实时状态 / 进度 / mailbox / 关键事件

- **PendingCrew iPad**（只云端 crew）可以遥控**同账号 PendingCrew Mac** 的本地 crew：
  - 跟上面一样的指令 / 批准 / 状态通道
  - iPad 用户可以在云端 crew 工作的同时，顺手批一下 Mac 上本地 crew 的 permission request

#### 架构层面

- 所有遥控指令走**后端 edge 服务**（Cloudflare Worker + Durable Object 或 realtime channel）
- 不依赖本机网络 / 局域网，跨地理位置 / 跨网络也工作
- **离线缓存**：PendingCrew Mac 离线时，iPhone 发的指令暂存到 edge，Mac 再次在线时拉取
- 计费：跨端发的指令依然走 crew 的 `responsible_subject_id` 钱包

#### 边界

- **跨端遥控 ≠ 跨账号**：只能遥控你自己账号（或你有 owner/admin 权限的群账号）下的设备
- **未登录 PendingCrew**（BYOK 模式）**不参与跨端遥控** —— 没有账号身份可以同步

---

## 10. Permission Request

### 10.1 模式

| 模式 | 行为 | 类比 |
|---|---|---|
| **自动**（默认） | agent 自由执行所有动作，不弹卡片请权限 | Claude Code 的 `--dangerously-skip-permissions` |
| **手动** | agent 做"高危操作"前**暂停**，在群聊弹卡片等批准，批准/拒绝后继续 | Claude Code 默认模式 |

### 10.2 用户切换

每个 session 设置里可切。crew-level 默认 = 自动。用户可在 crew 设置改全局默认 + 在 session 设置覆盖。

### 10.3 "高危操作"定义

由 claude code / codex 自己定义（它们各自的权限模型）。PendingCrew **不重新定义高危清单**，只在 agent 主动 `request_permission(...)` 时把请求转成群聊卡片。

### 10.4 卡片形态

- 在群聊里以特殊消息卡形式出现（不是普通消息）
- 显示：session 名 / 操作描述 / "批准" "拒绝" "查看详情"按钮
- 批准/拒绝按钮按当前 crew 权限矩阵显示（不是所有 member 都能批）

---

## 11. PendingBot UI（三端）

### 11.1 信息架构

- 消息 Tab（IM 主流）
- 好友 Tab
- **Crew Tab**（新）
- 来信 Tab
- 我 Tab

### 11.2 Crew Tab

Crew Tab 是普通群聊 UI grammar，不是 dashboard。包含：

- crew 列表（按最近活跃，**扁平**，不展示 DAG）
- 进入 crew → 群聊页面
- 群聊页面：消息流 / composer / @人/@session/@captain / session 状态卡 / 子 crew 摘要卡 / "在 PendingCrew 中打开"按钮

**Crew Tab 不展示**：

- 完整 DAG 折叠索引（在 PendingCrew 里）
- runner host 配置
- 完整 session 日志
- 工作目录文件树
- Fly machine 管理

### 11.3 PendingBot → PendingCrew 跳转

deep link：

```
pendingcrew://crew/<crew-id>
pendingcrew://crew/<crew-id>/session/<session-id>
pendingcrew://machine/<machine-id>
```

跳转目标：

- Mac PendingBot：直接 open PendingCrew Mac
- iOS/iPad PendingBot：显示“在 Mac/iPad 上打开 PendingCrew”提示 + 复制链接 + 二维码（让 Mac 端扫码定位）

**重要补充**：如果同账号在 Mac/iPad 上有 PendingCrew 已登录，iOS/iPad PendingBot **不一定要跳转** —— 可以直接通过跨端遥控（见 §9.6）完成大部分操作（发指令、批 permission、看状态）。跳转主要是为了**深度调试**（看完整 stdout/stderr、改工作目录、配 captain 等）。

---

## 12. PendingCrew UI（Mac + iPad）

### 12.1 三栏布局

#### 左栏：crew/标签索引

- **全局折叠 DAG 索引**：crew 树状展示，多父节点的 crew 在多个位置出现引用
- 按标签分组（标签 = 分类，4.x 里说的"项目"重命名）
- 最近 crew
- runner hosts（Mac 本机）
- Machines（v1.1：Fly machine 列表）
- 有求于你（permission request 待审批）
- 设置

#### 中栏：crew 群聊

- 跟 PendingBot Crew Tab **共享同一事实源**（同一份消息）
- 但比 PendingBot 多一些编排控件（创建 session 按钮、创建子 crew 按钮）
- 视觉上仍然是群聊 UI，不是 dashboard

#### 右栏：单 session 窗口

- 一次只显示**一个**选中的 session（v1 不做多窗口并排）
- 类比 Claude Code Desktop / Codex Desktop 的 session 详情区
- 内含：任务 brief / 状态 / 模型 / 工作目录 / mailbox / 事件流 / stdout-stderr / 上下文包 / 最新结果 / 补充指令输入框 / 启动/暂停/取消按钮

### 12.2 创建 Session 面板（重点）

类比 Claude Code Desktop 的 "new conversation" 面板。必须有：

- runner kind 选（Claude Code / Codex）
- 模型选
- 工作目录（默认 = crew 工作目录，可改）
- 是否从新 worktree 起（勾上 = 自动 `git worktree add`）
- 选分支
- 所在地（本地 / Fly machine，v1.1）
- 任务 brief
- 初始 prompt
- Permission Request 模式覆盖

### 12.3 项目/Machine 管理

- 左栏 Machines 分组（v1.1）：开新 machine / 看用量 / 关 machine / 看绑定的 crew
- 项目/标签管理：crew 编辑面板可改标签

---

## 13. 阶段分段

### 13.1 v1.0（核心闭环）

**目标**：本地 crew 端到端能跑，三端 IM 基础完整，发出去就能用。

**工作量预估**（一人）：8-10 周，每个数字 ±50%。

**必交付**：

1. PendingBot SwiftUI Multiplatform 三端基建重构（替换现 iOS xcodeproj + 砍现 Mac PendingBot 占位包）
2. PendingCrew SwiftUI Multiplatform 双端基建（Mac + iPad 共工程，iPad 跑空壳即可，本地 runner 模块 `#if os(macOS)`）
3. PendingBot 三端 IM 基础（消息 / 好友 / 来信 / 我 / Crew Tab）
4. Subject 系统（user + group_account）
5. 群账号扫码登录 + 权限矩阵（α 简化版）
6. Crew + Captain + DAG 完整数据模型 + UI
7. PendingCrew Mac 本地 crew 端到端：创建 crew / 选 captain / 配工作目录 / 创建 session / 启动 Claude Code 或 Codex / 看进度 / Cancel
8. Session ↔ 群聊通信全套规则（统一 @ / 整白板注入 / `post_to_crew` tool / 系统提示模板）
9. Permission Request 自动/手动模式
10. Bot `start_crew` tool + 人类确认 UI
11. 责任比例规则全套（认父时定 / 不允许相同 / 跨主体确认）
12. 未登录 BYOK 路径

### 13.2 v1.1（扩展）

**目标**：完整云端 crew + iPad 生产力工作台。

**工作量预估**：5-8 周。

**必交付**：

1. Fly Machine 集成：用户级 machine 开/关/销毁 / 规格选择 / 实时计费扣 subject 钱包（**注**：架构层 —— edge 通信、状态同步、permission request 通道、白板注入 —— 在 v1.0 做 `peer_device` 时已铺好；这里主要是 Fly API 适配 + 按秒计费 + machine 管理 UI）
2. 云端 crew 完整路径：crew 创建时选所在地、PendingCrew 在 machine 内 mkdir 工作目录 + 持久卷
3. iPad PendingCrew 完整体验（基于云端 crew，三栏布局 + 妙控键盘适配）
4. Machine 冷启动/休眠唤醒 UX

### 13.3 v1.x（后期）

- 自定义 RBAC（超出 owner/admin/member 三级）
- Multi-owner
- Kilo Code / 自定义 runner kind 插件
- iOS PendingCrew（如果有强需求）
- 复杂 merge conflict 处理
- 跨 crew session 依赖图可视化

---

## 14. 非目标（v1 明确不做）

- ❌ PendingCrew iOS
- ❌ PendingCrew 普通 IM（IM 全在 PendingBot）
- ❌ PendingBot 本机 runner 控制台
- ❌ Session 多窗口并排
- ❌ 子 crew 聊天记录自动同步到父 crew
- ❌ 通用企业 RBAC
- ❌ Kilo Code、opencode（v1 不做）
- ❌ 沙盒 / seatbelt 进程隔离
- ❌ Session timeout 上限
- ❌ 群账号提现
- ❌ Multi-owner 群账号
- ❌ 责任比例自由平均分配（结构性禁止）
- ❌ 子 crew 创建时强制全员确认（走主体内权限矩阵即可）

---

## 15. 老 spec / plan 处理

### 15.1 必须废弃

- ❌ `docs/superpowers/specs/2026-05-27-pendingbot-pendingcrew-product-design.md` —— 被本 spec 替换

### 15.2 必须修订（术语 + 决策同步）

- `docs/superpowers/specs/2026-05-27-crew-organization-model-design.md` —— 责任比例规则要换成本 spec 7.3 版本；subject 模型要加 group_account 轻量化定位
- `docs/superpowers/specs/2026-05-24-crew-temporary-groups-design.md` —— "workspace" 改"工作目录" + "项目"改"标签"

### 15.3 仍有效

- `docs/superpowers/plans/2026-05-24-subject-foundation.md` —— subject schema 基础设计仍用，群账号扫码登录细节需补
- `docs/superpowers/plans/2026-05-24-runner-host-schema.md` —— runner host schema 仍用
- `docs/superpowers/plans/2026-05-24-crew-dispatch-schema.md` —— session/mailbox/event schema 仍用

### 15.4 必须重写

- `docs/superpowers/plans/2026-05-27-pendingbot-multiplatform-shell.md` —— 改成 SwiftUI Multiplatform 单工程重构方案
- `docs/superpowers/plans/2026-05-27-pendingcrew-session-workbench.md` —— 改成 Mac + iPad 双端方案
- `docs/superpowers/plans/2026-05-27-local-crew-captain-foundation.md` —— captain 三种来源细化
- `docs/superpowers/plans/2026-05-27-pendingbot-crew-real-data.md` —— 删，被本 spec 的端到端规划取代

---

## 16. 自检清单

定稿前请用户挨条核对：

- [ ] PendingBot = 人与 AI 协作平台，三端 SwiftUI multiplatform IM 主客户端
- [ ] PendingCrew = 独立可开源 Codex Desktop 类客户端，Mac + iPad，iOS 不做
- [ ] PendingCrew 双轨：登录 unified billing / 未登录 BYOK 本地
- [ ] Subject 双类：user + group_account，群账号轻量化可临时
- [ ] 群账号权限 α 简化版：owner/admin/member 三级固定，owner 可转让
- [ ] 群钱包：充值全员可、无提现
- [ ] 登录代表群账号 owner+admin only
- [ ] Captain 三种来源（bot 发起自动 / 用户已有 bot / 系统生成）
- [ ] Bot 主动发起 crew 是新 tool + 必须人类确认
- [ ] Crew 三属性分开：所在地 / 标签 / 工作目录
- [ ] "项目" → "标签"重命名
- [ ] Crew DAG 多父多子，环禁止双保险
- [ ] 责任比例：认父时定死 + 不允许相同 + 永远有拍板方
- [ ] 跨主体确认走主体内权限矩阵（群账号 admin 即可）
- [ ] Runner v1：Claude Code + Codex（无 Kilo / opencode）
- [ ] 工作目录 crew-level 默认 + session 面板可覆盖（worktree / 分支）
- [ ] 沙盒：完全信任 + 最小 env 卫生
- [ ] 不设 timeout + Cancel 标配
- [ ] Session 通信：统一 @ / 整白板注入 / `post_to_crew` tool / 系统提示完整世界观
- [ ] Permission Request 自动/手动，默认自动
- [ ] v1.0 = 三端基建 + 本地 crew 闭环 + subject/captain/DAG MVP
- [ ] v1.1 = Fly Machine 完整 + iPad PendingCrew
- [ ] Fly 计费、machine 多 crew 共享、用户级管理
- [ ] **跨端遥控**：PendingBot 任意端可遥控同账号 PendingCrew；PendingCrew iPad 可遥控同账号 PendingCrew Mac；走 edge 中转；BYOK 未登录态不参与
- [ ] **Runtime Location 统一抽象**：`local_host` / `peer_device` / `fly_machine` 三种 location 共享同一套通信架构；v1.0 做完 peer 等于把 Fly 的通信层铺好

---

**Spec v2 完。**
