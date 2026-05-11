# IM 真测报告 — 2026-05-11

两端实跑：
- **iOS Simulator**（iPhone 17 Pro / iOS 26.4）账号 **夕阳** (mac-simu-1@pendingname.com / handle T4S2ET464N / 🐯)
- **Catalyst (Mac)** 账号 **文峰** (mac-01@pendingname.com / 🐌)

驱动方式：computer-use MCP 点击 + iOS 端用 `xcrun simctl pbcopy` 写设备粘贴板再 `cmd+v` 粘贴（直接 `type` 在 iOS UITextField 落不进去，是测试基础设施问题，不是 app 问题）。

---

## 总结一句话

**核心 IM 链路全部通**：1:1 user-user / bot SSE / 群创建+发收 / 人写人来信全跑通。发现 **1 个真 bug + 3 个 UX 问题** 值得跟进，**0 个阻塞性问题**。

---

## 🟢 通过的用例

### 1. 1:1 user-user 实时（✅）

夕阳 ↔ 文峰 已经是好友、有现成 conv。

- Sim 发 "test from sim 1" → Cat 在 ~2 秒内左侧出现，配 🐯 头像
- Cat 回 "reply from cat" → Sim ~2 秒内左侧出现，配 🌵 头像（→ 见下方 UX-A）
- 双向延迟稳定、不丢

### 2. 1:1 bot SSE（✅）

Catalyst → Lorem (claude-opus-4.7 via WorldRouter)：

- 发："用一句话总结上面的格式要点"
- ~3 秒内得到一句精准回复："台湾中文书信没有独立标题，开头是「称谓+提称语」（如「王老师 道鉴：」），下一行空两格接季节问候语。"
- token 流式渲染、markdown 行内 emphasis 都对

### 3. 群聊创建 + 跨端送达（✅）

从 Cat 走 消息列表右上 + → 拉群 → 名 `test-group-claude` → 选 1 个 bot (Sed) + 2 个人。RPC `open_group_conv` 成功。

- Cat 发 "大家好 测试群聊"
- Sim 在 test-group-claude 里 ~瞬间收到，sender 标签是 "3d33ddb8"（→ 见 UX-B）
- bot Sed 没回复（**不是 bug**，是 GroupRouterDO 的 small-router 判断这条无指向问候不需要 wake；符合 [group-router.ts:155](apps/edge/src/llm/group-router.ts:155) 设计）

### 4. 人写人来信（✅，0065 全链路）

Sim 走 文峰 conv → 齿轮（会话设置）→ 「给对方写信」→ LetterComposeSheet：

- title `letter test from sim`
- body 含 H1 + 段落 + 项目列表 + 段落
- 发送 → 关 sheet 回 settings

Cat 来信 tab 立刻出现 **2 封**：
- 夕阳 (🐯, 52 秒前) — title `letter test from sim` — 带 markdown preview flatten
- 示例来信（17 小时前，seeded by 0056）

点开详情：H1 `hello from sim` 渲染成大标题、bullet 列表正常、作者署名 "夕阳 于 5月11日 09:26" + 🐯 头像都对。

→ 0065 的 `are_mutual_friends()` gate + 跨 tab Realtime + markdown render 全部工作。

### 5. 现有 bot envelope letter（✅）

Cat 自带的 `示例来信：先看一眼版式`（seed letter from 0056）渲染：H1/H2/H3 / bullet / 内联链接 高亮 / 副标题排版，layout 干净。

### 6. 加好友完整流程（✅，第三个账号补测）

新开 iPhone 17 模拟器登 **梨香** (mac-simu-17 / 🌽) 测两人陌生 → 朋友的全流程：

| 步骤 | 验证 |
|---|---|
| `GET /lookup?handleValue=T4S2ET464N` | 输入 handle 后立刻显示 **夕阳 + 🐯 + "可以添加为好友"**（preview 从服务端读 user_handles → users 联表） |
| `POST /friend-requests` (with remark) | 200，sheet 干净关闭 |
| Realtime 推到 夕阳 | 夕阳 好友 tab 顶部 「好友申请」section 立即出现 **梨香 + 想加你为好友 + 同意/拒绝**（备注 `claude test` 不显示给对方，按设计是 user_contacts.alias 用） |
| `POST /friend-requests/:id/accept` | 200 |
| `accept_friend_request` RPC 副作用 | 夕阳 好友列表多 **梨香 (人类)**；梨香 好友列表多 **claude test (人类)** ← 备注正确写成 alias |
| 点 "claude test" → 空 conv → 发 "hi from new account" | 双向 1:1 通过；夕阳 conv 列表顶部出现 「梨香 / hi from new account」 |
| 夕阳 回 "welcome new friend" | 梨香 conv 即时收到，bubble 配 🐯 头像（夕阳 真实头像） |

**🟡 副发现 (UX-A 的细化)**：avatar fallback 是**非对称**的——
- 夕阳 看 梨香 → 🐞 ladybug（**错**，梨香 实际是 🌽）
- 梨香 看 夕阳 → 🐯（**对**，匹配 夕阳 实际头像）

→ 推测是新账号 `users.avatar_path` 是 NULL，iOS 用 user_id 客户端确定性 hash 选一个 emoji；但这个 hash 不跨设备一致，或者夕阳 端有缓存层先占了位。需要看 iOS 头像 fallback 路径 [iOS Avatar 渲染](apps/ios/PendingBot/Components/) 是否真的把 NULL avatar 处理成 deterministic emoji。

---

## 🔴 真 bug

### B1 · `groups.ts:566 /continue-decision` 跨 conv 注入

（这条是我昨晚静态审查发现的，今天没在线上触发，因为路径需要 group continue-vote 流程。但代码风险仍在。）

`POST /v1/groups/:id/continue-decision` 用 service-role 把决定文案插到 URL 上的 `:id` conv，而 RPC `group_continue_decide` 只校验 `requestId` 所在 conv 的权限——两个 conv id **没有交叉验证**。理论上能往任意 group 注一条 `✅ 让机器人继续` 决定消息。

修法 5 行：service-role insert 前 cross-check `requestId.conversation_id === param('id')`。

---

## 🟡 UX / 一致性问题

### UX-A · 联系人头像在不同设备上看到的是不同 emoji（非对称）

复现 1：文峰 自己 profile 是 🐌（snail），但在 夕阳 的 1:1 conv 里 文峰 的头像被渲染成 🌵（cactus）。

复现 2（加好友测试时新发现）：
- **梨香** 自己 profile 是 🌽（corn），但 夕阳 看到她是 🐞（ladybug）
- **夕阳** 自己 profile 是 🐯，梨香 看到她也是 🐯（这个方向**对**）

→ 一致的方向（夕阳 → 梨香）正确，反方向（梨香 → 夕阳）错。这指向：
- 新账号 `users.avatar_path` 入库是 NULL
- iOS 客户端在 NULL 时用 user_id 做 deterministic hash 挑 emoji 当 fallback
- **hash 函数在不同 iOS instance 上结果不同**（例如用了平台/时间相关的 seed），所以同一个 user 在不同设备上看到不同的 emoji
- 而对端用户如果有真 avatar_path（比如 夕阳 是早期账号已写过），就稳定显示

**用户角度**：朋友看你的头像跟你自己看到的不一样，会以为加错了人。**根因要么把 fallback 函数改成纯 user_id deterministic（无平台 seed），要么注册时就给一个稳定的服务端 avatar_path**。

### UX-B · 群聊里成员/sender 标签 fallback 不一致

test-group-claude 群成员列表里：
- **夕阳** ✅ display_name 显示
- **3d33ddb8 (群主, 文峰)** 只显示 user_id 前 8 位
- **154464d1** 同上

群里收到 文峰 发的消息，sender 标签也是 `3d33ddb8` 不是 "文峰"。

但 文峰 在 Catalyst 自己的 profile / 好友列表 / 1:1 conv 标题里都正常显示 "文峰"。

→ 群成员/消息的 display_name 解析路径跟其他视图不在一条上，可能漏了 `pendingbot.users` join，或者用了 `conversation_participants.nickname` 在没设 nickname 时 fallback 到 id 而没 fallback 到 `users.display_name`。

[GroupRouterDO.resolveSenderLabels](apps/edge/src/durable-objects/group-router.ts:231) 这块逻辑写得是对的（先读 nickname，再 fallback 到 display_name，再 fallback 到 "某人"）；问题应该在 **iOS 渲染端**，没有走 worker 解析的 sender_label，而是直接用了 user_id 前缀。

### UX-C · 拉群 picker 完全不显示 display_name / avatar

发起群聊面板的 「真人成员」section 只列 8-char hex id（`154464d1` / `862c7a12`），**完全不显示 display_name 也不显示 avatar**。

但同一批人在好友列表里都有正确的 `夕阳 (🐯)` / `淳化 (🍌)` 渲染。

→ iOS [NewGroupSheet / ContactPicker](apps/ios/PendingBot/Features/Group/) 没把 user_contacts 的 display_name + avatar_path join 进来。**用户根本不知道自己在选谁**。

**修复后 UX-B 的"群成员 fallback 不一致"很可能也一并解决**——大概率是同一处缺 join。

### UX-D · 会话列表 Realtime 刷新不彻底

观察了多次：
- 在某个 conv 里发消息，回到列表，**有时**对应行的 last preview / timestamp 不更新
- 切到别的 tab 再切回来，列表才刷新
- 不一定哪条更新哪条不更新——例如同一时刻 `夕阳` 行更新了但 `1` 群行没更新

不影响数据正确性（DB 里时间戳/preview 是对的），但视觉上让人怀疑消息没发出去。

→ 可能是 iOS 列表订阅了 conversations 表的 Realtime，但 update 事件的 payload 触发的 diff 不完整；也可能是 `last_activity_at` 在某些场景没被服务端更新。

---

## ❓ 没真测到的

| 用例 | 原因 |
|---|---|
| group QR 扫码入群 | iOS 扫码需要相机；模拟器没有可用相机源。需要真机才能测，或者解析 group qr 内容手动调 `/v1/groups/join`。 |
| 群冻结门 cap_credits | 触发条件是组内某成员开支超 cap；今天发的几条消息成本极低，没触发到。 |
| bot 写信（envelope kind=bot）触发 | 需要在 bot conv 里走 settings → 「请这位机器人写信给你」并等待。LLM 跑一次几十秒，这个用例下次跑慢的时候单独试。 |

---

## 🛠 给修 bug 的人的优先级

1. **B1**（continue-decision 跨 conv 注入）— 5 行 + 单测，安全相关，直接修
2. **UX-C**（拉群 picker 不显示 display_name）— 影响最直接，根因可能也覆盖 UX-B
3. **UX-A**（1:1 对方头像 emoji 不对）— 排查头像数据来源
4. **UX-D**（列表刷新不彻底）— 难复现，需要先 instrument 一下 conversations 的 Realtime 订阅日志
5. **UX-B**（群成员 sender 标签）— 大概率随 UX-C 一并修

---

## 测试基础设施备注

- iOS 模拟器的 UITextField 不接 computer-use `type`（某些字段接，大部分不接）。**workaround**：`echo -n "<text>" | xcrun simctl pbcopy <device-udid>` → 在模拟器里点字段 → `cmd+v`
  - 中文走 `simctl pbcopy` 偶发 NSCocoaErrorDomain 261 编码报错，要先用 `printf` 或重定向到 UTF-8 文件再喂
- Catalyst 的输入框 `type` 工作正常（中文也行），但需要先 `left_click` 一次确保焦点
- `xcrun simctl io <udid> screenshot <file>` 是无权限读模拟器截图的最快路径（写报告时 fallback 用过）

— 报告生成于 2026-05-11 09:30
