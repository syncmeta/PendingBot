# PendingCrew ⊗ PendingBot 接合 v2 —— 本地为家,edge 是邮差

**2026-06-10 用户重定调。取代** `2026-06-05-pendingcrew-local-first-crew-design.md` **§8 的接合定调**(那版的"captain 两实现按托管位置选 / 单后端+毕业"作废)。设计哲学对标 **Claude Code / Codex 的 remote control**:session/工作发生在本地机器,云只是 access 通道 + 队列;你从任何地方"探进来",但家永远在本地。

## 推翻什么(旧设计的三个错误)

1. **双轨 backend 作废**。现状 `AppModel.mode` 全局二选一(登录 → 整个 app 切 EdgeBackend,本地 crew 消失)是错的形态。**本地 crew 永远在、永远显示**;登录 PendingBot 只是账号级**能力叠加**,不是模式切换。
2. **edge-bot captain 作废**。captain **只有一种形态 = 本地 session**(claude/codex 进程 + 机长 persona,跑在 Mac 上)。`crews.captain_bot_id` 的"captain=bot"语义作废;任务 #241(bot captain 被群消息唤醒)作废;#242 里"captain 在 edge 编排"的半边作废(**edge→Mac 队列通道保留** —— 它是遥控/手机下指令的路径,auto-claim 已实现)。
3. **"毕业"(publish local→edge、整 crew 换后端)作废**。crew 不搬家。

## 新模型

### PendingCrew 接入 PendingBot,只实现两个功能

1. **遥控(控制面)**:在手机 PendingBot 上遥控 Mac 上跑的 session。载体 = 已建的 `SessionProxyDO` / T4.5(Mac 持久外连当 runner、手机当 viewer、命令/权限落库、轮询兜底)。**不变,继续收尾。**
2. **成员接入(通信面)**:PendingBot 的 **bot** 和**人类账号**可以**作为成员加入**本地 crew 的群聊。加入的是成员 —— 不当 captain、不把 crew 搬走。

### 白板消息路径:本地真源 + edge 邮差信箱(store-and-forward)

- **真源 = Mac 本地白板**(现有 `LocalWhiteboardStore`,每 crew JSON)。所有消息最终都汇入这里。
- **edge = 邮差 + per-crew 中转信箱**:
  - 远端成员(bot / 手机人类)的发言进信箱 → **即时分发给其它远端成员**(bot 收到就能答 —— bot 的脑子在 edge 的 bot-reply 管线,**不依赖 Mac 在线**;手机人类即时看到)→ 同时排队投递给 Mac。
  - Mac 在线即收、离线回线后补收,落入本地白板(本地 session/captain 由 hook 注入照常看到)。
  - 本地消息(session / captain / 本机人类)上行 → 信箱 → 分发给远端成员。
- **Mac 离线时**:远端这边(bot ↔ 手机人类)照聊;本地 session/captain 离线;Mac 回线后**双向补齐**。信箱是中转 + 最近窗口缓存,不是 home —— email 语义,最终一致到本地。
- 纯本地 crew(没邀请任何远端成员)完全不碰 edge,一切照旧。

### Captain(chunk 2,新模型下更简单)

- 唯一形态:本地 session。常驻/被本地白板唤醒,接 `ask` 的 triage、编排工具(派 session)。
- 不用做两套了 —— edge 侧没有 captain 执行体,只有信箱。

## 改造面(现状代码与新模型的冲突清单)

1. **拆双轨**:`BackendMode` 不再决定"看哪套 crew"。crew 列表 = 本地 crew(永远)＋(登录后)它们各自的联网状态;`LocalBackend` 是常驻 home,Edge 退化成"叠加能力的 API client"(遥控 + 信箱 + 邀请),不再是平行 backend。`CrewStore`/侧栏/`CrewChatView` 跟着改。
2. **成员模型**:本地 crew 花名册加"远端成员"(bot / 人类账号,经邀请加入);邀请流(从 PendingBot 好友/bot 列表选)。
3. **edge 信箱**:per-crew relay(新 DO 或复用现有 crew conversation/mailbox 基建,实现时定);bot 挂进信箱即可被 bot-reply 管线驱动(复用 PendingBot 群聊既有行为)。
4. **Mac 同步代理**:PendingCrew 在线时维持与信箱的连接(类比 SessionProxyDO 的 runner 外连),双向搬运 + 断线补齐(游标)。
5. **作废物清理**:`captain_bot_id` 语义、#241、#242 captain 半边、"毕业"概念、双轨 backend 文案。

## 不变的部分

- 登录 SSO(家族凭据/一键登录)—— 它就是"账号级能力叠加"的钥匙,与新模型同构。
- ask/审批(本地 ask 工具、权限 hook、内联卡片、白板通知)。
- 本地 prompts / world-model 注入 / crew-comms MCP helper。
- SessionProxyDO 遥控全套。

## 排序建议

1. **Chunk 2 captain-session**(纯本地,不依赖本 spec 的 edge 件;且把"和 session/captain 单聊 + 未读 + reporter"一起兑现)。
2. **拆双轨 backend**(app 内重构,不依赖 edge 新件,清掉错误形态)。
3. **edge 信箱 + 成员接入**(bot/人类入 crew,需要 edge 新件 + Mac 同步代理)。
4. 遥控 T4.5 收尾照旧并行。
