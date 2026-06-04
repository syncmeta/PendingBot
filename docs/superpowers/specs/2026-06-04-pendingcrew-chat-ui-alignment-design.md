# PendingCrew 中栏群聊 UI 对齐 PendingBot（iOS 设计语言）

**日期**：2026-06-04
**分支**：`feat/pendingcrew-chat-align`
**范围**：PendingCrew macOS 中栏群聊（`CrewChatView`）的视觉重画 + 一处 edge 配套改动。**不含** runner 改造（那是独立的第二个 spec）。

---

## 1. 目标与非目标

**目标**：把 PendingCrew 中栏的群聊从当前自绘的简易气泡（`RoundedRectangle(cornerRadius:12)` + accent/secondary 两色填充 + 行内文字 sender 标签、无头像）重画成 **PendingBot iOS 群聊**的视觉语言——头像 + 名字抬头 + 连续圆角气泡 + hairline 描边 + 暖色调 token + 5 分钟时间分隔 pill。

**参照基准**：**PendingBot 的 iOS app**（`apps/pendingbot/Sources/...`，用户认真打磨过的那套）。**不**参照 PendingBot 的 Mac 版（骨架，未打磨）。

**总方针**：在 PendingCrew 内**原生重画**，数据绑 `CrewWhiteboardEntry`。**不**抽共享 Swift Package、**不**引 PendingBot 私有代码——保住 PendingCrew README 的"独立、可开源、可不登录 BYOK 使用"定位。只搬**设计数值**（hex / 尺寸），不搬代码文件。

**非目标**：
- 不改轮询模型（中栏仍 3s 轮询；白板无 token 流，故**不需要**流式光标）。
- 不做附件（crew 白板无附件，composer 省掉 `+` 按钮）。
- 不碰 runner / session 窗口（右栏）/ 左栏 crew 列表的视觉。

---

## 2. 关键约束：白板消息缺 sender 身份

`CrewWhiteboardEntry`（`apps/pendingcrew/Sources/Services/PendingCrewAPI.swift:504`）当前只带：
- `senderKind`：`'session' | 'user' | 'bot'`（粗粒度）
- `senderSessionId`：仅 session 作者有

**没有** `sender_user_id` / `sender_bot_id`。后果：
- `session` 作者 → 可用 `senderSessionId` join `CrewMember.codeSessionId`（`PendingCrewAPI.swift:561`）拿到 `displayName` + `sessionStatus` ✅
- `bot` 作者 → 拿不到是哪个 bot，多 bot 群会贴错头像 ⚠️
- `user` 作者 → 拿不到 user_id，多人群里无法区分谁是谁 ⚠️

**决策（已定）**：补 edge，让白板端点返回 sender 身份，每个作者都能贴对头像+名字，真正对齐 PendingBot。

### 2.1 Edge 改动（已核实：纯序列化，零迁移）
**核实结论**：中栏白板端点 `GET /v1/crews/:crewId/messages`（`apps/edge/src/routes/crew-comms.ts:295`）其实读的是 conversation 的 **`messages`** 表（spec §9 统一存储），经 `mapMessageToEntry`（`crew-comms.ts:71`）映射成白板 entry 线型。`messages` 行**已带** sender 身份：`user_id`（user role）、`sender_bot_id`（bot role，`schema.ts:2151`）；session 卡在 `log_payload` 里。当前映射函数把这些丢掉了（`sender_session_id: null`，user_id/sender_bot_id 不透出）。

所以**不需要迁移**，改动是纯序列化：
- 扩 `CHAT_SELECT`（`crew-comms.ts:92`）加 `sender_bot_id`。
- `mapMessageToEntry` 多 emit：`sender_user_id`（user role = `m.user_id`）、`sender_bot_id`（bot role = `m.sender_bot_id`）、`sender_session_id`（log/session 卡从 `log_payload.session_id` 取，无则 null）。
- 同步更新 `CrewWhiteboardEntry`（iOS）解码 `sender_user_id` / `sender_bot_id`（可选）。

历史行天然带这些列（messages 一直在写），故无回填问题——§4.3 的 fallback 仅兜 null 边角。

---

## 3. 设计 token（PendingCrew 自带）

PendingBot 的 `Theme.swift` 是 `#if os(iOS)` 包着的，PendingCrew（原生 macOS）无法复用。新建 `apps/pendingcrew/Sources/Mac/Design/CrewTheme.swift`，把 PendingBot iOS 的**确切数值**抄成 PendingCrew 本地常量（纯值，零代码耦合）：

**Palette**（来自 `apps/pendingbot/Sources/Components/Theme.swift`）：
| token | hex | 用途 |
|---|---|---|
| `accent` | `#044735` | 强调（发送钮、captain 星标） |
| `accentBg` / `userBubble` | `#E3EEEA` | 我的气泡底 |
| `canvas` | `#FDFCFA` | 页面底 |
| `surface` | `#FFFFFF` | 别人气泡底 / 卡片 |
| `surfaceMuted` | `#EFEEE9` | chip / roster 底 |
| `ink` | `#1B1A14` | 主文字 |
| `inkMuted` | `#6E6A5C` | 名字抬头 / 时间戳 |
| `hairline` | `#E2E0D7` | 0.5pt 描边 |
| `amber`/`amberBg` `#6F5A0B`/`#FAEDC2`，`plum`/`plumBg` `#5B3D8A`/`#ECE3F7` | | 备用 tag 配色 |

**Metrics**：`gutter: 16`、`bubbleRadius: 18`、`cardRadius: 14`、`pillRadius: 999`、`readableColumn: 760`。

**Fonts**：本地 helper（system / rounded / serif），抄 PendingBot 的尺寸阶（body 16、caption 12、caption2 11…）。macOS 不需要 Catalyst 的 `macFontScale`，scale=1。

> 同时新建 `CrewColorHash.swift`：抄 `apps/pendingbot/Sources/Components/ColorHash.swift` 的算法（从 id 派生柔色底 + emoji），保证同一 bot/user 的头像配色与 PendingBot 端一致。

---

## 4. 消息行 `CrewBubbleRow.swift`

对齐 PendingBot `BubbleView`（`apps/pendingbot/Sources/Features/Message/BubbleView.swift`）的语法，但绑 `CrewWhiteboardEntry`。

### 4.1 三种作者头像（30pt 圆形）
- `bot` → `CrewColorHash` 柔色底 + emoji 字形（用 `sender_bot_id` 派生）。captain（`CrewRoster.captainBotId` 命中）加小星标角标。
- `session` → 终端字形 `terminal.fill`，绿系底（crew 特有作者类型，PendingBot 无）。名字下方挂运行状态点：`running` 绿 / `queued` 黄（来自 `CrewMember.sessionStatus`）。
- `user` → 右对齐"我"气泡，**无头像**（同 PendingBot：自己消息不显头像）。其他人类成员（非我）走左对齐 + `UserAvatar` 风格头像。

### 4.2 气泡样式
- 连续圆角 `bubbleRadius: 18`（`.continuous`）。
- 别人：`surface` 底 + 0.5pt `hairline` 描边；padding 水平 14 / 垂直 10。
- 我：`userBubble`(`#E3EEEA`) 底，同样圆角描边。
- 文字 `body`(16) / callout，`.textSelection(.enabled)`。
- 名字抬头：左对齐作者气泡正上方，11pt semibold rounded `inkMuted`（仅别人、仅群聊）。
- 宽度遵循 `readableColumnWidth`（macOS 下 leading 对齐、不强行居中——抄 PendingBot 的 Mac 处理思路）。

### 4.3 身份解析（含 fallback）
查表顺序：
1. `session` → `senderSessionId` join `CrewMember.codeSessionId` → displayName + status。join 不到 → "session · <8 位前缀>" + 终端头像。
2. `bot` → `sender_bot_id` join roster bot 成员 → displayName + 头像。**回填不到 / 老行 null** → captain 兜底；再不行用通用 "bot" 头像（记 tech-debt：仅当 edge 回填覆盖不全时短暂出现）。
3. `user` → `sender_user_id` == 本地登录 user → 右对齐"我"；否则左对齐 + 该成员 displayName/头像。**null** → 当"我"（BYOK 单人场景正确）。

---

## 5. 周边元素

- **时间分隔 pill**：新建 `CrewTimeSeparator.swift`，抄 PendingBot `RelativeMessageTime.swift` 的 `TimeSeparatorPill` + 5 分钟间隔逻辑（`几秒前 / 几分钟前 / 昨天 HH:mm / MM/DD HH:mm`）。`CrewWhiteboardEntry.createdAt` 是 ISO 字符串，解析成 Date 后比较间隔。
- **ask_human 交互卡片**：现有黄卡（`payload.kind == "interaction"`）重绘成 PendingBot `PermissionRequestCard` 的视觉语言（卡片底 `surface` + `cardRadius` + hairline，标题行带图标，问题文 + 回复 TextField/已回答态）。功能不变：pending 时 TextField+「回答」调 `answerInteraction`，已答显示「已回答」。
- **Composer**：重画对齐 PendingBot `ComposerView` —— 胶囊 TextField（占位「发消息…」，1–6 行自适应）+ 圆形发送钮（accent 填充、空时禁用灰、发送中 stop 态）。crew 白板无附件 → **省掉 `+` 按钮**。
- **Roster 条（保留，重样）**：顶部横向头像条保留（PendingCrew 特有的"一眼看 captain/session 运行状态"价值），但用 §4.1 的新头像组件重画成一排干净的成员头像（session 带状态点），视觉语言对齐 iOS。不折进导航。

---

## 6. 文件清单（新增，均在 `apps/pendingcrew/Sources/Mac/`）

| 文件 | 职责 |
|---|---|
| `Design/CrewTheme.swift` | Palette / Metrics / Fonts 本地 token |
| `Design/CrewColorHash.swift` | id → 柔色底 + emoji（抄 PendingBot 算法） |
| `Views/CrewAvatar.swift` | 三种作者头像（bot / session / user） |
| `Views/CrewBubbleRow.swift` | 单条消息行（头像 + 名字抬头 + 气泡） |
| `Views/CrewTimeSeparator.swift` | 时间分隔 pill |
| `Views/CrewInteractionCard.swift` | ask_human 卡片（从 CrewChatView 内联函数抽出 + 重样） |
| `Views/CrewComposer.swift` | 胶囊输入 + 发送钮 |
| `Views/CrewRosterBar.swift` | roster 头像条（从 CrewChatView 内联抽出 + 重样） |

`CrewChatView.swift` 改成组合上述组件的瘦容器（timeline ForEach → `CrewBubbleRow` / `CrewInteractionCard` / `CrewTimeSeparator`；顶部 `CrewRosterBar`；底部 `CrewComposer`）。

edge 侧：白板序列化补 `sender_user_id`/`sender_bot_id`（+ 视核查结果可能一条迁移）。

---

## 7. 验证

- Edge：`bun --filter='@pendingbot/edge' run typecheck`；若动迁移则 `db push` + `types:db` regen + commit。
- iOS/macOS：`cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build`。
- **真机/真用**：按用户惯例，编译过不算完 —— 构建后 `open` 跑起来，对一个有 session/bot/多消息的 crew 截图，肉眼核对头像/名字/气泡/时间分隔/roster 与 PendingBot iOS 群聊观感一致。

---

## 8. tech-debt / 尾巴

- 若 edge 走"序列化补字段"而历史 `crew_announcements` 行 sender 身份回填不全 → bot/user 头像短暂 fallback。记 `docs/tech-debt.md`（🟡），回填补齐后销账。
- PendingCrew 至此引入第一套设计 token（`CrewTheme`）。后续右栏 session 窗口 / 左栏列表若也要对齐，复用这套 token（本 spec 不含）。
