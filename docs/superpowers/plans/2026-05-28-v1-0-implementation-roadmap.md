# PendingBot + PendingCrew v1.0 Implementation Roadmap

日期：2026-05-28
基于 spec：[`2026-05-28-pendingbot-pendingcrew-product-design-v2.md`](../specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md)
状态：草案，待评审

---

## 0. 这份文档是什么

把 spec v2 §13.1 的 12 项 v1.0 必交付 + 新增的"跨端遥控 / peer_device 通信架构"，拆成可执行的 6 个 phase / 20+ 个 task，标依赖关系和粗估时。

不是 spec 的细化，是**做事顺序**。任何细节决策仍以 spec v2 为准。

---

## 1. 阶段总览

| Phase | 内容 | 预估 | 关键交付 |
|---|---|---|---|
| 0 | 基础建设 | 2 周 | SwiftUI Multiplatform 工程脚手架（PendingBot 三端 + PendingCrew 双端） |
| 1 | 身份地基 | 2 周 | Subject + 群账号 + 扫码登录 + PendingBot 三端基础壳 |
| 2 | Crew 核心 | 2 周 | Crew/Captain/DAG schema + 责任比例规则 |
| 3 | 本地 crew 闭环 | 2 周 | PendingCrew Mac 本机跑 Claude Code / Codex 完整闭环 |
| 4 | 通信 + Bot 扩展 | 2-3 周 | Session ↔ 群聊通信 + Permission + Bot start_crew + 跨端遥控 |
| 5 | BYOK + 整合 | 1-2 周 | PendingCrew 未登录 BYOK + 端到端 QA |

**总计 11-13 周（一人，每个数字 ±30%）**。比 spec §13.1 原估的 8-10 周多 1-3 周，因为加上了跨端遥控架构 + 老 plan 修订工作。

---

## 2. 依赖关系图

```
                    Phase 0: 基建
                    ├─ T0.1 PendingBot Multiplatform
                    └─ T0.2 PendingCrew Multiplatform
                              │
                              ▼
                    Phase 1: 身份地基
                    ├─ T1.1 Subject schema  ──────────┐
                    │       │                          │
                    │       ▼                          │
                    ├─ T1.2 群账号权限矩阵 ───┐        │
                    │                          ▼        │
                    ├─ T1.3 群账号扫码登录                │
                    └─ T1.4 PendingBot 三端 IM 基础壳 ◀┘
                              │
                              ▼
                    Phase 2: Crew 核心
                    ├─ T2.1 Crew schema 扩展
                    ├─ T2.2 Captain（三种来源）
                    ├─ T2.3 DAG + 环检测
                    └─ T2.4 责任比例规则
                              │
                              ▼
                    Phase 3: 本地 crew 闭环
                    ├─ T3.1 Claude Code runner
                    ├─ T3.2 Codex runner
                    ├─ T3.3 工作目录三层
                    ├─ T3.4 子进程安全
                    └─ T3.5 Session 面板 UI
                              │
                              ▼
                    Phase 4: 通信 + Bot
                    ├─ T4.1 Session ↔ 群聊通信
                    ├─ T4.2 Session 系统提示模板
                    ├─ T4.3 Permission Request
                    ├─ T4.4 Bot start_crew tool
                    └─ T4.5 跨端遥控 / peer_device 架构
                              │
                              ▼
                    Phase 5: BYOK + 整合
                    ├─ T5.1 PendingCrew 未登录路径
                    ├─ T5.2 双轨路由
                    └─ T5.3 端到端 QA
```

横向并行机会：

- T0.1 / T0.2 可并行
- T1.1 完成后 T1.2 / T1.4 可并行（前者改数据库 + edge，后者改 UI）
- T3.1 / T3.2 可并行（两个独立 runner）
- T4.1-T4.4 部分可并行（T4.5 需要 T4.1 接口稳定后再做）

---

## 3. Phase 0：基础建设（2 周）

### T0.1 PendingBot SwiftUI Multiplatform 工程脚手架

**目标**：新建 `apps/pendingbot/`，单 xcodeproj，三 destination（iOS / iPadOS / macOS），三端共一套 SwiftUI code。

**当前状态**：
- `apps/ios/PendingBot.xcodeproj` — iOS 完整
- `apps/macos/PendingBot/` — Mac 占位 SwiftPM 包（4/5 tab 是 placeholder）

**具体动作**：
- 新建 `apps/pendingbot/PendingBot.xcodeproj`，三 destination 配置
- 把 `apps/ios/PendingBot/` 全部 source 迁过来，整理进当前 `Sources/{Components,Features,Mac,Models,Networking,Storage,Stores}` 结构
- iOS/Mac-only 文件用 `#if os(iOS)/macOS` 隔离，**避免 destination 二分支用 if-else 思维**
- 把老共享 SPM 内容合并到 `apps/pendingbot/`
- 砍 `apps/macos/PendingBot/`（占位包，没保留价值）
- 砍 `apps/ios/PendingBot.xcodeproj`（迁移完成后）
- 更新所有 build script / deploy 脚本 / CI

**风险**：iOS code base 大，xcconfig / signing / Info.plist 三端独立配置容易踩坑

**估时**：3-5 天

**依赖**：无

---

### T0.2 PendingCrew SwiftUI Multiplatform 工程脚手架

**目标**：新建 `apps/pendingcrew/`，单 xcodeproj，双 destination（iPadOS / macOS）。

**当前状态**：`apps/macos/PendingCrew/` — Mac SPM 包 + xcodeproj，16 个 swift 文件中约 30% 可复用（API client / Keychain / device-login 流程），其余按 spec v2 要重写。

**具体动作**：
- 新建 `apps/pendingcrew/PendingCrew.xcodeproj`，双 destination
- 保留可复用代码：`PendingBotAPI.swift` / `KeychainStore.swift` / 部分 model 类型 / `PendingCrewAuthCredential.swift`
- 重写：所有 View / AppModel（spec v2 §12 三栏结构）
- 本地 runner 模块（`LocalCodingAgentRunner.swift` + `LocalCodingAgentProfile.swift`）用 `#if os(macOS)` 隔离
- iPad 上初始版本是空壳（创建 crew 提示"需要 peer_device 或 fly_machine"，但 T4.5 之前都是占位）
- 砍 `apps/macos/PendingCrew/`

**风险**：原 `AppModel` 的 10+ `@Published` dict 爆炸要重组成 `CrewDetail` 结构体（spec §6.2 模型）

**估时**：2-3 天

**依赖**：无，可与 T0.1 并行

---

## 4. Phase 1：身份地基（2 周）

### T1.1 Subject schema

**目标**：数据库支持 `user_account` + `group_account` 两种 subject，所有现有实体绑 `responsible_subject_id`。

**参考**：已有 plan [`2026-05-24-subject-foundation.md`](./2026-05-24-subject-foundation.md) 定义了大致 schema，但 group_account 的**轻量化定位**（spec v2 §4.2）需 review 后修订该 plan。

**具体动作**：
- 迁移：`subjects` 表（id, kind, display_name, created_by, created_at）
- 迁移：`group_subject_members` 表（subject_id, user_id, role, granted_by, granted_at），role = owner/admin/member
- 迁移：`subject_wallets` 表（subject_id, balance, currency）
- 现有 `bots` / `conversations` 加 `responsible_subject_id` 外键
- RLS 策略：subject 内权限按 role 配
- 回填脚本：现有用户都生成一个 `user_account` subject，现有 bot/conversation 绑定到 owner 的 user subject

**估时**：2 天

**依赖**：无

---

### T1.2 群账号 + 权限矩阵

**目标**：群账号 owner/admin/member 三级 + ownership 转让 + spec v2 §4.3 表格的 11 条操作权限。

**具体动作**：
- 迁移：`group_subject_members.role` enum 落库
- RPC：`grp_transfer_ownership(group_id, to_user_id)` —— 单 owner 转让
- RPC：`grp_promote_to_admin(group_id, user_id)` / `grp_demote_admin(group_id, user_id)`
- RPC：`grp_add_member(group_id, user_id)` / `grp_remove_member(group_id, user_id)`
- 权限矩阵 11 条操作的服务层守卫（每条 API 入口处检查角色）
- 钱包：充值所有 role 都可（spec §4.3 修正）；提现完全不做（schema 不留接口）

**估时**：2 天

**依赖**：T1.1

---

### T1.3 群账号扫码登录

**目标**：用户在 PendingBot 登录后，扫码代表"某个 subject"登录到 PendingCrew，token 含 subject scope。

**具体动作**：
- Edge：`POST /v1/device-login/challenges` 增加 `subjectId` 字段（可选；不传 = 个人 subject）
- Edge：校验当前用户是否有权代表该 subject（subject_id 的 role ≥ admin）
- Edge：device grant token JWT 含 `subject_id` claim
- iOS PendingBot：扫码授权页加"选择代表哪个 subject"步骤（个人 / 我有权限的群）
- Mac/iPad PendingCrew：扫码 UI + token 存 Keychain（key 用 `device-grant`，删除遗留的 `worker-jwt`/`debug-worker-jwt`）
- 退出登录清 token + 群账号身份切换

**估时**：3 天

**依赖**：T1.1, T1.2, T0.2

---

### T1.4 PendingBot 三端 IM 基础壳

**目标**：Mac / iPad 上 PendingBot 跑起来，普通 IM 流程（消息 / 好友 / 我 / 来信）能用，Crew Tab 暂时空占位（Phase 2 之后实装）。

**具体动作**：
- 三端登录 + 同步现有 iOS 已有的对话/消息/好友数据
- iPad 上 `NavigationSplitView` 双栏（会话列表 + 消息流）
- Mac 上 `NavigationSplitView` 三栏（会话列表 + 消息流 + 详情）
- iOS 上 `TabView` 不变
- Size class 自适应
- iOS-only 功能（VoIP / PushKit / CallKit）用 `#if os(iOS)` 隔离
- Crew Tab 在三端都有，但内容是"v1 Crew Tab 即将上线"占位
- 测试：iPad / Mac 上能登录、能聊天、能看好友

**估时**：5 天

**依赖**：T0.1, T1.1（账号登录链路）

---

## 5. Phase 2：Crew 核心（2 周）

### T2.1 Crew schema 扩展

**目标**：Crew 数据模型支持 spec v2 §6.2 的全部属性。

**具体动作**：
- 迁移：`crews` 表加 `runtime_location` (local_host/peer_device/fly_machine), `tag`(varchar), `working_directory` (text)
- 迁移：`crew_parent_links` 表（child_crew_id, parent_crew_id, child_share_bps, created_at）
- 迁移：`crew_responsibility_shares` 表（crew_id, subject_id, share_bps）持久化解析结果
- 迁移：删掉老 `project_id`（如果存在），重命名为 `tag`
- 现有 `2026-05-24-crew-temporary-groups-design.md` 的部分 schema 仍用，需修订

**估时**：2 天

**依赖**：T1.1

---

### T2.2 Captain（三种来源）

**目标**：每个 crew 有一个 captain bot，支持三种来源（bot 发起自动 / 用户已有 bot / 系统生成）。

**具体动作**：
- 迁移：`crews.captain_bot_id` 外键
- 迁移：`temporary_group_members` 加 `member_kind` enum (`human`/`bot`/`captain`)，captain 行额外有 `represents_crew_id`
- 创建 crew RPC：`create_crew(name, captain_source, captain_bot_id?, captain_template_id?)`
- 三种 captain 来源的 UI 入口：
  - bot 发起 → 由 T4.4 `start_crew` tool 填
  - 用户已有 bot（登录态）→ PendingCrew 创建 crew 面板里选
  - 系统生成 → "新建 captain" 表单（模型 / 名字 / 头像）
- 未登录态：本机 captain 池（SQLite 本地存）+ "新建 captain"

**估时**：3 天

**依赖**：T2.1

---

### T2.3 DAG + 环检测

**目标**：crew 多父多子，环禁止（数据库 + 服务层双保险）。

**具体动作**：
- 迁移：`crew_parent_links` 加唯一约束 + 防环 trigger（递归 CTE 检查）
- 服务层：`crew_attach_as_child(child_id, parent_id)` RPC，调用前先递归检查是否构成环
- UI：在 PendingCrew crew 详情里看到父 crew / 子 crew 列表 + "添加父 crew" 按钮（弹选择）

**估时**：3 天

**依赖**：T2.1

---

### T2.4 责任比例规则全套

**目标**：实现 spec v2 §7.3 的 5 条规则。

**具体动作**：
- 规则 1（认父时定）：`crew_attach_as_child(child, parent, child_keeps_bps)` 必须传明确比例
- 规则 2（不允许相同）：服务层检查任意两个 subject 比例不等；bot 协商时调 RPC `propose_split(subjects)` 返回非均等切分
- 规则 3（同主体合并）：父合并到子时 RPC 计算 `merge_and_normalize(parent_shares[])` 返回归一化结果
- 规则 4（跨主体确认）：判断"父之间责任主体集合"是否变化，变化时需要相应主体的人类批准（走主体权限矩阵）
- 规则 5（拍板原则）：crew 始终有一个 `tiebreaker_subject_id` 字段（占多数的 subject），bot 系统提示注入
- 测试：单元测试覆盖各种父子组合 + 边界情况（90/10、55/45、33/33/34 等）

**估时**：3-4 天（这部分逻辑复杂，需要扎实测试）

**依赖**：T2.1, T2.3

---

## 6. Phase 3：本地 crew 闭环（2 周）

### T3.1 Claude Code 本地 runner 适配

**目标**：PendingCrew Mac 能起一个 Claude Code 子进程，把 crew 任务跑起来。

**具体动作**：
- `LocalCodingAgentProfile` 重写，删 hardcode 的 opencode/kilo
- Claude Code 命令行模板：`claude` + 任务 prompt（确认实际 CLI 参数）
- queue prompt 适配（claude code 的 `claude --append-prompt` 或类似）
- stdout/stderr 实时流到 session 窗口
- 子进程结束 → 解析 exit code + 写 session_events

**估时**：3 天

**依赖**：T2.2 (captain), T0.2

---

### T3.2 Codex 本地 runner 适配

**目标**：同上，针对 Codex。

**具体动作**：基本同 T3.1，但 Codex 命令行接口跟 Claude Code 不同，需要单独适配。

**估时**：3 天

**依赖**：T2.2, T0.2，可与 T3.1 并行

---

### T3.3 工作目录三层

**目标**：spec v2 §8.3 工作目录模型 —— crew-level 默认 + session 面板可覆盖（worktree / 分支）。

**具体动作**：
- Crew 创建/编辑 UI：选默认工作目录（文件夹选择器）
- Session 创建面板：
  - "使用 crew 默认目录" / "选其他目录" / "新 worktree"（git）
  - 选分支（如果是 git repo）
- `git worktree add` 调用封装
- 持久化每个 session 实际使用的 cwd

**估时**：2-3 天

**依赖**：T2.1（crew schema 有 working_directory 字段）

---

### T3.4 子进程安全

**目标**：spec v2 §8.4 — 完全信任 + 最小 env 卫生 + Cancel。

**具体动作**：
- `Process.environment` 显式 set 白名单（PATH/HOME/SHELL/LANG + 用户配的 API key），不继承
- Cancel：用户按"停止"→ SIGTERM + 5 秒 grace + SIGKILL
- 不设 timeout
- "本机 agent = 完整登录用户权限" 在 PendingCrew 首次启动时弹一个 disclosure

**估时**：1-2 天

**依赖**：T3.1 或 T3.2 任一完成

---

### T3.5 Session 创建面板 UI

**目标**：PendingCrew 创建 Session 面板完整实现（spec v2 §12.2）。

**具体动作**：
- runner kind 选（Claude Code / Codex）
- 模型选（动态拉用户已配模型列表）
- 工作目录（默认 = crew 工作目录，可改）
- 是否新 worktree + 分支选
- 所在地（local_host / peer_device，T4.5 完成后 + fly_machine 在 v1.1）
- 任务 brief + 初始 prompt 输入框
- Permission Request 模式（继承 crew 默认或覆盖）

**估时**：3 天

**依赖**：T2.1, T3.3

---

## 7. Phase 4：通信 + Bot 扩展（2-3 周）

### T4.1 Session ↔ 群聊通信

**目标**：spec v2 §9 全套规则 —— 统一 @、整白板注入、`post_to_crew` tool。

**✅ 实现状态（2026-06-15，`feat/crew-comms-rework` 已合 main `5068cc04`，见 progress.md 同日条目）**：
基础件早落（#166–169：mailbox RPC 迁移 / edge 端点 / world-model prompt / post_to_crew tool）；
本次重做把剩下的接通 —— 入站 @（人 @session/@captain → `resolveRecipientSessions` 定向落
`session_mailbox_items`）、出站 @ + reply（session `post_to_crew` 带 mentions/reply_to）、白板
发送者显示名、去轮询（本地进程内事件 / 远端复用 `RealtimeHubDO`，**未新建 DO**）、composer @ picker
+ 本地 @ 直接唤醒 idle session、对消息回复自动 @ 原发送者 + 可见引用。**"session 接收过滤 + 远端
唤醒"那半（下面列表最后一条）代码就位但 dormant**，卡 block-3 本地↔edge 绑定（见 tech-debt + #373/#297）。

**具体动作**：
- 数据库：`session_mailbox` 表（session_id, message_id, status, queued_at）— ✅ 已建（`session_mailbox_items`）
- 用户在群聊 @session：消息进 session mailbox — ✅ 已接通
- 每次 session 进入新轮次：
  - 拉完整 crew 群聊消息（按时间序）注入 prompt context — ✅
  - 拉 mailbox 待处理消息追加到 prompt — ✅
- `post_to_crew(message)` tool：session 调用 → 写一条 crew 消息（发件人 = session）— ✅（已扩 mentions/reply_to）
- session 接收过滤：只收 `@self` + 无 `@` 消息 — ⏳ 代码就位但 dormant（卡 block-3）

**估时**：4 天

**依赖**：T2.1, T3.1（runner 跑起来后才能挂 tool）

---

### T4.2 Session 系统提示模板

**目标**：spec v2 §9.5 的 10 条世界观，写成一份 prompt template。

**具体动作**：
- 新文件 `apps/edge/prompts/zh/session-world-model.md` + en 版
- 用 prompt-loader 通道注入（按用户 memory 规则，不硬编码）
- 模板变量：crew 名、captain 名、人类列表、父子 crew、拍板方、Permission Request 模式
- session 启动时由 edge 渲染填值 → 传给 PendingCrew → PendingCrew 当作 system prompt 注入 agent CLI

**估时**：2 天

**依赖**：T2.4（拍板方信息）, T4.1

---

### T4.3 Permission Request 模式

**目标**：spec v2 §10 自动/手动模式 + 群聊卡片。

**具体动作**：
- Crew/Session 配置：`permission_mode` enum (auto/manual)
- 手动模式下，agent 发起 `request_permission(...)` → 暂停子进程（claude code/codex 自身机制）
- Edge 接到 request → 写 `permission_requests` 表 + 推群聊一条特殊卡片消息
- 群聊里相关权限的 user（看 spec §4.3 矩阵）能看到"批准 / 拒绝 / 详情"按钮
- 用户点批准 → Edge 通知 PendingCrew → 解锁子进程
- UI：群聊里特殊消息渲染 + PendingBot/PendingCrew 都要支持

**估时**：3 天

**依赖**：T4.1

---

### T4.4 Bot start_crew tool

**目标**：spec v2 §6.4 — bot 主动发起 crew 的新原子能力 + 人类确认 UI。

**具体动作**：
- 新 tool def `start_crew` in `apps/edge/src/lib/bot-reply/tools/start-crew.ts`
- 参数：`name`, `tag`, `working_directory`, `parent_crew_id?`, `members?`
- Tool 执行：写一条特殊"crew 创建提议"消息进当前对话
- 消息卡片有"确认 / 取消"按钮
- 用户确认 → Edge 执行实际 crew 创建（自动把发起 bot 设为 captain）
- 写入相应的 group_subject 钱包扣费意向

**估时**：2-3 天

**依赖**：T2.2（captain 关联）

---

### T4.5 跨端遥控 / peer_device 通信架构

**目标**：spec v2 §8.2 + §9.6 — 同账户跨端遥控通过 edge channel + DO/realtime。

**具体动作**：
- 选型：edge 用 Cloudflare Durable Object + WebSocket realtime channel（参考现有 `RoomVoiceDO` 模式）
- DO 实例：`SessionProxyDO`，每个 active session 一个，订阅方 = 所有同账户在线端 + session 所在 runner host
- 协议：
  - `session.command` (任意端 → DO → runner)：发指令到 session mailbox
  - `session.state` (runner → DO → 任意端)：进度、新事件、新输出
  - `permission.request` (runner → DO → 任意端)：批准请求广播
  - `permission.decision` (任意端 → DO → runner)：批准结果
- iOS PendingBot / iPad PendingCrew / Mac PendingBot：客户端订阅 DO
- PendingCrew Mac 作为 runner：发布到 DO + 接收命令
- 离线缓存：DO 在 runner 离线时把命令存 KV，runner 上线时拉取

**估时**：5 天（架构核心，要打磨）

**依赖**：T4.1（消息通信接口稳定）, T4.3（permission 通道）

---

### T4.6 iOS PendingBot Crew Tab v2 重做

**目标**：spec v2 §11.2 — 把 iOS Crew Tab 从 codex 旧 dashboard 风格改成**普通群聊 UI grammar**，跟 spec v2 §11.2 描述一致；iPad/Mac PendingBot 的 Crew Tab 沿用同一份代码（multiplatform 共享）。

**当前状态**：`apps/pendingbot/Sources/Features/Crew/CrewTabView.swift` 是 codex 之前实现的 878 行 dashboard（@State 字典爆炸：crews / runnerHosts / sessionsByCrew / linksByCrew / membersByCrew / announcementsByCrew），调老 `/v1/crew`（单数）endpoint；T1.3 D agent 只塞了 `SubjectPickerSheet`（扫码批准 PendingCrew 登录的入口），主体没动。该 task 漏在原 roadmap 里 —— 2026-05-28 session cleanup pass 时补加。详见 `docs/tech-debt.md` 同名条目。

**具体动作**：
- 重写 Crew Tab：crew 列表（扁平，按最近活跃排序，类似微信会话列表）+ tap 进 crew → 群聊页面
- 群聊页面用现有 ConversationView 风格作底，但 crew 上下文：
  - 消息流 + composer
  - `@人` / `@session` / `@captain` mention
  - session 状态卡（行内）
  - 子 crew 摘要卡 + "进入子 crew" 按钮
  - "在 PendingCrew 中打开" 跳转按钮（Mac 端用 deep link，iOS 端展示二维码/复制）
  - 跨端遥控状态指示（取决于 T4.5 完成度）
- 切到新 `/v1/crews` endpoint（F agent 在 commit `0e619241` ship 的），停掉老 `/v1/crew` 调用
- 保留 SubjectPickerSheet（T1.3 入口）
- Multiplatform 化：把 CrewTab 主体移出 iOS-only 子树，让 iPad / Mac PendingBot 共享同一份代码（spec v2 §11.2 三端齐）

**估时**：4-6 天（重写 878 行 view + 群聊 UI 借用 ConversationView 但 crew context + multiplatform 提升）

**依赖**：T4.1（Session ↔ 群聊通信接口）, T4.3（Permission Request UI 卡片）。但**P0 MVP**（crew 列表 + 进入 crew 看 metadata + 新 endpoint）可以**先做**，不必等 T4.1/T4.3。

---

## 8. Phase 5：BYOK + 整合（1-2 周）

### T5.1 PendingCrew 未登录路径

**目标**：spec v2 §5.2 — PendingCrew 不登录也能用，BYOK 配置 + 只本地 crew。

**具体动作**：
- 启动页"登录 PendingBot" / "不登录直接用"
- 不登录路径：本地 SQLite 存 crew/session（不同步 edge）
- 设置页 BYOK 区：Anthropic / OpenAI / Gemini key 输入 + 验证
- Captain bot 池：本机存的 "captain templates"
- Fly machine 入口禁用 + 提示"登录 PendingBot 解锁"

**估时**：4 天

**依赖**：T3.5（session 面板已成型）

---

### T5.2 双轨路由

**目标**：登录态/未登录态在同一份代码里通过 `AuthMode` 抽象优雅分流。

**具体动作**：
- 抽 `PendingCrewBackend` protocol，两种实现：`EdgeBackend`（登录）、`LocalBackend`（未登录 + SQLite）
- 所有 View 注入 backend，不直接调 API
- 切换登录态时不丢本地数据（merge 策略：登录后把本地 crew 上传 edge 或保留本地）

**估时**：3 天

**依赖**：T5.1

---

### T5.3 端到端 QA + bug 修

**目标**：v1.0 release-ready。

**具体动作**：
- 手动跑通整条链路（spec v2 §13.1 12 项 + T4.5 共 13 项）
- bug log + 修
- 性能：crew 列表加载、session 启动延迟、跨端遥控延迟
- 边界：网络断开、PendingCrew 崩溃恢复、token 过期
- 文档：用户指南、开发者 README

**估时**：5-7 天

**依赖**：所有前面

---

## 9. 老 plan/spec 同步（贯穿全程，不单独占 phase）

按 spec v2 §15 处理表，在对应 phase 内顺带做：

| 老文件 | 动作 | 在哪个 task 内处理 |
|---|---|---|
| `2026-05-27-pendingbot-pendingcrew-product-design.md` | ✅ 已废弃（标 DEPRECATED） | 已完成 |
| `2026-05-27-crew-organization-model-design.md` | 修订（责任比例规则 + group_account 轻量化） | T2.4 时一并改 |
| `2026-05-24-crew-temporary-groups-design.md` | 修订（"workspace"→"工作目录"+"项目"→"标签"） | T2.1 时一并改 |
| `2026-05-24-subject-foundation.md` | 仍用，补群账号扫码登录细节 | T1.3 时一并改 |
| `2026-05-24-runner-host-schema.md` | 仍用 | — |
| `2026-05-24-crew-dispatch-schema.md` | 仍用 | — |
| `2026-05-27-pendingbot-multiplatform-shell.md` | ✅ 已删 → 被 T0.1 取代 | 已完成 |
| `2026-05-27-pendingcrew-session-workbench.md` | 重写 → 被 T0.2 + Phase 3 取代 | Phase 3 完成后删 |
| `2026-05-27-local-crew-captain-foundation.md` | 重写 → 被 T2.2 + T3.x 取代 | Phase 3 完成后删 |
| `2026-05-27-pendingbot-crew-real-data.md` | ✅ 已删（被本 roadmap 取代） | 已完成 |

---

## 10. 风险与未知

| 风险 | 影响 phase | 缓解 |
|---|---|---|
| Claude Code / Codex 的 queue prompt CLI 不稳定或缺失 | T3, T4.1 | 早做 spike，T0 前先 hand-test 一下 CLI |
| iPad mini 三栏太挤 | T0.2, T5 | 用 SizeClass 自适应回退到两栏 |
| 跨端遥控 DO+WS 选型 | T4.5 | 参考现有 RoomVoiceDO 模式，复用基础设施 |
| Fly Machine API 实际行为（v1.1） | 不影响 v1.0 | T4.5 设计时把通信层做成 location-agnostic，v1.1 加 fly 实现 |
| 群账号轻量化 vs 旧 plan 的"workspace 重资产"心智 | T1.1, T1.2 | T1.1 实施前 review 老 `subject-foundation` plan，必要时修订 |
| 现有 iOS code base 大，T0.1 迁移风险 | T0.1 | 在独立分支做，每个文件夹搬完即 build 验证 |

---

## 11. 起手怎么选

T0.1 / T0.2 是最自然的起手 —— 不动产品逻辑，只搭脚手架。其他 phase 都依赖工程结构稳定。

**推荐起手顺序**：

1. **T0.2 PendingCrew Multiplatform**（先做这个，因为现有 PendingCrew 代码 30% 可复用，工作量小、风险低，能快速验证 SwiftUI multiplatform 工作流）
2. **T0.1 PendingBot Multiplatform**（搬 iOS 完整 code base 风险大，先用 T0.2 把流程跑通再做）
3. **T1.1 Subject schema** + **T1.4 PendingBot 三端基础壳** 并行（数据库 + UI 各自走）
4. ...

---

## 12. 自检（roadmap 评审通过前必看）

- [ ] 12 项 spec v2 §13.1 必交付都有对应 task
- [ ] T4.5 跨端遥控 / peer_device 通信架构 task 落实
- [ ] 老 plan 同步动作分散到对应 task，不漏
- [ ] 依赖关系图无环
- [ ] 风险清单覆盖了"codex 留下的雷"（子进程安全 / Multiplatform 重构难度 / queue prompt CLI）
- [ ] 起手 task（T0.2）是低风险高确定性的

---

**Roadmap 草案完。**
