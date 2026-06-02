# PendingBot / PendingCrew 进度账本 (Progress Ledger)

**最近对账：2026-06-02**（对照实际代码 / 迁移 / git，不是看 task 标记）

---

## 0. 这个文档是什么 / 不是什么

这是**活的进度视图** —— 回答"现在到底做到哪了、验证没、卡在哪、下一步是什么"。它是 task system / roadmap / tech-debt 三者之间的**对账与汇总层**，把它们串起来，补上"进度叙事"这个谁都没覆盖的缺口。

四个账本各有本职，**不要混用**：

| 账本 | 本职 | 粒度 |
|---|---|---|
| **Task 系统**（内置 TaskList） | 原子勾选清单，**做没做的事实源** | 单个可提交单元 |
| **roadmap**（`superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md`） | 计划 / 做事顺序 / 依赖 | phase / T 编号 |
| **tech-debt**（`tech-debt.md`） | 结构风险 + 关不掉的尾巴登记 | 风险条目 |
| **本文件**（progress） | 当前真实状态汇总 + 阻塞 + 下一步 | 工作流 / feature rollup |

**判断"做没做"以 Task 系统为准；判断"现在整体到哪了"以本文件为准；两者冲突 = 该对账了。**

## 1. 维护纪律（这个文档失效就白建了）

- **绑到已发生的动作**：小单元 auto-commit 的同一拍翻对应 task 状态；合 sub-agent worktree 后由汇总方对账那批 task。
- **`completed` = 已验证可用**，不是"代码写了"。需人工/真机才能 done 的，task 保持 open + 缺口记 tech-debt。
- **本文件每次 session 末、或合一批活之后更新**，顺手改 roadmap/tech-debt 对应条目，别攒到一次性审计。
- 顶部"最近对账"日期每次更新时改。**超过一两周没动 = 大概率已漂移，需重新对账。**

---

## 2. v1.0 主线（按 roadmap phase）

状态：✅ 完成且验证 · 🟡 部分/有洞 · ❌ 未做。验证列：代码=已合入树 / typecheck / 真机=端到端跑过。

| Roadmap | 状态 | 验证 | Task# | 缺口 / 下一步 | tech-debt |
|---|---|---|---|---|---|
| T0.1 PendingBot 三端脚手架 | 🟡 | 代码 | — | Mac 仅"我"+"好友"tab 接真数据；消息/Crew/来信仍 placeholder | 🔴 Mac 业务接入 |
| T0.2 PendingCrew 双端脚手架 | ✅ | 代码 | — | — | — |
| T1.1 Subject schema | ✅ | 代码 | #161-163 | — | — |
| T1.2 群账号权限矩阵 | 🟡 | 代码 | #167 | edge `/v1/group-subjects/*` 有；**iOS/Mac 客户端没消费**，仍走旧 client 规则 | — |
| T1.3 群账号扫码登录 | 🟡 | 代码 | — | `devicePublicKey` 是 placeholder，没真绑设备 | 🟡 device key placeholder |
| T1.4 三端 IM 基础壳 | 🟡 | 代码 | — | Mac 三栏结构在；中栏会话列表 + 右栏消息流仍 placeholder | 🔴/🟡 Mac 子树 |
| T2.1 Crew schema 扩展 | ✅ | 代码 | — | ⚠️ 三组字段双写未 cutover | 🟡 三组字段双写 |
| T2.2 Captain 三种来源 | ✅ | 代码 | #163 | ⚠️ 实有第四种 `spawned_by_captain`，spec 未同步 | 🟡 spec §6.3.1 |
| T2.3 DAG + 环检测 | ✅ | 代码+单测 | — | 递归 CTE trigger + `crew_attach_as_child` + 内联测试 | — |
| T2.4 责任比例 5 规则 | ✅ | 代码+单测 | — | `crew_recompute_shares`/`propose_split_distinct`/tiebreaker 全有 | — |
| T3.1 Claude Code runner | ✅ | 代码 | — | 本轮修了 nested-ObservableObject 不回流 bug | — |
| **T3.2 Codex runner** | ✅ | 代码+单测 | #202 | argv codex 分支补 `--json`(JSONL 事件流,对标 Claude stream-json)+ `-m/--model` 透传;launch/env/discovery 早已 kind-无关复用。11/11 测试绿(含 model 透传) | — |
| T3.3 工作目录三层 | ✅ | 代码 | — | GitWorktreeService + session sheet | — |
| T3.4 子进程安全 | ✅ | 代码 | — | env 白名单 + SIGTERM/grace/KILL + 首启 disclosure | — |
| T3.5 Session 创建面板 | ✅ | 代码 | — | — | — |
| T4.1 Session↔群聊通信 | ✅ | 代码 | #166-169 | mailbox/whiteboard + post_to_crew | — |
| T4.2 Session 系统提示模板 | ✅ | 代码 | #168 | 走 prompt-loader | — |
| T4.3 Permission Request | ✅ | 代码 | #170-176 | schema + tool + iOS/Mac 卡片 | — |
| T4.4 Bot start_crew tool | ✅ | 代码 | — | `tools/start-crew.ts` + tool-def | — |
| **T4.5 跨端遥控 peer_device** | 🟡 | 代码(服务端**全**+客户端 codec) | #204 | **服务端比账本旧写的完整得多(2026-06-02 重新核实)**:不止 SessionProxyDO —— `crew_sessions` 表 + 整条 runner HTTP 生命周期都在:`POST /v1/crews/:id/sessions`(创建)·`runner-hosts/:id/sessions/:sid/{claim,events,finish}`(`runner:write`)·`GET /v1/sessions/:sid/proxy/connect`·`PATCH .../permission-mode`。**客户端两层地基已落**:wire codec(`d6fba7a3`,14测试绿)+ **session 生命周期 API client**(`289788b3`,createSession/registerRunnerHost/claimSession/appendSessionEvent/finishSession,镜像已上线端点,iOS+macOS 双编译绿)。**剩客户端集成(无 edge/迁移工作,需 device-grant 运行时验)**:① runner-loop 接线(register→claim→publish→finish,用上面 API)② WS 传输(URLSessionWebSocketTask + codec)③ CrewSessionRun 接 server sessionId(现用本地 stub UUID)④ iOS viewer 订阅+遥控 UI ⑤ 两设备 E2E QA。**每步需 device-grant `runner:write`,活验证要登录账号+真机** —— 宜作连贯 feature 一次做,别拆成孤儿/半接(create-不-claim 会留 queued 孤儿行) | 🟡 半截桥(服务端**全好**+codec,客户端链未接) |
| T4.6 iOS Crew Tab v2 | 🟡 | 代码 | — | 群聊 UI + live push + 权限卡done；剩附件、自我气泡高亮 2 洞 | 🟢 Crew Tab 2 洞 |
| T5.1 PendingCrew BYOK 未登录 | ✅ | 代码 | #177 | 本机 captain 池 + BYOK key | — |
| T5.2 双轨路由 | ✅ | 代码 | #177 | EdgeBackend/LocalBackend；⚠️ 无单测 | 🟢 backend 无单测 |
| **T5.3 端到端 QA** | ❌ | — | — | **BYOK/cloud 全链路从没真机跑通** | 仍延期 |

### roadmap 维度真实缺口（就这几个真"没做"）
- ✅ ~~T3.2 Codex runner~~ —— 已补完(#202,2026-06-02)。其上层 **JSONL 事件解析层**也已落地(#203,2026-06-02):`RunnerEventParser` 把 codex/claude 两种 JSONL flatten 成统一 `RunnerEvent` 模型,接进 `CrewSessionRun.events` 并在 session 窗口加「转写」tab 渲染;schema 取自实跑两个 CLI 的 fixtures,9 测试绿。本机 runner 闭环(Phase 3)真实缺口已清零(剩 T5.3 真机 QA 见下)。
- ❌ **T5.3 端到端 QA** —— 整链路没真机验证
- 🟡 **T4.5 客户端侧** —— 服务端 + runner-side codec 已落（#204）；仍缺 WS 传输/server-session 端点/runner 发布/iOS viewer/两设备 QA（仍是半截桥，地基更厚了）
- 🟡 **Mac/iPad IM 业务内容**（T0.1/T1.4）—— 壳在，tab 是 placeholder
- 🟡 **T1.2 客户端消费** —— 后端权限矩阵有了，客户端没用

---

## 3. 独立功能（不在 roadmap）

### Bot 邀请链接（取代旧 slug 分享 — decisions.md D1）
- **状态**：🟡 后端完成并验证；iOS UX 返工进行中（feat/invite-model 分支，未合 main）
- **决策**：旧 slug-直查模型作废（陌生人被 RLS 堵死、ship 即坏）。改为 **invite-token 模型**：好友可签发、关联签发者、7 天有效、可撤销、redeem 记 invited_by。见 decisions.md D1。
- **已落地并验证（2026-06-01）**：
  - ✅ DB（#191，迁移已 push 到 live + schema regen + typecheck 绿）：`bot_invite_links` 表 + `user_bot_contacts.invited_by` + `bot_invite_link_{create,list,revoke,resolve,redeem}` RPC（RLS 不放宽，definer 代写授权行）+ `get_bot_friends` 带 invited_by。
  - ✅ Edge（#192/#193，typecheck 绿）：`POST/GET /v1/bots/:id/invite-links`、`GET/POST/DELETE /v1/bot-invites/:token`、friends 返回 invited_by。
  - ✅ iOS 基础（BotInviteAPI.swift）：API client 方法 + 类型。
- **剩余（#194，未做）**：iOS UX 返工 —— scan/universal-link → resolve → redeem 的 AddBotSheet 改造（去掉手动 slug 加，改 token codec）、ManageBotSheet 分享区改成「签发/管理邀请链接」。**这是 UX 重设计，需 simulator 视觉验证（非仅编译）**。#121-127 旧 slug task 待 #194 完成后一起翻。
- **关联**：D2 群加入码同构（#195，未做）。

---

## 4. Billing v2（#180-190）—— 代码完成 ≠ 可用

主路径（schema / settleUsage / LLM / voice / web tools / sandbox 计费 / share-index / cron）已落地并验证。以下 task 标 completed，但**真实可用还差人工/runtime**，缺口在 tech-debt：

| Task# | 缺口 | 谁能做 |
|---|---|---|
| #185 IAP | JWS 验签已实现（427 行手写 DER/ASN.1，14 单测绿）；**缺真 Apple sandbox 端到端** | 人工 |
| #186 LS refund | 入账 + 反向冲销代码全；**缺 LS test mode 联调** | 人工 |
| #188 Board admin | grant/claw-back RPC 有；**缺 pack 列表/作废/refund 列表/wallet 详情 UI** | 需设计 |
| #189 iOS 钱包 | 余额+账本(含 refund)显示全；**缺 IAP 购买流 / 群池贡献 UI** | 需设计 |
| #190 v1 退役 | 数据已迁；**v1 表当冷备未删，`billing_debit` 等 v1 RPC 仍被调，无 drop 迁移** | 观察期后 |

> 另：sandbox `vendorCostUsd` 仍硬写 0（无 Cloudflare 价目），用户可免费无限跑 execute_code。见 tech-debt 🟡。

---

## 5. 账本一致性待办（本次对账发现的漂移）

- [ ] #121-127 **不翻 completed**（代码已落但功能被 RLS bug 堵死、#128 未验证；按"completed=已验证"规则保持 pending，真实中间态由本文件 §3 记录）；RLS 修通 + #128 跑过后再一起翻
- [ ] tech-debt **T4.5 条目改为"服务端 P0 已落、客户端未接"**（现写成"只有文档"，已过时）
- [ ] tech-debt 新增 **bot 分享 RLS 闭环 bug**（游离缺口，三个账本都没记）
- [ ] roadmap 标注 T3.2 / T5.3 未做、T4.5 半截
