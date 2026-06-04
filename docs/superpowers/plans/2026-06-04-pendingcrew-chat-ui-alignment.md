# PendingCrew 中栏群聊 UI 对齐 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PendingCrew macOS 中栏群聊从自绘简易气泡重画成 PendingBot **iOS** 群聊的视觉语言（头像+名字抬头+连续圆角气泡+hairline+暖色 token+时间分隔 pill），数据仍绑 `CrewWhiteboardEntry`。

**Architecture:** 在 PendingCrew 内**原生重画**一套对齐 PendingBot iOS 观感的组件（本地 `CrewTheme` token + `CrewColorHash` + `CrewAvatar`/`CrewBubbleRow`/`CrewTimeSeparator`/`CrewInteractionCard`/`CrewComposer`/`CrewRosterBar`），不抽共享包、不依赖 PendingBot 私有代码。配套一处 edge **纯序列化**改动：白板端点把 `messages` 行已有的 sender 身份（`user_id`/`sender_bot_id`）透出，让客户端 join roster 给每个作者贴对头像+名字。

**Tech Stack:** SwiftUI (macOS 14+, 原生非 Catalyst)、XcodeGen、Hono + supabase-js (edge)、vitest。

**参照基准（只读不改）：**
- 视觉源：PendingBot **iOS** —— `apps/pendingbot/Sources/Components/Theme.swift`（token 数值）、`ColorHash.swift`、`Features/Message/BubbleView.swift`、`Components/RelativeMessageTime.swift`、`Features/Message/ComposerView.swift`。**不参照** PendingBot Mac 版（骨架）。
- 现状：`apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`（待重构的瘦容器目标）、`apps/pendingcrew/Sources/Services/PendingCrewAPI.swift:504`（`CrewWhiteboardEntry` / `CrewMember`）。

**通用验证命令：**
- Edge typecheck：`bun --filter='@pendingbot/edge' run typecheck`
- Edge 单测：`cd apps/edge && ./node_modules/.bin/vitest run tests/crew-comms.test.ts`
- macOS 构建：`cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -5`

> ⚠️ XcodeGen 注意（实施中已纠正）：本计划新增的 `.swift` 文件落在 `Sources/Mac/**`。**最初误以为 project.yml 的 `sources` glob 会让 xcodebuild 自动纳入——错。** `PendingCrew.xcodeproj` 已 commit，glob 在 **xcodegen 生成时**展开、不在 build 时；新增文件后**必须 `cd apps/pendingcrew && xcodegen` 重生 `project.pbxproj` 并提交**，否则文件不进编译 target、build 出现"假绿"（不报错只是没编它们）。每加一批新文件就重跑 xcodegen + 提交 pbxproj，再 `xcodebuild` 才是真验证。

---

## File Structure

**新增（均在 `apps/pendingcrew/Sources/Mac/`）：**
| 文件 | 职责 |
|---|---|
| `Design/CrewTheme.swift` | Palette / Metrics / Fonts 本地 token（搬 PendingBot iOS 数值） |
| `Design/CrewColorHash.swift` | id → 柔色底 + emoji + 首字（搬 PendingBot 算法，去 iOS guard） |
| `Views/Chat/CrewSenderResolver.swift` | `CrewWhiteboardEntry` + roster → `CrewSender`（kind/名字/头像 seed/是否我） |
| `Views/Chat/CrewAvatar.swift` | 三种作者头像（bot / session / human），30pt 圆 |
| `Views/Chat/CrewBubbleRow.swift` | 单条消息行（头像 + 名字抬头 + 气泡） |
| `Views/Chat/CrewTimeSeparator.swift` | 5 分钟间隔相对时间 pill + 间隔计算 |
| `Views/Chat/CrewInteractionCard.swift` | ask_human 卡片（重样） |
| `Views/Chat/CrewComposer.swift` | 胶囊输入 + 圆形发送钮 |
| `Views/Chat/CrewRosterBar.swift` | roster 头像条（用 `CrewAvatar` 重画） |

**修改：**
| 文件 | 改动 |
|---|---|
| `apps/edge/src/routes/crew-comms.ts` | `CHAT_SELECT` 加 `sender_bot_id`；`mapMessageToEntry` 透出 sender 身份；export 该函数供测试 |
| `apps/edge/tests/crew-comms.test.ts` | 加 `mapMessageToEntry` 单测 |
| `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift` | `CrewWhiteboardEntry` 解码 `sender_user_id`/`sender_bot_id` |
| `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift` | 重构成组合新组件的瘦容器 |

---

## Task 1: Edge — 白板序列化透出 sender 身份（TDD）

**Files:**
- Modify: `apps/edge/src/routes/crew-comms.ts:61-92`
- Test: `apps/edge/tests/crew-comms.test.ts`

- [ ] **Step 1: 把 `mapMessageToEntry` 改成 export，并写失败测试**

在 `apps/edge/tests/crew-comms.test.ts` 顶部加导入与一组断言（若文件已有 import 块就并入）：

```ts
import { mapMessageToEntry } from '../src/routes/crew-comms';

describe('mapMessageToEntry sender identity', () => {
  const base = { id: 'm1', conversation_id: 'c1', created_at: '2026-06-04T00:00:00Z', log_kind: null, log_payload: null };

  it('user prose carries sender_user_id', () => {
    const e = mapMessageToEntry({ ...base, role: 'user', content: 'hi', user_id: 'u1', sender_bot_id: null } as any);
    expect(e.sender_kind).toBe('user');
    expect(e.sender_user_id).toBe('u1');
    expect(e.sender_bot_id).toBeNull();
  });

  it('bot reply carries sender_bot_id', () => {
    const e = mapMessageToEntry({ ...base, role: 'bot', content: 'yo', user_id: null, sender_bot_id: 'b1' } as any);
    expect(e.sender_kind).toBe('bot');
    expect(e.sender_bot_id).toBe('b1');
    expect(e.sender_user_id).toBeNull();
  });

  it('log/session card pulls session id from log_payload', () => {
    const e = mapMessageToEntry({ ...base, role: 'log', content: null, user_id: null, sender_bot_id: null,
      log_kind: 'interaction', log_payload: { kind: 'interaction', session_id: 's1', question: 'ok?' } } as any);
    expect(e.sender_kind).toBe('session');
    expect(e.sender_session_id).toBe('s1');
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/edge && ./node_modules/.bin/vitest run tests/crew-comms.test.ts`
Expected: FAIL —— `mapMessageToEntry` 未 export（import 报错）/ 新字段为 undefined。

- [ ] **Step 3: 改 `crew-comms.ts`**

`ChatMessageRow` 类型加 `sender_bot_id`（`crew-comms.ts:61`）：

```ts
type ChatMessageRow = {
  id: string;
  conversation_id: string;
  role: string;
  content: string | null;
  user_id: string | null;
  sender_bot_id: string | null;
  log_kind: string | null;
  log_payload: Record<string, unknown> | null;
  created_at: string;
};
```

`mapMessageToEntry` 改成 export 并透出身份（`crew-comms.ts:71`）：

```ts
export function mapMessageToEntry(m: ChatMessageRow): Record<string, unknown> {
  const lp = (m.log_payload ?? {}) as Record<string, unknown>;
  const senderKind =
    m.role === 'user' || m.role === 'human' ? 'user'
    : m.role === 'bot' || m.role === 'assistant' ? 'bot'
    : m.role === 'log' ? 'session'
    : m.role;
  const payload = m.role === 'log' ? lp : { text: m.content ?? '' };
  const sessionId = typeof lp.session_id === 'string' ? lp.session_id : null;
  return {
    id: m.id,
    crew_conversation_id: m.conversation_id,
    sender_kind: senderKind,
    sender_user_id: senderKind === 'user' ? m.user_id : null,
    sender_bot_id: senderKind === 'bot' ? m.sender_bot_id : null,
    sender_session_id: sessionId,
    message_kind: m.log_kind ?? 'text',
    summary: m.content ?? (typeof lp.question === 'string' ? lp.question : null),
    payload,
    created_at: m.created_at,
  };
}
```

`CHAT_SELECT` 加 `sender_bot_id`（`crew-comms.ts:92`）：

```ts
const CHAT_SELECT = 'id, conversation_id, role, content, user_id, sender_bot_id, log_kind, log_payload, created_at';
```

- [ ] **Step 4: 跑测试 + typecheck**

Run: `cd apps/edge && ./node_modules/.bin/vitest run tests/crew-comms.test.ts && cd .. && bun --filter='@pendingbot/edge' run typecheck`
Expected: PASS + typecheck 通过。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/routes/crew-comms.ts apps/edge/tests/crew-comms.test.ts
git commit -m "feat(edge): 白板序列化透出 sender 身份(user_id/sender_bot_id/session_id)"
```

---

## Task 2: iOS — `CrewWhiteboardEntry` 解码 sender 身份

**Files:**
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift:504-540`

- [ ] **Step 1: 加字段 + CodingKeys**

在 `CrewWhiteboardEntry`（`PendingCrewAPI.swift:504`）加两个可选字段与 key：

```swift
struct CrewWhiteboardEntry: Decodable, Identifiable, Equatable {
    let id: String
    let senderKind: String          // 'session' | 'user' | 'bot'
    let senderSessionId: String?
    let senderUserId: String?       // 新增：user 作者
    let senderBotId: String?        // 新增：bot 作者
    let messageKind: String
    let summary: String?
    let createdAt: String
    let payload: Payload?

    // ...Payload 不变...

    enum CodingKeys: String, CodingKey {
        case id
        case senderKind = "sender_kind"
        case senderSessionId = "sender_session_id"
        case senderUserId = "sender_user_id"
        case senderBotId = "sender_bot_id"
        case messageKind = "message_kind"
        case summary
        case createdAt = "created_at"
        case payload
    }

    var displayText: String { payload?.text ?? summary ?? "" }
    var isInteraction: Bool { payload?.kind == "interaction" }
}
```

> `Decodable` 对缺失的可选字段自动给 nil，老服务端响应也能解（向后兼容）。

- [ ] **Step 2: 构建确认编译**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Services/PendingCrewAPI.swift
git commit -m "feat(pendingcrew): CrewWhiteboardEntry 解码 sender_user_id/sender_bot_id"
```

---

## Task 3: 设计 token `CrewTheme.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Design/CrewTheme.swift`

数值搬自 `apps/pendingbot/Sources/Components/Theme.swift`（hex 一致即配色一致）。

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// PendingCrew 本地设计 token —— 数值对齐 PendingBot iOS Theme，但独立成 macOS
/// 原生实现，不依赖 PendingBot 私有代码（保住 PendingCrew 可独立开源定位）。
enum CrewTheme {
    enum Palette {
        static let accent           = Color(hex: 0x044735)
        static let accentBg         = Color(hex: 0xE3EEEA)   // 我的气泡底
        static let userBubble       = accentBg
        static let canvas           = Color(hex: 0xFDFCFA)
        static let surface          = Color(hex: 0xFFFFFF)   // 别人气泡 / 卡片底
        static let surfaceMuted     = Color(hex: 0xEFEEE9)   // chip / roster 底
        static let ink              = Color(hex: 0x1B1A14)
        static let inkMuted         = Color(hex: 0x6E6A5C)   // 名字抬头 / 时间戳
        static let hairline         = Color(hex: 0xE2E0D7)
        static let amber            = Color(hex: 0x6F5A0B)   // 交互卡强调
        static let amberBg          = Color(hex: 0xFAEDC2)
    }

    enum Metrics {
        static let gutter: CGFloat       = 16
        static let bubbleRadius: CGFloat = 18
        static let cardRadius: CGFloat   = 14
        static let avatar: CGFloat       = 30
    }

    enum Fonts {
        static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
        static let body     = system(16)
        static let callout  = system(15)
        static let caption  = system(12)
        static let caption2 = system(11)
    }
}

/// 十六进制 → Color（PendingCrew 本地，避免依赖 PendingBot 的 ColorHex.swift）。
extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
#endif
```

> **先核查**：`Color(hex:)` 在 PendingCrew 里是否已存在（grep `init(hex`）。若已存在，删掉本文件里的 extension 段，只留 `CrewTheme`，避免重复定义编译冲突。

- [ ] **Step 2: 构建**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Design/CrewTheme.swift
git commit -m "feat(pendingcrew): 加 CrewTheme 设计 token(对齐 PendingBot iOS 数值)"
```

---

## Task 4: `CrewColorHash.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Design/CrewColorHash.swift`
- 参照：`apps/pendingbot/Sources/Components/ColorHash.swift`（`hue(for:)` / `softBackground(for:)` / `initial(for:)` / `emoji(for:)`）

- [ ] **Step 1: 创建文件**（把 ColorHash 的算法搬过来，去掉 iOS guard、改成 macOS）

```swift
#if os(macOS)
import SwiftUI

/// id → 稳定的柔色底 + emoji + 首字。算法搬自 PendingBot iOS ColorHash，
/// 保证同一 bot/user 在两端头像配色一致。
enum CrewColorHash {
    static func hue(for seed: String) -> Double {
        var h: UInt64 = 5381
        for b in seed.utf8 { h = ((h << 5) &+ h) &+ UInt64(b) }
        return Double(h % 360)
    }

    static func softBackground(for seed: String) -> Color {
        Color(hue: hue(for: seed) / 360, saturation: 0.30, brightness: 0.94)
    }

    static func initial(for name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "?" : String(t.prefix(1)).uppercased()
    }

    private static let emojis = ["🤖","🦊","🐙","🦉","🐳","🦄","🐝","🦋","🐢","🦓","🐬","🦜","🐧","🦔","🐰","🦒"]
    static func emoji(for seed: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return emojis[Int(h % UInt64(emojis.count))]
    }
}
#endif
```

> **核对**：打开 `apps/pendingbot/Sources/Components/ColorHash.swift`，确认 `hue`/`softBackground`/`emoji` 的常量（saturation/brightness、emoji 池）与上面一致；如 PendingBot 用了不同 saturation/brightness 或 emoji 列表，**以 PendingBot 为准**抄过来（目标是两端视觉一致）。

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Design/CrewColorHash.swift
git commit -m "feat(pendingcrew): 加 CrewColorHash(搬 PendingBot 头像配色算法)"
```

---

## Task 5: `CrewSenderResolver.swift` —— 作者身份解析

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewSenderResolver.swift`

这是消息行渲染的核心：把一条 `CrewWhiteboardEntry` + roster + captainBotId + 本地 userId 解析成统一的 `CrewSender`。

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import Foundation

/// 一条消息的作者解析结果，供 CrewBubbleRow / CrewAvatar 渲染。
struct CrewSender: Equatable {
    enum Kind: Equatable { case bot, session, human }
    let kind: Kind
    let displayName: String
    let avatarSeed: String          // 喂给 CrewColorHash 的稳定 id
    let isCaptain: Bool
    let sessionStatus: String?      // 仅 session：running/queued/…
    let isMine: Bool                // 我自己 → 右对齐、无头像
}

enum CrewSenderResolver {
    /// `entry` 的作者。`localUserId` = 当前登录用户（用于判断"我"）。
    static func resolve(
        _ entry: CrewWhiteboardEntry,
        members: [CrewMember],
        captainBotId: String?,
        localUserId: String?
    ) -> CrewSender {
        switch entry.senderKind {
        case "user", "human":
            let uid = entry.senderUserId
            let mine = uid != nil ? (uid == localUserId) : true   // 缺 id 时 BYOK 单人 → 当我
            let m = members.first { $0.userId != nil && $0.userId == uid }
            return CrewSender(
                kind: .human,
                displayName: m?.displayName ?? "我",
                avatarSeed: uid ?? "me",
                isCaptain: false, sessionStatus: nil, isMine: mine
            )

        case "session":
            let m = members.first { $0.codeSessionId != nil && $0.codeSessionId == entry.senderSessionId }
            let short = entry.senderSessionId.map { "session · \($0.prefix(8))" } ?? "session"
            return CrewSender(
                kind: .session,
                displayName: m?.displayName ?? short,
                avatarSeed: entry.senderSessionId ?? entry.id,
                isCaptain: false, sessionStatus: m?.sessionStatus, isMine: false
            )

        case "bot":
            let bid = entry.senderBotId
            let m = members.first { $0.botId != nil && $0.botId == bid }
                ?? members.first { $0.memberKind == "captain" }   // null 兜底 captain
            let isCaptain = (bid != nil && bid == captainBotId) || m?.memberKind == "captain"
            return CrewSender(
                kind: .bot,
                displayName: m?.displayName ?? (isCaptain ? "机长" : "bot"),
                avatarSeed: bid ?? captainBotId ?? "bot",
                isCaptain: isCaptain, sessionStatus: nil, isMine: false
            )

        default:
            return CrewSender(kind: .bot, displayName: entry.senderKind,
                              avatarSeed: entry.id, isCaptain: false, sessionStatus: nil, isMine: false)
        }
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewSenderResolver.swift
git commit -m "feat(pendingcrew): CrewSenderResolver —— 白板 entry+roster 解析作者身份"
```

---

## Task 6: `CrewAvatar.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewAvatar.swift`

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// 30pt 圆形头像。三种作者：
/// - bot → CrewColorHash 柔色底 + emoji；captain 加星标角标
/// - session → 终端字形(绿系)，可挂运行状态点
/// - human → 柔色底 + 首字
struct CrewAvatar: View {
    let sender: CrewSender
    var size: CGFloat = CrewTheme.Metrics.avatar

    var body: some View {
        ZStack {
            base
            if sender.isCaptain {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.30, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(1.5)
                    .background(Circle().fill(CrewTheme.Palette.surface))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
            if let status = sender.sessionStatus {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().strokeBorder(CrewTheme.Palette.surface, lineWidth: 1.5))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var base: some View {
        switch sender.kind {
        case .bot:
            Circle().fill(CrewColorHash.softBackground(for: sender.avatarSeed))
                .overlay(Text(CrewColorHash.emoji(for: sender.avatarSeed)).font(.system(size: size * 0.55)))
                .overlay(Circle().strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
        case .human:
            Circle().fill(CrewColorHash.softBackground(for: sender.avatarSeed))
                .overlay(Text(CrewColorHash.initial(for: sender.displayName))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(CrewTheme.Palette.ink.opacity(0.8)))
                .overlay(Circle().strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
        case .session:
            Circle().fill(Color(hue: 0.38, saturation: 0.22, brightness: 0.93))
                .overlay(Image(systemName: "terminal.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Color(hue: 0.38, saturation: 0.6, brightness: 0.5)))
                .overlay(Circle().strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "running": return .green
        case "queued":  return .yellow
        default:        return .gray
        }
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewAvatar.swift
git commit -m "feat(pendingcrew): CrewAvatar(bot/session/human 三态头像)"
```

---

## Task 7: `CrewBubbleRow.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewBubbleRow.swift`
- 参照视觉：`apps/pendingbot/Sources/Features/Message/BubbleView.swift`（头像 spacing 8、名字 11 semibold inkMuted、气泡 padding 水平14/垂直10、连续圆角、hairline）

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// 单条白板消息行，对齐 PendingBot iOS BubbleView 语法。
/// 我 → 右对齐绿气泡无头像；别人 → 左对齐头像+名字抬头+surface 气泡。
struct CrewBubbleRow: View {
    let entry: CrewWhiteboardEntry
    let sender: CrewSender

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if sender.isMine {
                Spacer(minLength: 48)
                bubble(mine: true)
            } else {
                CrewAvatar(sender: sender)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sender.displayName)
                        .font(CrewTheme.Fonts.rounded(11, weight: .semibold))
                        .foregroundStyle(CrewTheme.Palette.inkMuted)
                    bubble(mine: false)
                }
                Spacer(minLength: 32)
            }
        }
        .padding(.horizontal, CrewTheme.Metrics.gutter)
        .padding(.vertical, 4)
    }

    private func bubble(mine: Bool) -> some View {
        Text(entry.displayText)
            .font(CrewTheme.Fonts.body)
            .foregroundStyle(CrewTheme.Palette.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CrewTheme.Metrics.bubbleRadius, style: .continuous)
                    .fill(mine ? CrewTheme.Palette.userBubble : CrewTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CrewTheme.Metrics.bubbleRadius, style: .continuous)
                    .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5)
            )
            .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewBubbleRow.swift
git commit -m "feat(pendingcrew): CrewBubbleRow(头像+名字抬头+气泡,对齐 iOS)"
```

---

## Task 8: `CrewTimeSeparator.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewTimeSeparator.swift`
- 参照：`apps/pendingbot/Sources/Components/RelativeMessageTime.swift`（5 分钟阈值、`几秒前/几分钟前/昨天 HH:mm/MM/DD HH:mm`）

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// 居中的相对时间 pill。仅当与上一条间隔 ≥ 5 分钟时插入（由 CrewChatView 决定）。
struct CrewTimeSeparator: View {
    let date: Date

    var body: some View {
        Text(CrewTimeSeparator.label(date))
            .font(CrewTheme.Fonts.caption2)
            .foregroundStyle(CrewTheme.Palette.inkMuted)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
    }

    /// ISO 字符串 → Date（白板 createdAt 是 ISO-8601）。
    static func parse(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// 两条之间是否要插分隔（首条总插）。
    static func needsSeparator(prev: Date?, cur: Date) -> Bool {
        guard let prev else { return true }
        return cur.timeIntervalSince(prev) >= 300
    }

    static func label(_ d: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let secs = now.timeIntervalSince(d)
        if secs < 60 { return "几秒前" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        if cal.isDateInToday(d) { return hm.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 \(hm.string(from: d))" }
        let md = DateFormatter(); md.dateFormat = "MM/dd HH:mm"
        return md.string(from: d)
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewTimeSeparator.swift
git commit -m "feat(pendingcrew): CrewTimeSeparator(5 分钟间隔相对时间 pill)"
```

---

## Task 9: `CrewInteractionCard.swift`（重样 ask_human）

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewInteractionCard.swift`

把 `CrewChatView.interactionCard`（旧 `CrewChatView.swift:143-177`）抽出并按 CrewTheme 重样。回调上提，便于瘦容器接线。

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// ask_human 交互卡（payload.kind == "interaction"）。操作者就地答。
struct CrewInteractionCard: View {
    let entry: CrewWhiteboardEntry
    @Binding var reply: String
    let onAnswer: () -> Void

    private var reqId: String? { entry.payload?.permissionRequestId }
    private var pending: Bool { (entry.payload?.status ?? "pending") == "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent 在问你", systemImage: "person.fill.questionmark")
                .font(CrewTheme.Fonts.caption.weight(.semibold))
                .foregroundStyle(CrewTheme.Palette.amber)
            Text(entry.payload?.question ?? entry.displayText)
                .font(CrewTheme.Fonts.callout)
                .foregroundStyle(CrewTheme.Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if pending, reqId != nil {
                HStack(spacing: 8) {
                    TextField("回答…", text: $reply, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit(onAnswer)
                    Button("回答", action: onAnswer)
                        .buttonStyle(.borderedProminent)
                        .tint(CrewTheme.Palette.accent)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if !pending {
                Text("已回答").font(CrewTheme.Fonts.caption).foregroundStyle(CrewTheme.Palette.inkMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CrewTheme.Metrics.cardRadius, style: .continuous)
            .fill(CrewTheme.Palette.amberBg.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: CrewTheme.Metrics.cardRadius, style: .continuous)
            .strokeBorder(CrewTheme.Palette.amber.opacity(0.30), lineWidth: 0.5))
        .padding(.horizontal, CrewTheme.Metrics.gutter)
        .padding(.vertical, 4)
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewInteractionCard.swift
git commit -m "feat(pendingcrew): CrewInteractionCard(ask_human 卡片重样)"
```

---

## Task 10: `CrewComposer.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewComposer.swift`
- 参照：`apps/pendingbot/Sources/Features/Message/ComposerView.swift`（胶囊 TextField + 圆形发送钮）。crew 无附件 → 省 `+`。

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// 中栏底部输入条：胶囊 TextField + 圆形发送钮。对齐 PendingBot iOS Composer。
struct CrewComposer: View {
    @Binding var draft: String
    let sending: Bool
    let errorText: String?
    let onSend: () -> Void

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            if let errorText {
                Text(errorText).font(CrewTheme.Fonts.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("发消息…（不 @ = 广播给所有 session）", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CrewTheme.Fonts.body)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(CrewTheme.Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
                    .onSubmit(onSend)

                Button(action: onSend) {
                    ZStack {
                        Circle().fill(canSend ? CrewTheme.Palette.accent : CrewTheme.Palette.surfaceMuted)
                            .frame(width: 30, height: 30)
                        if sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canSend ? .white : CrewTheme.Palette.inkMuted)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(CrewTheme.Palette.canvas)
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewComposer.swift
git commit -m "feat(pendingcrew): CrewComposer(胶囊输入+圆形发送钮)"
```

---

## Task 11: `CrewRosterBar.swift`

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/Views/Chat/CrewRosterBar.swift`

用 `CrewAvatar` 重画 roster 头像条。`CrewMember` → `CrewSender` 映射（成员本身就是身份源）。

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI

/// 顶部 roster 头像条：一排成员头像（session 带状态点），保留 crew 特有的
/// "一眼看 captain/session 运行状态" 价值，视觉对齐 iOS。
struct CrewRosterBar: View {
    let members: [CrewMember]
    let captainBotId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(members) { m in
                    let sender = senderFor(m)
                    VStack(spacing: 3) {
                        CrewAvatar(sender: sender, size: 28)
                        Text(sender.displayName)
                            .font(CrewTheme.Fonts.caption2)
                            .foregroundStyle(CrewTheme.Palette.inkMuted)
                            .lineLimit(1)
                            .frame(maxWidth: 76)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(CrewTheme.Palette.surfaceMuted.opacity(0.5))
    }

    private func senderFor(_ m: CrewMember) -> CrewSender {
        let isCaptain = m.memberKind == "captain" || (m.botId != nil && m.botId == captainBotId)
        let kind: CrewSender.Kind = {
            switch m.memberKind {
            case "code_session": return .session
            case "human":        return .human
            default:             return .bot   // bot / captain
            }
        }()
        let seed = m.botId ?? m.userId ?? m.codeSessionId ?? m.id
        let name = m.displayName?.isEmpty == false ? m.displayName!
            : (isCaptain ? "机长" : kind == .human ? "我" : kind == .session ? "session" : "bot")
        return CrewSender(kind: kind, displayName: name, avatarSeed: seed,
                          isCaptain: isCaptain, sessionStatus: m.sessionStatus, isMine: false)
    }
}
#endif
```

- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/Chat/CrewRosterBar.swift
git commit -m "feat(pendingcrew): CrewRosterBar(用 CrewAvatar 重画成员条)"
```

---

## Task 12: 重构 `CrewChatView` 成瘦容器

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`（整体重写 body + 渲染部分，data 部分保留）

把 timeline / roster / composer / 卡片渲染全部委托给新组件；timeline 插入时间分隔；接 `localUserId`（从 `appModel`）做身份解析。

- [ ] **Step 1: 重写 View**

保留现有 `@State` 与 data 方法（`pollLoop` / `refresh` / `send` / `answer`，`CrewChatView.swift:220-274`）不动；删掉旧的 `rosterBar` / `memberChip` / `memberLabel` / `timeline` / `row` / `messageBubble` / `interactionCard` / `senderLabel`（`:44-285`），换成：

```swift
    var body: some View {
        VStack(spacing: 0) {
            if !members.isEmpty {
                CrewRosterBar(members: members, captainBotId: captainBotId)
                Divider()
            }
            timeline
            Divider()
            CrewComposer(draft: $draft, sending: sending, errorText: loadError) {
                Task { await send() }
            }
        }
        .background(CrewTheme.Palette.canvas)
        .task(id: crewId) { await pollLoop() }
    }

    private var localUserId: String? { appModel.currentUserId }   // 见 Step 2 注

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty { emptyState }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        let prevDate = idx > 0 ? CrewTimeSeparator.parse(entries[idx - 1].createdAt) : nil
                        if let cur = CrewTimeSeparator.parse(entry.createdAt),
                           CrewTimeSeparator.needsSeparator(prev: prevDate, cur: cur) {
                            CrewTimeSeparator(date: cur)
                        }
                        rowView(entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: entries.count) { _, _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ entry: CrewWhiteboardEntry) -> some View {
        if entry.isInteraction {
            let reqId = entry.payload?.permissionRequestId ?? entry.id
            CrewInteractionCard(
                entry: entry,
                reply: Binding(get: { replyDrafts[reqId] ?? "" }, set: { replyDrafts[reqId] = $0 })
            ) { Task { await answer(reqId) } }
        } else {
            let sender = CrewSenderResolver.resolve(entry, members: members,
                                                    captainBotId: captainBotId, localUserId: localUserId)
            CrewBubbleRow(entry: entry, sender: sender)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("群聊白板 —— 在这里给 session 留指令、看关键节点。\n@session 发给某个 session，不 @ 则广播给全部。")
                .font(CrewTheme.Fonts.callout).foregroundStyle(CrewTheme.Palette.inkMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
```

- [ ] **Step 2: 确认 `appModel.currentUserId` 存在**

`localUserId` 依赖 `AppModel` 暴露当前登录用户 id。**先核查** `apps/pendingcrew/Sources/Stores/AppModel.swift`：
- 若已有 `currentUserId`（或等价，如 `session?.userId`）→ 用它，必要时改 `localUserId` 的取值表达式。
- 若没有 → 退化为 `private var localUserId: String? { nil }`，此时 user 作者全部按"我/BYOK 单人"右对齐（与改造前行为一致），并在本任务 commit body 注明、在 Task 13 记一条 tech-debt（多人群里区分人类成员待 AppModel 暴露 userId）。

- [ ] **Step 3: 构建**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift
git commit -m "refactor(pendingcrew): CrewChatView 重构成组合新群聊组件的瘦容器"
```

---

## Task 13: 端到端验证 + 账本

**Files:**
- 验证产物（截图）+ `docs/progress.md` + 视情况 `docs/tech-debt.md`

- [ ] **Step 1: 构建并启动**

```bash
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -3
open /tmp/pendingcrew-dd/Build/Products/Debug/PendingCrew.app
```

- [ ] **Step 2: 真用核对（不只编译过）**

进一个有 captain + session + 多条消息的 crew，肉眼核对（对照 PendingBot iOS 群聊）：
- 别人消息：左对齐、头像（bot emoji / session 终端 / human 首字）、名字抬头、surface 气泡 + hairline；captain 带星标；session 带运行状态点。
- 我的消息：右对齐、绿气泡、无头像。
- 间隔 ≥5 分钟出现时间分隔 pill。
- roster 条头像化、session 状态点正确。
- ask_human 卡片新样式可答、答后变"已回答"。
- composer 胶囊 + 圆形发送钮、空时禁用。

截图留档（`SendUserFile` 发给用户确认）。若发现具体视觉偏差，回到对应 Task 的文件修正再提交。

- [ ] **Step 3: 账本**

- 更新 `docs/progress.md` 顶部"最近对账"日期 + 一行本次（PendingCrew 中栏群聊对齐 iOS）。
- 若 Task 12 Step 2 退化（AppModel 无 userId）→ `docs/tech-debt.md` 加 🟡 一条。
- Commit：

```bash
git add docs/progress.md docs/tech-debt.md
git commit -m "docs: PendingCrew 群聊 UI 对齐对账 + tech-debt(若有)"
```

---

## Self-Review

**Spec coverage：**
- §2.1 edge 透出 sender 身份 → Task 1 ✅
- §3 设计 token → Task 3 ✅
- §4 消息行(三态头像/气泡/名字抬头/身份解析+fallback) → Task 4/5/6/7 ✅
- §5 时间分隔 → Task 8；ask_human 卡 → Task 9；composer → Task 10；roster 保留重样 → Task 11 ✅
- §6 瘦容器组合 → Task 12 ✅
- §7 验证 → Task 13 ✅
- §8 tech-debt 尾巴 → Task 12 Step 2 / Task 13 Step 3 ✅

**类型一致性：** `CrewSender`(Task 5) 的字段 `kind/displayName/avatarSeed/isCaptain/sessionStatus/isMine` 在 Task 6/7/11 一致使用；`CrewColorHash.softBackground/emoji/initial`(Task 4) 在 Task 6 一致；edge `mapMessageToEntry` 新字段 `sender_user_id/sender_bot_id/sender_session_id`(Task 1) 与 iOS `senderUserId/senderBotId/senderSessionId`(Task 2) 经 CodingKeys 对应。

**核查点（实施时先验证再写，已在对应 Task 标注）：** ① `Color(hex:)` 是否已存在(Task 3)；② ColorHash 常量与 PendingBot 一致(Task 4)；③ `AppModel.currentUserId` 是否存在(Task 12)。
