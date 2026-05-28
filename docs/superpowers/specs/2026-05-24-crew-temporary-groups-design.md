# Crew 与临时群地基设计

日期：2026-05-24
分支：`codex/temporary-groups-foundation`

> 2026-05-27 更新：本文件中关于 Crew、master bot、父子关系和 PendingCrew/PendingBot 产品边界的部分，已被 `docs/superpowers/specs/2026-05-27-crew-organization-model-design.md` 和 `docs/superpowers/specs/2026-05-27-pendingbot-pendingcrew-product-design.md` 修正。新实现应使用「机组」和 `captain`/「机长」语义。
>
> **2026-05-28 修订**:本文件随 [`2026-05-28-pendingbot-pendingcrew-product-design-v2.md`](./2026-05-28-pendingbot-pendingcrew-product-design-v2.md)(spec v2)做了术语对齐:
>
> 1. 全文 "workspace"(产品/语义层用法)改为 "工作目录(workspace)"。代码标识符(如 SQL 列名 `workspace_root`、`workspace_id`)保留英文不变。
> 2. crew 的三属性分离:**所在地 / 标签 / 工作目录**,见 spec v2 §6.2。**注意 spec v2 把老 spec 中"项目"重命名为"标签"以避免与"工作目录"混淆**;本文件 v1 历史文本里没有"项目"这个术语,因此没有具体的"项目→标签"替换,但新实现按 spec v2 的命名走。
> 3. 责任比例规则:任何冲突一律以 spec v2 §7.3 + `2026-05-27-crew-organization-model-design.md`(2026-05-28 修订版)为准。
> 4. group_account 是**轻量化、可临时**的(出门旅游/家庭共享/公司团队同模型),跟 Notion workspace 重资产**完全不同**(spec v2 §4.2)。

## 目的

这份设计重建当前“子会话 / 临时协作 / coding agent 编排”这一块的地基。目标不是做最小验证，而是先把长期会稳定下来的模型定清楚。

核心结论：

- bot 创建的临时群是真实、可审计的协作空间。
- Crew 是人类显式创建、用于调用 coding agent 的临时群。
- 成本、责任、控制权和 runner 授权归属于人类实体：个人账号或群账号。
- iOS 和 macOS 都能使用 Crew。Mac 只是可以额外作为本地 runner host。
- 旧的 `subagent` 会话模型不再作为新产品能力继续演进。
- 面向用户阅读的产品/架构/spec 文档默认使用中文；代码标识、字段名、命令和必要工程注释按仓库惯例保留英文。

这套设计刻意避免三件事：

- 避免再长出一套隐藏 task system。
- 避免把权限和计费规则塞进 `metadata` 里靠应用层猜。
- 避免把普通群聊分摊账单和 agent 执行账单混在一起。

## 核心概念

### Subject：责任主体

`subject` 是真正承担控制、计费、runner 授权和审计责任的人类实体。

支持两类：

- `user_account`：个人账号。
- `group_account`：轻量群账号。

subject 负责：

- 钱包余额和消费责任；
- 私有 bot 所有权；
- runner host 授权；
- coding agent 高风险操作审批；
- 查看自己名下 Crew、临时群、session、事件和产物。

bot 不是最终责任主体。bot 是 subject 的代理，或者是被调用的公有能力。

### Chat Group：普通群

现有群聊继续作为普通聊天表面存在。

普通群可以：

- 有人类和 bot；
- 支持群语音；
- 使用现有群成员分摊账单；
- 被人或 bot 在聊天语义里使用。

普通群不是 coding-agent 权限边界。

### Temporary Group：bot 发起的临时群

临时群是新的 `conversation_type = 'temporary_group'`，由 bot 在完成任务时创建。

它替代旧的“子会话”概念。两个人的临时群只是最小临时群，不再需要单独叫 subagent。

临时群规则：

- 是真实会话，有消息、参与者和审计；
- 可以加入人类、已注册 bot、临时 bot；
- 默认不出现在普通消息列表；
- 在“有求于你”和临时群树状检查器里出现；
- 不支持群语音；
- 不使用普通群分摊账单；
- 不要求 SSE 流式输出；
- 不能静默启动本机或云端 coding agent。

### Crew：调用 coding agent 的临时群

Crew 是人类显式创建、用于调用 coding agent 的临时群。

它是调用本机/云端 coding agent 的安全边界：

- 没有 Crew，就不能启动本机 Claude Code / Codex / opencode / Kilo。
- 没有 Crew，就不能启动云端 Cloudflare Sandbox coding agent。
- Crew 创建者和有权限的 subject 控制者可以看状态、批准权限、发指令、接收结果。

Crew 是跨端能力：

- iOS 可以创建和控制 Crew。
- macOS 可以创建和控制 Crew。
- macOS 可以额外作为本地 runner host。
- iOS 可以像遥控器一样控制在线 Mac runner。
- 如果没有可用 Mac runner，可以使用云端 runner，前提是 subject 启用了云端执行。

Crew 不是 Mac 专属功能。Mac 是更强的控制端和可选 runner host；iOS 是控制端。

每个由 PendingBot 里的 bot 创建或调用的 Crew，可以有一个 `master bot`。

- `master bot` 对应 PendingBot 里创建或调用这个 Crew 的那个 bot。
- Crew 内的 master bot 是成员和控制入口，不承担费用责任；费用仍归因到个人或群 subject。
- 本机 master bot 能力可以开关，默认关闭。关闭时，Crew 仍可存在，但不会把本机 agent 能力暴露给 master bot。
- 人类可以单独和 master bot 私聊；私聊是普通 `user_bot` 会话，和 Crew 公告板分开，只通过 metadata/linkage 关联。
- 人类直接创建、没有 bot 参与的 Crew，可以没有 master bot。

## 会话类型

新增：

- `temporary_group`：bot 创建的临时协作群。
- `crew`：人类创建的 coding-agent 编排临时群。

> **2026-05-28 校准**:`crew` 的三属性现在被明确**分离**:**所在地**(本地 / fly machine)、**标签**(轻量分类字符串)、**工作目录**(crew 默认 cwd)。详见 spec v2 §6.2。三者各自独立配置,不再混用 "workspace" 一个词代表多个语义。

保留：

- `group`：普通群聊。
- `user_bot`、`user_user`、`self`：普通聊天表面。

废弃新写入：

- `subagent`：不再有新产品路径创建它。

`temporary_group` 和 `crew` 共享部分执行底座，但权限语义不同：

- `temporary_group` 由 bot 发起，主要解决 bot 求助、多人协作、临时 bot。
- `crew` 由人类发起，是 coding-agent 权限边界。

## 责任主体解析

每个临时群、Crew、coding session、runner lease、audit row 都必须解析到一个 `responsible_subject_id`。

解析规则：

- 个人与 bot 单聊：责任主体是该个人账号。
- 普通群里发起：责任主体是该群对应的群账号。
- Crew：责任主体由创建者选择，默认是当前个人账号；如果用户有权限，也可以选择群账号。
- 公有 bot：永远不是责任主体，只是被调用能力或参与者。
- 临时 bot：永远不是责任主体。
- coding session：继承创建它的 Crew 的责任主体。

责任主体决定：

- 扣哪个钱包；
- 谁能看实时状态；
- 谁能批准权限请求；
- 哪些 runner host 可以执行；
- 哪些私有 bot 可以用；
- 能不能向哪些人类求助。

## 数据模型

### `subjects`

新增表：

```sql
pendingbot.subjects (
  id uuid primary key,
  subject_type text not null check (subject_type in ('user_account', 'group_account')),
  user_id uuid null references auth.users(id) on delete cascade,
  group_conversation_id uuid null references pendingbot.conversations(id) on delete cascade,
  display_name text not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
)
```

约束：

- `user_account` 必须有 `user_id`。
- `group_account` 在当前实现里绑定 `group_conversation_id`。
- 每个用户有且只有一个个人 subject。
- 需要钱包、runner、Crew、临时群责任能力的普通群，必须有且只有一个群 subject。

如果未来把 group 从 conversation 中独立成专门表，迁移必须保持 subject id 不变。

### `subject_wallets`

新增表：

```sql
pendingbot.subject_wallets (
  subject_id uuid primary key references pendingbot.subjects(id) on delete cascade,
  balance_credits bigint not null default 0,
  lifetime_topup_credits bigint not null default 0,
  lifetime_spent_credits bigint not null default 0,
  balance_updated_at timestamptz
)
```

钱包规则：

- 个人 subject 钱包先镜像当前 `users.balance_credits`，兼容迁移。
- 群账号钱包可以由群成员充值。
- 群账号钱包不能把余额退回给群成员。
- Crew、临时群、云端 runner、PendingBot 付费模型/工具调用都通过 subject 钱包结算。

### `group_subject_members`

新增表：

```sql
pendingbot.group_subject_members (
  subject_id uuid references pendingbot.subjects(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member')),
  can_manage_wallet boolean not null default false,
  can_manage_runners boolean not null default false,
  can_create_crew boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (subject_id, user_id)
)
```

它把“能在群里聊天”和“能代表群账号操作”分开。

### `temporary_group_meta`

新增表：

```sql
pendingbot.temporary_group_meta (
  conversation_id uuid primary key references pendingbot.conversations(id) on delete cascade,
  temporary_kind text not null check (temporary_kind in ('bot_temporary_group', 'crew')),
  responsible_subject_id uuid not null references pendingbot.subjects(id),
  initiator_type text not null check (initiator_type in ('human', 'bot')),
  initiator_user_id uuid null references auth.users(id),
  initiator_bot_id uuid null references pendingbot.bots(id),
  source_conversation_id uuid null references pendingbot.conversations(id),
  parent_temporary_group_id uuid null references pendingbot.conversations(id),
  root_temporary_group_id uuid null references pendingbot.conversations(id),
  status text not null default 'active' check (status in ('active', 'closing', 'closed', 'cancelled')),
  title text,
  created_at timestamptz not null default now(),
  closed_at timestamptz
)
```

约束：

- `temporary_kind = 'crew'` 必须是 `initiator_type = 'human'`。
- `temporary_kind = 'bot_temporary_group'` 必须是 `initiator_type = 'bot'`。
- `root_temporary_group_id` 指向整棵临时群树的根。
- 根节点创建后可以指向自己。
- `responsible_subject_id` 创建后不可变，除非做明确的管理员修复。

### `temporary_group_members`

新增表：

```sql
pendingbot.temporary_group_members (
  id uuid primary key default pendingbot.uuidv7(),
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  member_kind text not null check (member_kind in (
    'human',
    'registered_bot',
    'ephemeral_bot',
    'code_session'
  )),
  user_id uuid null references auth.users(id),
  bot_id uuid null references pendingbot.bots(id),
  code_session_id uuid null,
  display_name text not null,
  role text not null default 'member' check (role in ('owner', 'admin', 'member', 'observer')),
  capabilities jsonb not null default '{}'::jsonb,
  ephemeral_spec jsonb not null default '{}'::jsonb,
  invited_by_member_id uuid null references pendingbot.temporary_group_members(id),
  status text not null default 'active' check (status in ('active', 'left', 'removed', 'expired')),
  created_at timestamptz not null default now()
)
```

说明：

- 真正的人类参与者需要同步写入 `conversation_participants`，用于 RLS 和消息可见性。
- 持久注册 bot 如需被普通会话读取，也可以同步写入 `conversation_participants`。
- 临时 bot 和 code session 主要存在于 `temporary_group_members`，通过服务端授权访问。

虽然表里保留 `code_session` member kind，但产品规则是：只有 Crew 可以创建 code session。bot 创建的普通临时群不能创建 code session。

### `human_help_requests`

“有求于你”入口使用新表：

```sql
pendingbot.human_help_requests (
  id uuid primary key default pendingbot.uuidv7(),
  temporary_group_id uuid not null references pendingbot.conversations(id) on delete cascade,
  requester_member_id uuid not null references pendingbot.temporary_group_members(id),
  requested_user_id uuid not null references auth.users(id),
  responsible_subject_id uuid not null references pendingbot.subjects(id),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  reason text,
  created_at timestamptz not null default now(),
  decided_at timestamptz
)
```

规则：

- 私有 bot 不能向无关人类求助。
- 公有 bot 只能按明确关系规则向人类求助。
- 请求出现在被请求用户的“有求于你”列表。
- 用户接受后，才加入对应临时群。

### `crew_sessions`

Crew 中每个 coding agent 运行实例使用：

```sql
pendingbot.crew_sessions (
  id uuid primary key default pendingbot.uuidv7(),
  crew_conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  responsible_subject_id uuid not null references pendingbot.subjects(id),
  initiating_member_id uuid not null references pendingbot.temporary_group_members(id),
  assigned_to_member_id uuid null references pendingbot.temporary_group_members(id),
  runner_host_id uuid null,
  runner_kind text not null check (runner_kind in (
    'cloud_sandbox',
    'local_claude_code',
    'local_codex',
    'local_opencode',
    'local_kilo'
  )),
  status text not null default 'queued' check (status in (
    'queued',
    'waiting_runner',
    'running',
    'waiting_permission',
    'blocked',
    'completed',
    'failed',
    'cancelled'
  )),
  task_brief text not null,
  progress_summary text,
  last_context_cursor text,
  final_result_message_id uuid null references pendingbot.messages(id),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
)
```

bot 创建的临时群不能创建此表记录。Crew 是 coding-agent 权限边界。

### `session_events`

session 过程输出不刷进群消息流，写入事件表：

```sql
pendingbot.session_events (
  id uuid primary key default pendingbot.uuidv7(),
  crew_session_id uuid not null references pendingbot.crew_sessions(id) on delete cascade,
  event_type text not null,
  visibility text not null default 'controllers' check (visibility in ('controllers', 'crew_members', 'private_system')),
  summary text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
)
```

事件类型：

- `queued`
- `runner_selected`
- `started`
- `context_injected`
- `status`
- `tool_call`
- `tool_result`
- `permission_requested`
- `permission_resolved`
- `artifact_created`
- `posted_to_crew`
- `blocked`
- `completed`
- `failed`
- `cancelled`

### `runner_hosts`

runner host 表：

```sql
pendingbot.runner_hosts (
  id uuid primary key default pendingbot.uuidv7(),
  responsible_subject_id uuid not null references pendingbot.subjects(id),
  device_id uuid null,
  platform text not null check (platform in ('macos', 'cloud')),
  display_name text not null,
  capabilities jsonb not null default '{}'::jsonb,
  status text not null default 'offline' check (status in ('online', 'offline', 'disabled')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
)
```

Mac runner host 由原生 macOS app 注册。Cloud runner host 是 Cloudflare Sandbox 池的逻辑入口。以后其他云端 provider 必须实现同一套 runner host 和 lease 协议。

### `runner_leases`

runner 不拿用户主 token，只拿单 session lease：

```sql
pendingbot.runner_leases (
  id uuid primary key default pendingbot.uuidv7(),
  crew_session_id uuid not null references pendingbot.crew_sessions(id) on delete cascade,
  runner_host_id uuid not null references pendingbot.runner_hosts(id),
  responsible_subject_id uuid not null references pendingbot.subjects(id),
  lease_status text not null default 'active' check (lease_status in ('active', 'released', 'expired', 'revoked')),
  granted_by_user_id uuid null references auth.users(id),
  lease_token_hash text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
)
```

### `permission_requests`

高风险操作使用权限请求：

```sql
pendingbot.permission_requests (
  id uuid primary key default pendingbot.uuidv7(),
  crew_session_id uuid not null references pendingbot.crew_sessions(id) on delete cascade,
  responsible_subject_id uuid not null references pendingbot.subjects(id),
  requested_action text not null,
  risk_level text not null check (risk_level in ('low', 'medium', 'high')),
  detail jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'expired', 'cancelled')),
  requested_at timestamptz not null default now(),
  decided_by_user_id uuid null references auth.users(id),
  decided_at timestamptz
)
```

iOS 和 macOS 都可以审批，只要当前用户有权代表 responsible subject。

## 权限与 RLS

### subject 访问

用户能访问 subject 的条件：

- 它是用户自己的 personal subject；
- 或用户在 `group_subject_members` 中拥有该 group subject 的权限。

按角色控制：

- 钱包管理；
- runner 管理；
- Crew 创建；
- 权限审批；
- 完整 session event 查看。

### 临时群访问

访问路径：

- 是临时群的人类成员；
- 是 responsible subject 的控制者；
- 接受了 human help request；
- runner/session 通过服务端 lease 访问。

列表规则：

- 普通消息列表默认排除 `temporary_group` 和 `crew`。
- “有求于你”列出待处理人类求助。
- Crew tab 列出用户有权控制的 `conversation_type = 'crew'`。
- 临时群树状检查器列出 bot 创建的临时群树。

### Crew 安全边界

只有 `conversation_type = 'crew'` 可以通过用户 API 创建 general coding session。

创建 `crew_session` 前必须检查：

- 调用者能控制 responsible subject；
- group subject 下调用者有 `can_create_crew`；
- Crew 会话处于 active；
- requested runner kind 被 subject 设置允许；
- 本地 runner 请求必须有合格在线 runner host；
- 云端 runner 请求必须启用云端执行并通过钱包 gate。

bot 创建的 `temporary_group` 不能绕过 Crew 直接创建 coding session。

## Dispatch 架构

dispatch 层是状态机和事件总线，不是单个 supervisor bot。

职责：

- 创建任务和 session；
- 选择 runner；
- 发放 runner lease；
- 在关键步骤前注入上下文；
- 收集结构化状态；
- 路由权限请求；
- 把最终结果交回发起人；
- 维护 session 之间的依赖和 mailbox；
- 向 iOS/macOS 暴露实时状态。

### Context Packet

每次 coding agent 继续执行前，coordinator 生成一个紧凑上下文包：

- Crew 任务 brief；
- 只投递给当前 session 的 Crew 消息；
- 上次 cursor 之后、当前 session 应接收的新 mailbox 项；
- 当前 session 状态；
- 其他活跃 session 摘要；
- 依赖状态；
- 未完成权限请求；
- responsible subject 和 runner 边界；
- 可用工具和输出策略。

不要重放完整 transcript。上下文包是压缩后的工作状态。

### 输出策略

默认：

- 原始进程输出写 `session_events`；
- 状态摘要更新 `crew_sessions.progress_summary`；
- 只有 session 显式调用公告工具才写入 Crew 公告板；
- 公告可以 `@` 一个或多个 session / 人类成员；
- 有 `@` 时，只投递给被 `@` 的 session；没有 `@` 时视为全员广播，所有 session 都收到；
- 人类在 Crew 公告板发消息遵循同一规则；
- 人类回复某条 session 发出的消息时，客户端默认自动 `@` 该发送 session；
- 最终结果交回发起 member 或指定负责人。

Crew 会话消息流不能变成终端日志。

### Mailbox

需要支持 IM 风格的 Crew 公告板和 session mailbox：

- `crew_announcements` 是公告本体，像群聊消息一样展示；
- `crew_announcement_mentions` 记录这条消息 `@` 了哪些 session 或人类成员；
- `session_mailbox_items` 是对 session 的投递队列，只保存 session 应该收到的消息；
- session 默认只读自己的 mailbox，不扫整个 Crew 公告板；
- 没有 `@` 的公告会 fan-out 到所有 session mailbox；
- 人类面板展示完整 IM 流，可以看到谁发给谁、谁 `@` 谁，并可对单条消息回复。

这借鉴成熟多 agent / team 系统，但不要求所有 session 共用一个巨大上下文。

### Dependencies

显式记录依赖：

```sql
pendingbot.session_dependencies (
  id uuid primary key default pendingbot.uuidv7(),
  crew_session_id uuid not null references pendingbot.crew_sessions(id) on delete cascade,
  depends_on_session_id uuid null references pendingbot.crew_sessions(id) on delete cascade,
  dependency_type text not null,
  status text not null default 'waiting',
  created_at timestamptz not null default now(),
  resolved_at timestamptz
)
```

依赖类型：

- `wait_for_result`
- `wait_for_permission`
- `wait_for_artifact`
- `wait_for_file_claim`
- `manual_blocker`

### File Claims

coding 工作要声明路径占用：

```sql
pendingbot.session_file_claims (
  id uuid primary key default pendingbot.uuidv7(),
  crew_session_id uuid not null references pendingbot.crew_sessions(id) on delete cascade,
  workspace_root text not null,
  path_pattern text not null,
  claim_type text not null check (claim_type in ('read', 'write', 'exclusive_write')),
  status text not null default 'active',
  created_at timestamptz not null default now()
)
```

这能避免多个 session 不知情地改同一块代码。

## Runner 架构

### 云端 runner

云端 runner 使用 Cloudflare Sandbox 或等价远程执行 provider。

规则：

- 一个 session 一个 lease；
- 明确 timeout 和 cleanup；
- 默认不保留长期记忆；
- destroy 前拷出 artifacts；
- 云端 runtime 成本计入 responsible subject。

### Mac runner

macOS app 有两个角色：

- 控制端 UI；
- 可选 runner host。

runner host 应该由 helper/bridge 承担，而不是绑死在某个窗口状态里。

职责：

- 注册本机能力；
- 接收 scoped lease；
- 启动 Claude Code / Codex / opencode / Kilo 等本地 runner；
- 回传结构化状态；
- 发起权限请求；
- 写入产物和最终结果；
- 释放 lease。

安全规则：

- auth secret 存 Keychain；
- runner 只拿单 session lease；
- 工作目录(workspace root)需要显式授权；
- 高风险操作必须走 permission request；
- 本地 runner 不拿 service-role 凭据。

### iOS runner 行为

iOS 只作为控制端。

iOS 可以：

- 创建 Crew；
- 选择 runner 类型；
- 查看状态；
- 批准权限请求；
- 发指令；
- 收最终结果。

iOS 不能在手机本地执行 coding agent。

如果有合格 Mac runner 在线，iOS 可以通过 Crew 遥控它；否则可以用云端 runner，或进入 `waiting_runner`。

## iOS 与 macOS 产品表面

### macOS 双 App 边界

macOS 需要两个原生 SwiftUI App，而不是一个 App 塞下所有模式：

- `PendingBot` macOS 主应用：PendingBot 的桌面主端，负责 Messages、普通群、好友/联系人、Bots、Wallet、Settings、通知、“有求于你”和日常聊天操作。它和 iOS 主应用属于同一产品线，只是不走 Catalyst。
- `PendingCrew` 独立 App：专业 Crew 工作台，负责 Crew、runner host、本机工作目录(workspace)授权、coding session 编排、权限审批、artifact/patch、session events。它可以向开源软件方向演进，但账号、subject、钱包、资源、bot 控制权和云端 API 仍属于 PendingBot 平台。

两个 App 共享账号体系、扫码登录、subject grant、附件/资源 API 和基础设计语言，但不共享窗口结构。主应用可以通过 deep link 打开 `PendingCrew` 中的 Crew；`PendingCrew` 不承载普通聊天主流程。

### 共享 Crew 产品面

Crew 是跨端产品能力，但不是每个端都嵌在 PendingBot 主应用里。

- iOS：在 PendingBot 主应用里提供单独 `Crew` tab，用来创建 Crew、远程控制在线 Mac runner，或直接使用云端 runner。
- macOS：提供独立 `PendingCrew` App，登录 PendingBot 账号后访问同一套 subject、Crew、附件、资源、钱包和云端 API。

Crew 表面显示：

- 活跃 Crew；
- 按状态分组的 sessions；
- 待处理权限请求；
- 需要人类输入的 sessions；
- 完成结果；
- artifacts 和 patches；
- runner 可用状态。

### macOS 表面

macOS 使用单独的原生 SwiftUI App，不用 Catalyst，也不作为 PendingBot 主应用的 macOS 变体。

这个 App 可以向开源软件方向演进。它的边界是：

- 账号体系、subject、附件、资源、钱包、bot 控制权和云端 API 仍属于 PendingBot 平台；
- 本机 runner host、工作区授权、session 看板、权限审批和 coding-agent 编排属于 Crew App；
- 普通聊天、普通群、好友和非 Crew 的消息体验不放进这个 App 的核心路径。

推荐结构：

- `WindowGroup` 作为主窗口；
- 使用 `NavigationSplitView`；
- 左侧：Crew 列表、saved views 和 runner 状态；
- 中间：session 看板和选中 Crew 的公告板；
- 右侧 inspector：选中 session 的事件、产物、权限请求；
- toolbar：新建 Crew、新建 session、暂停/取消、runner 选择；
- Commands menu：常用动作和快捷键；
- Settings scene：runner 配置、账号和设备管理。

独立 Crew App 的主要区域：

- `Crew`
- `Runners`
- `Wallet`
- `Resources`
- `Settings`

`Runners` 可以是 Mac-only；`Crew`、`Wallet`、`Resources` 和权限审批是 iOS/macOS 共享能力的不同端面。

### iOS 表面

iOS tabs：

- `Messages`
- `Crew`
- `Bots`
- `Wallet`
- `Settings`

iOS Crew UI 重点：

- 状态看板；
- 权限请求；
- 远程控制 Mac/cloud sessions；
- 简洁事件摘要；
- 最终结果和产物。

iOS 不应该照搬桌面终端 UI。

## 手机扫码登录与群账号 runner 授权

Mac 登录流程：

1. Mac app 生成设备公钥和一次性 challenge。
2. Mac 显示二维码。
3. 已登录的 iOS app 扫码。
4. 用户选择授权主体：个人账号或某个群账号。
5. Edge 检查该用户是否有权代表所选 subject。
6. Edge 颁发绑定 Mac 公钥和 subject 的 device grant。
7. Mac 把刷新凭据存入 Keychain。
8. runner host 为该 subject 注册。

群账号限制：

- 可以拥有私有 bot；
- 可以拥有钱包；
- 可以授权 runner host；
- 不能创建公有 bot；
- 不能加人类好友；
- 不能把钱包余额返还给成员。

## 计费与审计

audit 需要增加 subject-based 字段：

- `responsible_subject_id`
- `temporary_group_id`
- `crew_session_id`
- `runner_host_id`
- `billing_mode`
- `settlement_status`

计费模式：

- `subject_wallet`：从 responsible subject 钱包扣 PendingBot credits。
- `external_user_subscription`：使用用户自己的本地订阅时只审计，不扣 PND。
- `free`：无计费成本。
- `unbilled`：有成本但结算失败。

云端执行和 PendingBot 付费 LLM/tool 调用都从 responsible subject 钱包扣款。本机 runner 如果使用用户自己的 Claude/Codex 订阅，可以只做审计；如果调用 PendingBot 付费 API，则按 subject 钱包扣费。

## 旧 subagent 退场

新写入：

- 移除或禁用会创建 `conversation_type = 'subagent'` 的 `delegate_to_specialist` 路径；
- 替换为 temporary group 或 Crew-aware API。

UI：

- 新流程不再进入 `SubConversationView`；
- 工具 trace 链接到 temporary group 或 Crew session 状态。

数据：

- 已存在 `subagent` 行可以作为历史数据保留；
- 普通列表继续排除；
- 除非未来需要历史归档查看器，否则不迁移成新产品模型。

代码清理：

- 替换 API 上线后移除 subagent 专用假设；
- 用 `temporary_group_meta` 替换只靠 `parent_message_id` 的树关系。

## 实施阶段

### Phase 1：Subject 地基

- 新增 `subjects`、`subject_wallets`、`group_subject_members`。
- 回填用户个人 subject。
- 按需回填群 subject。
- 增加 subject wallet RPC，同时保持当前 user wallet 兼容。
- 增加 subject 访问 RLS helper。

### Phase 2：临时群与 Crew Schema

- 增加 `temporary_group` 和 `crew` conversation types。
- 增加 `temporary_group_meta`、`temporary_group_members`、`human_help_requests`。
- 增加列表过滤和访问策略。
- 增加人类创建 Crew、bot 创建临时群的 RPC。

### Phase 3：Dispatch 与 Events

- 增加 `crew_sessions`、`session_events`、dependencies、mailbox、file claims、permission requests。
- 增加 Edge coordinator API。
- 增加 session 状态 Realtime channel。
- 增加 audit subject 字段和 subject debit path。

### Phase 4：Runner Hosts

- 增加 runner host 注册。
- 增加 cloud runner adapter。
- 增加 Mac runner bridge 协议。
- 增加 scoped runner leases。
- 增加 permission request 处理。

### Phase 5：产品表面

- iOS Crew tab。
- macOS 独立原生 SwiftUI Crew App。
- macOS Runner tab 和 settings。
- bot 求助人类的“有求于你”入口。
- 临时群树状检查器。

### Phase 6：Subagent 移除

- 用 temporary group API 替换 `delegate_to_specialist`。
- 停止创建新的 `subagent`。
- 从活跃流程里移除旧 iOS 子会话 viewer。
- 历史行继续隐藏。

## 测试与验证

数据库：

- subject 访问 RLS；
- Crew 可见性 RLS；
- “有求于你”收件箱 RLS；
- subject wallet 扣款；
- personal subject 和 group subject 回填。

Edge：

- Crew 创建必须有人类 subject 权限；
- 非 Crew 不能创建 `crew_session`；
- runner lease 必须绑定 subject；
- cloud runner 成本扣 responsible subject；
- local external-subscription runner 只写审计；
- permission request 阻塞 session 直到审批；
- session events 只向授权控制者开放。

iOS/macOS：

- Crew 列表不混入普通群；
- iOS 可以创建 Crew 并使用云端 runner；
- iOS 可以远程控制在线 Mac runner；
- macOS 可以注册 runner host；
- iOS/macOS 都能审批权限请求；
- 原始 session 输出不会刷爆会话消息流。

回归：

- 普通群聊和群语音继续工作；
- 普通群分摊账单不作用于 Crew；
- 旧 `subagent` 行继续从普通列表隐藏。

## 已定设计决策

1. Crew 使用独立 conversation type：`conversation_type = 'crew'`。

   原因：coding-agent 权限足够敏感，数据库策略和 Edge 路由需要直接边界，不能靠 metadata 判断。

2. subject wallet 先走兼容模式。

   个人 subject wallet 先镜像当前用户余额；UI 和 RPC 在验证后逐步迁移到 subject wallet。

3. 群 subject 懒创建。

   群第一次需要责任、钱包、私有 bot、Crew、临时群责任或 runner 能力时创建 group subject。普通只聊天的群不需要立即创建。

4. bot 创建的临时群不能创建 coding session。

   Crew 是 coding-agent 权限边界。bot 可以请求人类打开或批准 Crew 流程，但不能静默启动本机或云端 coding agent。

5. Mac runner bridge 是 runner 基础设施，不是普通 UI 状态。

   原生 macOS app 是控制端 UI。runner bridge 负责 runner 注册、lease、子进程控制、状态上报和权限交接。
