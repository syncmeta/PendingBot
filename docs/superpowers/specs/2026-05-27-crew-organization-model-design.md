# 机组组织模型设计

日期：2026-05-27
分支：`codex/crew-group-continuation`
状态：仍有效,**2026-05-28 已校准**(见下方修订说明)

> **2026-05-28 修订**
>
> 本文件随 [`2026-05-28-pendingbot-pendingcrew-product-design-v2.md`](./2026-05-28-pendingbot-pendingcrew-product-design-v2.md)(以下简称 spec v2)做了**校准式**修订,不弃用,继续作为 crew 组织模型的子领域 spec。变更点:
>
> 1. **责任比例规则**整段(下方「责任主体比例」一节)按 spec v2 §7.3 重写为 5 条核心规则:认父时定死、不允许相同/不允许平均、同主体合并、跨主体确认、拍板原则。旧版"多父继承、相同 subject 比例相加再归一化"的简单合并规则被保留为规则 3 的一部分,但**新增**了"拍板方"的强约束。
> 2. **subject 模型**:补充了 `group_account` 的轻量化定位(可临时建群账号,跟 Notion workspace 重资产**不同**)。详见 spec v2 §4.2。
> 3. 其它消息路由、DAG 结构、本地/云端边界保持不变;但任何冲突一律以 spec v2 为准。

## 目的

这份设计修正 2026-05-24 Crew/临时群地基设计中关于 Crew、master bot、父子关系和消息同步的语义。

新的产品术语：

- Crew 面向用户中文叫「机组」。
- `supervisor bot` / `master bot` 在机组语境里统一改为 `captain`，中文叫「机长」。
- 机组不是一个附属的 chat 模块；机组本身就是一组工作群聊、成员、session 和编排规则。
- 第一阶段只做本地机组闭环；云端机组和 Fly Machine 先预留，不做真实创建和计费自动化。

## 核心模型

### 机组

一个机组是一个可被人类和 bot 共同参与的工作群。

它包含：

- 群聊现场；
- 一个机长 bot；
- 人类成员；
- bot 成员；
- session 成员，例如 Codex、Claude、Kilo、Cloud Sandbox；
- 本地或云端运行形态；
- 指向父机组的边；
- 指向子机组的边；
- 继承或显式指定的责任主体比例。

机组不是普通群聊的同义词。普通群聊解决 IM 协作；机组解决任务编排、session 成员和上传下达。

### 机长

每个机组必须有一个机长 bot。

机长职责：

- 在本机组中接收人类和 session 成员的消息；
- 在父机组中代表本机组接收上级消息；
- 向父机组汇报本机组摘要；
- 将父机组的指令理解、拆解并按需带回本机组；
- 自主创建继承当前权限和分摊关系的子机组；
- 自主启动普通 session；
- 在需要改变责任主体比例或云端成本边界时请求人类确认。

机长不是责任主体。权限、计费和分摊始终由继承或显式确认的 subject 比例决定。

### 机组 DAG

机组之间形成有向无环图，不是树。

规则：

- 一个机组可以有多个父机组。
- 一个机组可以有多个子机组。
- 不能形成环。
- 父机组关系同时代表责任主体比例继承。
- 责任主体比例同时管权限、计费和分摊。
- 指定父机组就是指定父机组的责任主体比例覆盖到子机组。
- 多父机组时，子机组继承并合成所有父机组的责任主体比例。

产品类比：

- 父机组像公司部门或上级工作群。
- 子机组像小组或专项组。
- 一个小组可以隶属于多个部门。
- 小组长在上级群中上传下达，但不会把小组内部所有消息刷到上级群。

## 父子机组关系

### 创建子机组

机长可以自主创建子机组，只要子机组完全继承当前机组的责任主体比例。

不需要人类确认的创建：

- 子机组只有当前机组作为父机组；
- 子机组继承当前机组的责任主体比例；
- 子机组使用本地机组运行形态；
- 子机组成员都来自当前权限链允许的范围。

需要人类确认的创建或修改：

- 子机组增加另一个父机组；
- 子机组修改责任主体比例；
- 子机组邀请不在父机组权限链里的成员；
- 子机组切到云端机组或绑定会产生 Fly 成本的 machine；
- 子机组请求新 workspace 或更高本机执行权限。

### 子机组在父机组中的表现

创建子机组时，子机组的机长自动加入父机组。

父机组看到的不是完整子机组，而是一个代表该子机组的机长成员。UI 可以显示为：

- `机长 · <子机组名>`;
- 子机组状态徽标；
- 最近摘要；
- 进入子机组按钮。

真实消息路由仍然以机长为边界。

### 消息路由

父机组给子机组机长发消息时：

- 消息进入机长的父机组上下文；
- 不自动进入子机组群聊；
- 不自动广播给子机组成员；
- 由机长判断是否回复父机组、转述给子机组、创建 session 或创建更小的子机组。

子机组向父机组汇报时：

- 由机长发摘要；
- 不同步完整子机组聊天记录；
- 不同步完整 session 日志；
- 关键状态可以在父机组中呈现为摘要消息或状态卡。

父机组人类成员可以直接进入子机组。这个能力来自父机组边本身代表的权限继承，而不是来自消息同步。

## 责任主体比例

> **2026-05-28 校准**:本节按 spec v2 §7.3 的 5 条核心规则重写。旧的"多父继承 → 相同 subject 比例相加再归一化"被吸收为规则 3,但加上了新增的「不允许相同」「拍板原则」「认父时定死」「跨主体确认」四条强约束。

### 关于 subject(责任主体)

机组的责任主体逻辑和临时群一致。subject 支持两类:

- `user_account`(个人账号)
- `group_account`(**群账号**:**轻量化、可临时**。跟 Notion workspace 那种重资产**完全不同**——出门旅游临时建一个群账号都行,家里一台共享 Mac 登一个群账号也行,公司团队同样模型,没有特殊处理。详见 spec v2 §4.2)

责任主体不是机组上单独拍脑袋指定的一个字段,而是一组 subject 比例。它同时决定:

- 谁有权限看和进入这个机组;
- 谁承担模型、工具、session 和 runner 成本;
- 每笔 token 或云端成本如何分摊;
- 哪些人类可以批准高风险操作。

每次产生费用或权限判断时,服务端都必须解析当前机组的责任主体比例,并在审计行中保存 resolved snapshot。

### 责任比例核心规则(spec v2 §7.3)

#### 规则 1 —— 认父时定死,不事后协商

- 设机组 C 当前由 subject X 100% 控制;
- 现在 X 想把 C 认作 D 的父机组(让 D 参与 C 的责任分配);
- **认父这一刻,X 自己决定保留多少比例**(>50% → X 仍是拍板方;<50% → D 拍板);
- 之后不能"协商重分配",要改必须明确发起一次"修改责任比例"动作。

#### 规则 2 —— 不允许相同 / 不允许平均

- 任意两个 subject 在同一机组的比例**不允许相等**;
- bot 协商比例时只能在"非均等合法解空间"内挑;
- 这条规则的产品意图:**保证机组永远有一个明确的「占多数」的责任主体(拍板方)**,避免 captain 之间扯皮 / 模型幻觉时跟错指令。

#### 规则 3 —— 同主体合并

- 多父场景下,合并所有父机组的责任主体比例:相同 subject 的比例**先相加,再归一化为 100%**。
- 例:机组 C 多父 —— 父 A 责任主体 = X(40%) + Y(60%),父 B 责任主体 = X(70%) + Z(30%);合并到 C 时:X = 40+70 = 110,Y = 60,Z = 30;归一化后 X(55%) + Y(30%) + Z(15%)。
- 合并完后必须满足规则 2(不允许相同);若机械合并出相等比例,需要人类介入打破平局(走规则 4)。

#### 规则 4 —— 跨主体确认

- 多父的责任主体集合**不同**时,**各方人类必须批准**;
- 多父的责任主体集合**相同**时,**bot 自己协商无需人类**;
- 群账号场景下"人类批准" = **走群权限矩阵**(admin+ 批,不需要全员):
  - 不会出现"旅游群有人手机没电卡住所有人"的情况,因为内部权限由群主配置 admin 名单;
- 个人账号场景下 = 本人批准。

#### 规则 5 —— 拍板原则

- 每个机组永远有一个"占多数"的责任主体(**拍板方**);
- 当 captain 之间出现指令冲突 / 模型在多父消息里幻觉跟错时,**听拍板方的**;
- 这是 bot 系统提示里必须强调的规则。

### 跨主体协作场景

跨主体只出现于"**我创建/拥有的机组,需要请别的人/群参与协作**":

- 我把机组 C 认作 D 的父机组,但 D 属于另一个主体;
- → 这是请别的主体来"领养" C 当子;
- → 异步等对方人类批准(走对方主体的权限矩阵);
- → 不在线就等,这是产品本意的同步语义,**不是 bug**。

### 默认分摊与审计

- 没有 explicit split 时,按规则 3 合并父机组比例;
- 不做额外权重 UI;
- 每次计费都持久化 resolved beneficiaries/split snapshot,保证审计可复现;
- 禁止 DAG 环,避免继承和计费循环。

## 本地机组与云端机组

### 本地机组

第一阶段完整实现本地机组。

本地机组运行在用户自己的 Mac 和 PendingCrew runner host 上。

能力：

- 创建机组；
- 创建子机组；
- 加入父机组 DAG；
- 机长上传下达；
- 创建 Codex/Claude/Kilo session；
- 本机 runner host 认领 session；
- workspace 权限由 PendingCrew 管理；
- session 事件、mailbox、日志、结果回传。

### 云端机组

云端机组第一阶段只预留。

预留概念：

- cloud crew；
- Fly Machine；
- 一个用户可以管理多个 Fly Machine；
- 一个 Fly Machine 上可以承载多个机组空间；
- Fly 成本归到机组解析出的责任主体比例；
- 创建、唤醒、销毁或产生持续成本前必须有人类确认。

第一阶段不做：

- Fly Machine 自动创建；
- Fly Machine 销毁；
- Fly 成本实时结算；
- 云端 workspace 自动分配；
- 云端 runner 真实执行。

## 数据模型建议

### `crew_meta`

在现有 Crew metadata 基础上补齐以下字段或等价表结构：

```sql
captain_bot_id uuid not null references pendingbot.bots(id),
runtime_kind text not null default 'local' check (runtime_kind in ('local', 'cloud')),
cloud_machine_id uuid null,
responsibility_mode text not null default 'inherit' check (responsibility_mode in ('inherit', 'explicit')),
status text not null default 'active',
title text not null
```

`captain_bot_id` 取代旧的 `master_bot` / `supervisor bot` 语义。`responsibility_mode` 描述责任主体比例来源；实际比例由父机组边或显式确认的 split 解析，不应简化成单个 subject。

### `crew_parent_links`

新增 DAG 边表：

```sql
pendingbot.crew_parent_links (
  id uuid primary key default pendingbot.uuidv7(),
  parent_crew_id uuid not null references pendingbot.conversations(id) on delete cascade,
  child_crew_id uuid not null references pendingbot.conversations(id) on delete cascade,
  link_kind text not null default 'parent' check (link_kind in ('parent')),
  created_by_kind text not null check (created_by_kind in ('human', 'captain')),
  created_by_user_id uuid null references auth.users(id),
  created_by_bot_id uuid null references pendingbot.bots(id),
  split_mode text not null default 'inherit' check (split_mode in ('inherit', 'explicit')),
  requires_human_confirmation boolean not null default false,
  confirmed_at timestamptz null,
  created_at timestamptz not null default now(),
  unique (parent_crew_id, child_crew_id),
  check (parent_crew_id <> child_crew_id)
)
```

数据库或服务层必须阻止环。

### `crew_members`

成员需要能表达 captain 代表子机组加入父机组：

```sql
member_kind text check (member_kind in (
  'human',
  'bot',
  'captain',
  'code_session'
)),
represents_crew_id uuid null references pendingbot.conversations(id)
```

当 `member_kind = 'captain'` 且 `represents_crew_id` 不为空时，这个成员是某个子机组在当前父机组里的机长代表。

## API 合约建议

第一阶段需要这些 API 能力：

- 创建本地机组；
- 获取机组 DAG 索引；
- 获取某个机组的父机组和子机组；
- 创建继承式子机组；
- 为机组创建或读取 captain；
- 让 captain 作为成员加入父机组；
- 发送机组消息；
- @成员、@session、@captain；
- 获取父机组摘要流；
- 获取 session 事件、mailbox 和执行状态。

需要人类确认的 API：

- 创建 explicit responsibility split；
- 修改父机组集合；
- 修改责任主体比例；
- 绑定云端 machine；
- 创建会产生云端成本的机组。

## 非目标

第一阶段不做：

- 完整云端 Fly Machine 生命周期；
- 子机组完整聊天记录自动同步到父机组；
- merge conflict；
- session 多窗口并排；
- 通用组织架构管理系统；
- 将 PendingCrew 做成普通 IM 客户端。

## 自检

- 术语统一：Crew 中文为机组，supervisor/master bot 改为 captain/机长。
- 父子关系统一：DAG 边代表责任主体比例继承，责任主体比例同时管权限、计费和分摊。
- 消息路由明确：父机组消息不自动进入子机组，由机长自行处理。
- 范围明确：第一阶段做本地机组完整闭环，云端只预留。
- 计费审计明确：每次计费持久化 resolved responsibility split snapshot，并禁止 DAG 环。
