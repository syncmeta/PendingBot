# PendingCrew 接合 v2 — Block 3：edge 信箱（relay）+ 成员接入 设计

> 上游定调：`2026-06-10-pendingcrew-pendingbot-integration-v2.md`（edge = 邮差 + per-crew store-and-forward 信箱；本地永远是 home）。
> 前置已落：拆双轨 backend（`f0c0027b`/`f398bf3d`）—— macOS crew 恒本地，`isAuthenticated` 是能力门。

## 1. 核心模型

**Relay = 一个普通的 edge crew conversation**，与本地 crew 1:1 绑定。不造新 DO、不造新消息系统：

- 本地 crew 是事实源（白板/session/captain 全在 Mac）。
- 登录后用户对某个本地 crew 点「接入 PendingBot」→ Mac 用 device grant 调 `POST /v1/crews` 在 edge 建一个同名 crew conversation（绑 grant 的 subject），把 `remoteConversationId` 存进**本地** crew JSON（local-first：映射放 Mac，不加 edge 表）。
- PendingBot 的 bot / 人类账号作为这个 edge conversation 的成员参与；人类在 iOS 发消息 → bot 经现有 group-turn 管线回复 → 都落 `messages` 表。**Mac 不在线 bot 照样不哑**（管线在 edge）。
- Mac 在线时跑**同步代理**（双向搬运）：
  - 拉：`GET /v1/crews/:id/messages?since=<cursor>` 轮询（device grant 已通），新条目写进本地白板（带 relay 来源标记）。
  - 推：本地白板新 post（human/captain/session 发的）→ `POST /v1/crews/:id/messages` 上行。
  - 游标存本地（`relayCursor`），断线重连自动补齐。

## 2. edge 改造面（按调查 afb9 报告）

1. **trivial — 拉取游标**：`GET /v1/crews/:crewId/messages` 响应加 `lastCursor`（最大 created_at），客户端续传。
2. **trivial — 上行身份**：`POST /v1/crews/:crewId/messages` body 扩展可选 `senderLabel`/`localSessionId`（Mac 代发本地 captain/session 的话语时标注来源；落 `messages.attachments`/log 卡，不冒充人类）。回环防护：上行消息带 `origin:"mac_relay"` 标记，拉取侧过滤掉自己推上去的。
3. **medium — 成员邀请走 grant**：`POST /v1/crews/:crewId/members { kind: bot|human, botId?/userId? }`，device grant + `crew:write` + subject 匹配；新 RPC `crew_add_member_for_subject`（插 `temporary_group_members` + conversation 成员，校验 bot/human 与 subject 的可见性——bot 须是 subject 可用的 bot，human 须是好友/同 subject 成员）。
4. **不做**：edge 侧 binding 表（映射在 Mac 本地）；Realtime/WebSocket 推送（v1 轮询够用，session-proxy 通道留遥控用）。

## 3. Mac 改造面

1. **LocalCrewStore**：crew 模型加 `remoteConversationId: String?` + `relayCursor: String?`。
2. **「接入 PendingBot」UI**：crew inspector（详情页）登录态下显示接入按钮/已接入状态 + 成员邀请入口（v1 先支持邀 bot：列 subject 可用 bots 选一个调 members 端点）。
3. **CrewRelayAgent**（新 service，@MainActor 定时器 ~5s）：对所有已绑定 crew 跑拉/推循环；写本地白板用现有 LocalWhiteboardStore，relay 来的消息 `senderSessionId=nil`、sender 显示 PendingBot 侧名字；本地新消息（cursor 之后产生、非 relay 来源）上行。
4. **captain 感知**：relay 消息进了本地白板，captain 的世界观注入/唤醒机制自动覆盖（无需新通道）。

## 4. 验证

- edge：vitest 覆盖 lastCursor、senderLabel 落库、members 端点权限矩阵（错 subject 403 / 非成员 bot 403 / 正常 201）；typecheck。
- Mac：双平台 build；同步代理单测（mock API：拉合并去重、推防回环、cursor 推进）。
- 端到端（需真机/真账号，留人工拍）：本地 crew 接入 → iOS 看到群 → bot 回复 → Mac 白板出现。
