# 模型盲盒(Model Blind Box)— 设计文档

> 状态:设计已与用户确认,待评审 → 转 writing-plans
> 分支:`feat/model-blindbox`
> 日期:2026-06-14

## 1. 背景与目标

现有 arena 功能是 **LMArena 式的模型评价框架**:随机抽模型 + A/B 盲投对比 + Bradley-Terry 个人排行榜。
用户要把它**从"评价"转向"娱乐"** —— 做成**开盲盒**体验:模型随机、藏起真名、让用户**猜**,主打趣味与随机性,而非评测。

核心诉求:

1. 猜中之前,模型名显示 **`PendingModel`**。
2. 输入框 `+` 菜单出**「猜模型」**入口:选一个模型猜 → 揭晓真实模型(对/错)。选项里含**「不想猜(直接揭晓)」**。
3. 对话中**模型可调 tool** 弹出"猜模型" UI。
4. `+` 菜单也提供**直接换当前会话指定模型**的入口。
5. Bot 设置里可选**「保留惊喜」/「直接披露」**:披露模式下不让猜,直接显示真名。

非目标(本期明确不做):模型图鉴/收藏册、全局排行榜、跨会话统计。纯娱乐。

## 2. 核心状态机(关键约束:缓存友好)

**硬约束**:prompt caching 要求会话内模型稳定,否则缓存全不命中、账单爆炸。因此**会话当前模型一旦抽定就固定,逐轮复用**。

- `conversations.current_model_slug` 抽定后**持续整个会话**,普通往返**永不**换。
- **只有两件事会重抽新模型**:
  1. **手动重新生成**(且 bot 设置 `regenReroll=true`,默认开)
  2. **手动换模型**(随机重抽 / 选具体模型)
- **猜 / 揭示的对象 = 会话当前模型**(单个,非单条气泡)。模型名以**会话级单一指示**呈现(一个 pill),未揭示显示 `PendingModel`,揭示后显示真名 —— 天然就是"整个会话"。
- 重抽(regen/换随机)→ 新模型 → reveal 状态**重置** → pill 变回 `PendingModel`,需重新猜。
- 手动选**具体**模型 → 直接算**已揭示**(自己选的,不必猜)。
- UI 只认"当前模型"这一个 pill;不画逐气泡模型徽标,因此不存在"停住没猜的旧气泡"问题。历史归属仍由 `messages.model_slug` 如实记录(供持久猜测记录)。

### 显示判定(单一真值)

```
当前模型显示名 =
  model_revealed == true  → 友好名(从模型目录解析)
  否则                    → "PendingModel"
```

`model_revealed` 是 `conversations` 上的布尔列,随重抽重置。

## 3. 数据模型

### 3.1 `conversations` 新增列

- `model_revealed boolean NOT NULL DEFAULT false` —— 当前模型是否已揭示。
  - 抽随机模型(新建会话 / regen 重抽 / 手动换随机)时置 `false`。
  - 揭示(猜 / 不想猜)或手动选具体模型时置 `true`。

`current_model_slug` / `current_model_provider` / `random_model_config` 沿用现有(随机池配置不动)。

### 3.2 新表 `model_guesses`(持久猜测记录)

```sql
create table pendingbot.model_guesses (
  id            uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  actual_slug   text not null,          -- 揭晓时的真实模型 slug
  actual_provider text,
  guessed_slug  text,                    -- 用户猜的;不想猜=NULL
  correct       boolean,                 -- guessed_slug == actual_slug;不想猜=NULL
  created_at    timestamptz not null default now()
);
-- RLS:仅本人可读写自己的记录
```

用途:重载后气泡/卡片仍能显示「✓ 你猜对了」/「✗ 你猜的是 X,实际是 Y」/「(放弃)实际是 Y」。一次揭示一条记录(对应一个被揭示的当前模型 stint)。

### 3.3 Bot 配置(`bots.config`)新增

在现有 `config`(jsonb)下加一个 `blindBox` 段:

```jsonc
{
  "blindBox": {
    "revealMode": "surprise" | "disclose",  // 默认 "surprise":藏名让猜;"disclose":直接显示真名,不让猜
    "regenReroll": true                       // 默认 true:手动 regen 重抽新模型;false:regen 保持当前模型
  }
}
```

- `revealMode="disclose"`:`model_revealed` 视为恒 true,`+` 菜单不出「猜模型」,pill 直接显示真名。
- `regenReroll` 仅影响**手动重新生成**是否重抽(独立于"手动换模型",后者总是换)。

### 3.4 删除(旧评价框架连根拔)

- 表 `model_comparisons` —— DROP(新迁移)。
- 列:无需保留 arena 投票相关列(`model_comparisons` 独立表)。

## 4. 后端(apps/edge)

### 4.1 删除

- 路由 `apps/edge/src/routes/arena.ts`(`POST /v1/arena/compare`、`GET /v1/arena/leaderboard`)。
- `apps/edge/src/lib/arena-bradley-terry.ts` + 测试。
- `apps/edge/src/routes/arena-switch.test.ts`(投票切模型逻辑)。
- 路由注册处去挂载。

### 4.2 保留

- `apps/edge/src/llm/random-model.ts`(随机池 resolver)—— 盲盒内核,保留。
- `apps/edge/src/lib/conversation-model.ts`(`chooseConversationMainModel`)—— 保留;`chooseCandidateModel`(原为 A/B 候选)按需简化或删除(regen 重抽改走主模型重选 + 置 `model_revealed=false`)。

### 4.3 新端点

**`POST /v1/conversations/:id/reveal-model`** —— 猜 / 揭晓当前模型。

```
Body: { guess?: string | null }   // model_slug;不想猜=null/缺省
Resp: {
  actual_slug: string,
  actual_provider: string | null,
  correct: boolean | null         // guess 缺省 → null
}
```

行为:
1. 鉴权 + 取会话当前 `current_model_slug/provider`。
2. `disclose` 模式或已 revealed → 直接回真名(幂等)。
3. 置 `conversations.model_revealed=true`。
4. 插入一条 `model_guesses` 记录(actual / guessed / correct)。
5. 返回真名 + 对错。

**手动换模型**:沿用现有"切会话模型"通道(ModelPicker 已有的 PATCH 路径)。扩展语义:
- 换成**随机**(从池重抽)→ 置 `model_revealed=false`。
- 换成**具体**模型 → 置 `model_revealed=true`(自己选的,已知)。

**regen 重抽**:重新生成端点里,依据 bot `blindBox.regenReroll`:
- `true` → 重新 `pickRandomModel`(排除当前)→ 写 `current_model_slug` + `model_revealed=false`。
- `false` → 保持 `current_model_slug` 不变。

### 4.4 新 Tool:`prompt_model_guess`

让 LLM 在对话中主动弹"猜一猜"。机制走**特殊消息行**(与 `send_images` 终端效应一致,**不是**临时 SSE):

- `tool-defs.ts` 加声明 `prompt_model_guess`(无参或仅可选 `hint` 文案)。
- `tool-runner.ts` 加分支:调用时通过 `ToolCtx` 插入一条 `kind='guess_prompt'` 的 bot 消息行(类比 `emitImagesMessage`),不回 `tool_result` 文本。
- `tools-registry.ts` 注册(board 可 kill-switch)。
- 客户端见到 `kind='guess_prompt'` 消息 → 渲染可交互"猜一猜"卡片。
- 卡片被作答后,落 `model_guesses` + 置 `model_revealed=true`(复用 4.3 端点)。卡片状态持久(消息行进历史/Realtime)。

> `disclose` 模式下该 tool 应被禁用/无视(prompt 里说明 + 服务端兜底:已 revealed 时插入的卡片直接呈"已揭晓")。

## 5. 客户端(apps/pendingbot,iOS/iPad/macOS SwiftUI)

### 5.1 模型 pill(会话级单一指示)

- 现有 `ModelPickerButton` 改造:`model_revealed=false && surprise` → 显示「PendingModel」(配个盲盒图标);否则显示友好名。
- 点 pill 仍可进换模型(保留),但主"猜"入口在 `+` 菜单(下条)。

### 5.2 `+` 菜单两个入口

复用输入框现有 `+`(附件/更多)菜单(`ChatComposerAccessory` / `ChatActionSheet`),加两项:

- **「猜模型」**(仅 `surprise` 且未揭示时出现)→ 打开猜模型 sheet。
- **「换模型」**→ 打开换模型 sheet(随机重抽 / 选具体模型),即现有 ModelPicker 能力。

### 5.3 猜模型 sheet

- 复用 `ModelPicker` 的列表(从池/目录选一个)。
- 顶部/底部一个**「不想猜(直接揭晓)」**按钮。
- 选定 → 调 `POST /v1/conversations/:id/reveal-model`。
- 回来后:展示结果「✓ 猜对了!就是 X」/「✗ 你猜的是 X,实际是 Y」/「(揭晓)实际是 Y」,pill 翻成真名。
- 结果持久(来自 `model_guesses`):重进会话仍可见最近一次猜测结论。

### 5.4 tool 弹出的"猜一猜"卡片

- 时间线渲染 `kind='guess_prompt'` 消息为可交互卡片(类似 BubbleView 旁的特殊行)。
- 作答路径同 5.3(同一端点)。作答后卡片定格为结果态。

### 5.5 Bot 设置

`BotManagement.swift`(创建/编辑 bot)`blindBox` 段加两个开关:

- **保留惊喜 / 直接披露**(`revealMode`)。
- **regen 时重抽 / 保持当前**(`regenReroll`)。

随机池编辑器(`ArenaModelPoolEditor`)沿用 —— 它是盲盒内核(决定盒里有哪些模型)。可顺手把面向用户的 "arena/盲评" 文案改成"盲盒"。

### 5.6 删除(客户端)

- `MeTabView` 排行榜区(`GET /v1/arena/leaderboard` 调用 + 渲染)。
- `ConversationView` 的 A/B 盲投对比 UI(`/v1/arena/compare`)。
- `APIModels.swift` 的 `ArenaStanding` / `ArenaLeaderboard` / `ArenaCompareResult`。
- `ModelPicker.swift` 里 `ArenaModelSelection` 等可保留(池编辑),仅去掉对比/投票相关。

## 6. 命名

- 用户可见文案:**盲盒 / PendingModel / 猜模型**。
- 内部:`modelPool` 中性名沿用不改;`arena.ts` 路由删除;不强制重命名所有内部 `arena` 标识符(避免无谓 churn),但删掉对比/排行榜相关。新端点/列用 `reveal` / `guess` / `blindBox` 命名。

## 7. 影响面清单

| 层 | 改动 |
|---|---|
| 迁移 | +`model_revealed` 列;+`model_guesses` 表(RLS);DROP `model_comparisons` |
| schema.ts | regen |
| edge 删 | `arena.ts`、`arena-bradley-terry.ts`(+test)、`arena-switch.test.ts` |
| edge 改 | `conversation-model.ts`(regen 重抽+reveal 重置)、bots 配置接受 `blindBox`、换模型端点置 reveal |
| edge 加 | `POST /v1/conversations/:id/reveal-model`、tool `prompt_model_guess`(tool-defs/runner/registry) |
| iOS 删 | leaderboard(MeTab)、A/B 投票(ConversationView)、Arena* structs |
| iOS 改 | model pill(PendingModel)、`+` 菜单两入口、bot 设置两开关、池编辑器文案 |
| iOS 加 | 猜模型 sheet、`guess_prompt` 卡片渲染、reveal API client、`model_guesses` 解码 |

## 8. 验证

- 迁移:`supabase db push` → `types:db` regen → edge typecheck。
- edge:`vitest run`(新增 reveal 端点 + regen 重抽 + reveal 重置用例;删 arena 测试)。
- iOS/iPad/macOS:`xcodebuild` 三目标 build;模拟器/真机冒烟:抽模型→PendingModel→猜对/猜错/不想猜→regen 重抽变回 PendingModel→换具体模型直接真名→disclose 模式不出"猜模型"。

## 9. 待确认/已确认决策

- [x] 旧 A/B 对比 + 排行榜 **全删**,纯娱乐。
- [x] 揭示作用域 = **整个会话**(会话级单一当前模型)。
- [x] 会话模型**抽定即固定**(缓存友好);仅 regen/手动换重抽。
- [x] regen **默认重抽**,可 bot 设置 `regenReroll` 关。
- [x] tool→猜模型 UI 走**特殊消息行**(`guess_prompt`),持久。
- [x] 入口在**输入框 `+` 菜单**。
- [x] 猜测结果**持久化**(`model_guesses` 表)。
