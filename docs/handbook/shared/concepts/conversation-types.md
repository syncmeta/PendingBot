# 会话类型

大绿豆里所有"对话"是同一张底层会话表,靠一个 `conversation_type` 区分定位。理解这几类各自管什么,是看懂消息怎么流、谁付费、谁可见的前提。

**逻辑** —— 当前在用的会话类型:

| 类型 | 定位 |
|---|---|
| **1:1(人 ↔ bot)** | 一个用户和一个 bot 的日常对话。PendingBot 的主入口。 |
| **1:1(人 ↔ 人)** | 两个好友之间的会话;两人之间全局只有一个,反复点进的是同一个。 |
| **自聊(self)** | 用户和自己的会话(草稿 / 笔记式)。 |
| **群(group)** | 多个用户 + bot 的群聊。普通 IM 群。 |
| **crew** | PendingCrew 的编排单元 —— 一组群聊 + coding agent 的权限边界。`conversation_type = 'crew'`。 |
| **临时群(temporary_group)** | bot 主动拉起的临时协作群(如 bot 判断"这事得拉个群一起弄")。 |
| **子会话(subagent)** | 一个 bot 把任务委托给另一个 bot 时开的只读子对话,用户能点开看完整委托过程。 |

**为什么这么分**
- **同一张表 + 类型字段**,而不是给每种对话单独建表 —— 消息、参与者、未读这些通用机制只写一遍,新类型只是多一个枚举值 + 各自的元数据表。
- **crew 是 conversation_type=crew,不是另起一套系统** —— 这是关键设计:crew 本质上**就是一种会话**(人类显式创建的、带 coding agent 权限边界的群聊),复用整套会话基础设施(消息、参与者、群聊白板),只是多挂了责任主体、所在地、captain、DAG 边等 crew 专属属性。没有 crew 就不能启动 agent。crew 的产品模型见 pendingcrew [`crew`](../../pendingcrew/concepts/crew.md)。
- **子会话与临时群让"bot 自己开会话"成为一等公民** —— 委托 / 主动协作不是临时 hack,而是有明确类型、可持久化、可被用户看到的会话。

**用在哪·长什么样**
- 用户在 PendingBot 看到的会话列表混着 1:1、群、crew(crew 在 PendingBot 里以入口形式出现,深度操作在 PendingCrew)。
- 子会话**不进未读 / 不占会话列表主位**,是点进委托才看得到的旁支。
- crew 群聊是 PendingCrew 三栏 UI 的中栏,既是人和 captain 对话的地方,也是子 crew captain 回摘要的地方。

**边界**
- **类型决定可见 / 计费 / 路由,不是装饰** —— 比如 crew / 临时群绑 `responsible_subject_id`(谁付钱谁可见),普通 1:1 绑用户。别把 `conversation_type` 当成纯展示标签。
- **父子 crew 之间不自动同步消息** —— crew 的 DAG 是权限关系,不是消息广播;父说的话留在父 crew,子 captain 自己读、自己判断要不要拆解(见 pendingcrew [`crew`](../../pendingcrew/concepts/crew.md) / [`dag-and-responsibility`](../../pendingcrew/concepts/dag-and-responsibility.md))。

**注意**
- **已废弃的旧类型别写回** —— 历史上有过 `discuss` / `surf` / `portrait`(早期"复盘 / 冲浪 / 群议"曾各占一种会话类型)、以及一度用来标群账号雏形的旧值,均已废。当前 schema 的 `conversation_type` 允许集只有:`user_bot` / `user_user` / `group` / `self` / `subagent` / `temporary_group` / `crew`。
- **"crew 是一种会话"容易被误解成"crew 另有一套对话系统"** —— 不是。它就是会话表里 `conversation_type='crew'` 的一行,加一组 crew 元数据。看到老 spec 把 crew 描述成独立子系统时,以"它是一种 conversation_type"为准。
- **临时群和 crew 共用一张元数据表** —— `temporary_group_meta` 用 `temporary_kind ∈ {bot_temporary_group, crew}` 再细分(crew 必须是人类发起)。这是实现层的事,产品上记住"crew = 人类建的、临时群 = bot 拉起的"即可。

**现状** — 🟨 会话类型本身的 schema(含 crew / temporary_group / subagent)已落 + db push;1:1 / 群 / 子会话(委托)是当前已验证可用的主路径(✅);crew / 临时群作为 PendingCrew 编排底座代码已落,但端到端依赖 PendingCrew 登录 + runner 链路,整体 pre-launch 未全验。crew 现状以 pendingcrew 册各篇为准。
