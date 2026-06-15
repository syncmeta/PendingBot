# 新建机器人 —— 一页式 + 模型预设 设计

状态：已与用户确认，待写 implementation plan
日期：2026-06-15
分支：`feat/create-bot-presets`

## 背景与问题

当前"新建机器人"是**两步式 sheet**（`apps/pendingbot/Sources/Features/Friends/BotManagement.swift` 的 `CreateBotSheet`）：

1. Step 1 `.models` —— `ArenaModelPoolEditor`（`ModelPicker.swift`）选模型池。进页时同步 `GET /v1/models` 拉全量 catalog（1–2MB），无客户端持久缓存，且与 `ModelCatalog` 各拉一遍；落地后在主线程对几百个模型排序 → **"等好几秒"的根因**。
2. Step 2 `.settings` —— 名字（Lorem token 默认）、公开程度（默认私有）、公有 slug。

用户要的新流程：

- 第一屏给几个**模型预设**（多选，默认勾前三），点进去能看每个预设包含哪些模型；预设在 **board** 里管理。
- 一个**自定义**入口：在已选预设基础上进入现有选模型页手动增删/筛选。
- 名字从**全世界地名**里选（权威数据），随机默认 + "换一个"。
- **公开程度第一屏就选**，不要"下一步"——一页内即可建好。

## 目标 / 非目标

**目标**
- create-bot 收敛为**单页** Form：名字 + 预设多选 + 自定义入口 + 公开程度 + 创建。
- 引入 board 管理的**模型预设**系统，内容由 OpenRouter API 驱动。
- bot **存预设引用**，对话时解析（预设在 board 改了，已建 bot 自动跟随）。
- 名字默认走 GeoNames 世界地名 + reshuffle。
- 消除模型列表"等好几秒"。

**非目标**
- 不做"性价比"预设（用户明确"先不要"）。
- 不改盲盒/arena 选模型与揭示机制本身（只把"池来源"换成预设引用）。
- 不引入新计费/可见性档位。

## 决策记录（用户已拍板）

| 决策点 | 结论 |
|---|---|
| 预设内容怎么定义 | 用 **OpenRouter API** 动态解析；board 管"定义/规则"。去掉"性价比"，加"最热门"。预设集 = 头两家旗舰 / 中国旗舰 / 各家最新 / 速度快 / 最热门 |
| "头两家"是哪两家 | 固定 **OpenAI + Anthropic**（board 可改） |
| 旗舰怎么自动选 | 每厂一个，策略默认"最贵"（`blended_usd_per_million` 最高），可切"最新"/"某系列最新"。**5 个预设全规则驱动，无手钉** |
| bot 标识 | **vanity slug 彻底退役**。bot = 显示名（可改、不唯一）+ 自动 id（唯一、不可改、链接用），与人类账号一致。创建/管理都不让用户碰 slug |
| 默认公开程度 | 改回 **默认私有**（规避公有永久不可逆的坑） |
| 公有 bot 删除 | 放宽：公有 bot 若**只有创建者一人是好友**（无其他采用者）仍可删 |
| 预设如何落到 bot | **存预设引用，对话时解析** |
| 名字交互 | **随机默认 + "换一个"按钮**，仍可手改 |
| 自定义语义 | 点自定义 = 拿所选预设并集作起点 → 进选模型页手改 → bot 改存**显式** `modelPool`（冻结快照 + 筛选），**不再跟预设联动**。一个 bot 要么"预设驱动（活）"、要么"自定义（冻结）"，二选一 |

## OpenRouter API 可行性（已核实官方文档）

`GET https://openrouter.ai/api/v1/models` 接受 sort/filter 参数：
- sort：`throughput-high-to-low`（→速度快）、`most-popular` / `top-weekly`（→最热门）、`newest`（→各家最新）、`pricing-*`、`context-high-to-low`、`latency-low-to-high`
- filter：`model_authors`、`providers`、`min_price` / `max_price`、`category`、`input/output_modalities`、`context`

Datasets/rankings API（`/docs/api/api-reference/datasets/get-rankings-daily`，用 OR key 鉴权）给"每日 top-50 按 token 用量"——最热门的更干净来源。

边端已有从 OpenRouter 派生 catalog 的逻辑（`apps/edge/src/routes/models.ts`，`/v1/models` 走 1h 边缘缓存 + LMArena 6h KV）。预设解析复用同一上游。

## 设计

### 1. 模型预设系统

**新表 `pendingbot.model_presets`**（board 管理，复用 `boardResource()`）：

| 列 | 类型 | 说明 |
|---|---|---|
| `slug` | text PK | `top-flagship` / `cn-flagship` / `latest-per-vendor` / `fastest` / `most-popular` |
| `title` | text | 中文展示名（"头两家旗舰"…） |
| `description` | text | 一句话说明 |
| `resolver_kind` | text | `top_flagship` / `chinese_flagship` / `latest_per_vendor` / `fastest` / `most_popular` / `manual` |
| `params` | jsonb | 解析参数：`{ count, authors[], manual_models[] }` 等 |
| `default_selected` | bool | 默认是否勾选（前三个为 true） |
| `enabled` | bool | 开关 |
| `sort_order` | int | 排序 |
| `updated_at` / `updated_by` | | 审计 |

`resolver_kind` → OpenRouter 查询映射（**全部规则驱动，无需手钉清单**）：

- `top_flagship` —— 厂商列表固定 `[openai, anthropic]`（`params.authors` 可改），各厂按"旗舰策略"取一个
- `chinese_flagship` —— `params.authors` = 中国厂白名单（默认 `[deepseek, qwen, moonshotai, z-ai, minimax, ...]`），各厂按"旗舰策略"取一个
- `latest_per_vendor` —— `order=newest`，按 author 分组各取最新一个，限 `params.count`（默认 8）
- `fastest` —— `order=throughput-high-to-low`，取前 `params.count`（默认 5）
- `most_popular` —— Datasets 用量榜 或 `order=most-popular`，取前 `params.count`（默认 5）
- `manual` —— 直接用 `params.manual_models`（纯应急口，正常不用）

**旗舰策略**（`top_flagship` / `chinese_flagship` 的 `params.flagship`，每厂取一个）：
- `most_expensive`（默认）—— 厂内 `blended_usd_per_million` 最高的
- `latest` —— 厂内 `release_date` 最新的
- `latest_in_series` —— 按 slug 模式（如 `claude-opus-*`、`gpt-5*`）取最新——支持"某系列的 latest"

**原生优先**：`top_flagship` 解析到 OpenAI/Anthropic 时取**原生 twin 行**（`deriveNative` 已给原生行带上同样的 `blended_usd_per_million` + `release_date` + `model_provider`，见 `models.ts:255`），走统一计费原生路由。中国厂无原生 twin，走 OpenRouter 透传。

**边端解析器** `resolveModelPreset(slug) -> ModelRef[]`：
- 调 OpenRouter（按 `resolver_kind`/`params`）→ 与边端 catalog 对齐成 `{ slug, display_name, provider }`。
- 结果缓存进 KV（建议 6h TTL；可后台/cron 刷新）。供 iOS 展示 + 对话时解析共用。
- "旗舰"判定先用简单启发式（同厂 most-popular 或最新非廉价档），细节留给 plan；board 的 `manual_models` 兜底。

**新端点 `GET /v1/model-presets`**：返回启用预设
```jsonc
[{ "slug": "...", "title": "...", "description": "...", "default_selected": true,
   "models": [{ "slug": "...", "display_name": "...", "provider": "..." }] }]
```
载荷只有 5 个预设、几十个模型名 → **第一屏秒开**（不再首拉全量 catalog）。常驻 KV 缓存。

**board 前端**（`apps/admin/`，4 步模式）：`board.ts` 加 `boardResource({ table: 'model_presets', ... })` + `resource-map.ts` / `App.tsx` / 新建 `pages/model-presets.tsx`（list/create/edit；`resolver_kind` 下拉 + `params` JSON 编辑器）。审计自动走 `admin_audit`。

### 2. Bot 绑定（存引用，对话时解析）

bot `config.modelPool`（现 `RandomModelConfig`：`price_min/max`、`models[]`、`exclude[]`、`vendors[]`、`release_window_days`）**新增** `presets?: string[]`（选中预设 slug）。

- **预设驱动 bot**：`modelPool.presets = [选中 slug]`；`models/exclude/vendors/...` 留空。`model_id`(NOT NULL) 存一个 fallback（创建时取首个解析模型）。
- **自定义 bot**：`modelPool.presets` 留空，写显式 `models/exclude/vendors/price/release`（冻结）。

**对话时解析**（扩展现有"随机模型 resolver" `apps/edge/src/llm/router.ts` / 盲盒 conversation-model helpers）：
```
pool = ∅
for slug in modelPool.presets: pool ∪= resolveModelPreset(slug)   // 走 KV 缓存
pool ∪= modelPool.models
pool -= modelPool.exclude
应用 vendors/price/release 过滤
若 pool 为空 → fallback 到 bots.model_id
盲盒/arena 从 pool 选一个
```

### 3. 公开程度 + 删除放宽

- 第一页内联公开程度，**默认私有**（`Visibility = .privateBot`）。**不再有 slug 字段**——公私有都自动生成 `bots.slug`（私有沿用 `u_<随机>`；公有用同类自动随机串，格式细节留 plan），用户全程不碰。
- **vanity slug 退役**：删 `CreateBotSheet` 自选 slug（#123）、`ManageBotSheet` slug 编辑（#124）；分享区只展示不可改。`BotSlugRule` 校验从 create/manage 路径移除（如别处无引用则删）。显示名不要求唯一。分享/深链（`/b/<slug>`、QR、universal link #121-128）照常用自动 slug，不受影响。
- **迁移**放宽公有删除：改 `bots_creator_delete` 策略 + `bots_guard_public_update` 触发器，判据从 `visibility = 'private'` 改为 `visibility = 'private' OR 无外部采用者`。"无外部采用者" = 除创建者外，无其他 `user_bot_contacts` 行、无 `bot_invites`/`bot_invite_links` 兑换。
  - 注意：RLS DELETE 策略 + 触发器双闸都要放。删除判据用子查询，留意性能（这些表有 bot_id 索引即可）。

### 4. 名字 —— GeoNames 世界地名

- 复用 GeoNames `cities15000`（CC BY 4.0，仓库已有 `apps/pendingcrew/Resources/crewground_places.txt`）。
- 生成一份**展示友好**（保留空格：`Casablanca`、`Buenos Aires`，非拼接形）的 `.txt` 打进 **PendingBot** iOS bundle（新资源，独立于 crewground 的拼接版）。
- 新 `enum PlaceNames`（iOS）读 bundle；`CreateBotSheet` 默认随机取一个、"换一个"按钮 reshuffle、可手改。替换现 `loremTokens` + `seedDefaultName`。
- 轻量去重：默认 pick 时避开创建者已用名（沿用现思路，但 32K 名几乎不撞）。

### 5. 性能修复

- iOS 给 `/v1/models` 加**磁盘持久缓存**（ETag/Last-Modified 重验）：进"自定义"页先显缓存、后台刷新。`ModelCatalog` 收为单一来源，`ArenaModelPoolEditor` 不再独立拉取。
- 模型排序挪出主线程（或惰性/分页渲染）。
- 边端 `/v1/model-presets` 常驻 KV 缓存，保证第一屏稳定快。
- 结构性收益：预设页只载轻量 `/v1/model-presets`，全量 catalog 仅在点"自定义"时懒加载。

### 6. iOS 一页式 `CreateBotSheet` 重构

单页 Form（取消两步 `Step` 枚举与"下一步"）：

1. **名字** —— TextField + "换一个"(dice) 按钮。
2. **模型预设 · 可多选** —— `GET /v1/model-presets` 渲染行：勾选框 + 标题 + 副标题（前几个模型名）+ chevron。点行展开/进二级看完整模型清单。默认勾 `default_selected` 的（前三）。
3. **自定义模型池** —— 一行入口，点开 `ArenaModelPoolEditor`，**用当前所选预设并集 seed**。确认后 bot 转**显式** `modelPool`，主页面摘要显示"自定义 · N 个模型"，预设勾选转为"起点"不再联动。
4. **公开程度** —— 私有(默认)/公有·邀请制 radio。**无 slug 字段。**
5. **创建** —— 顶部右上角；校验：名字非空 + (有选中预设 或 有自定义池)。slug 自动，不进校验。

创建写库：`bots` insert（`model_id` fallback、`config.modelPool.presets` 或显式池、`visibility`、自动 `slug`、`tz`）+ `user_bot_contacts`（沿用现逻辑）。

## 受影响文件（首盘点，plan 细化）

**Edge**
- `supabase/migrations/<ts>_model_presets.sql` —— 新表 + seed 5 个预设
- `supabase/migrations/<ts>_relax_public_bot_delete.sql` —— 删除策略 + 触发器放宽
- `apps/edge/src/db/schema.ts` —— regen
- `apps/edge/src/routes/board.ts` —— `model_presets` boardResource + Zod
- `apps/edge/src/routes/models.ts` 或新 `model-presets.ts` —— `GET /v1/model-presets` + `resolveModelPreset`
- `apps/edge/src/llm/router.ts` + 盲盒 conversation-model helpers —— 池解析展开 presets
- `apps/edge/wrangler.jsonc` / `types.ts` —— 若需 OpenRouter key / 新 KV 命名空间

**Board (`apps/admin/`)**
- `providers/resource-map.ts`、`App.tsx`、`pages/model-presets.tsx`

**iOS (`apps/pendingbot/`)**
- `Features/Friends/BotManagement.swift` —— `CreateBotSheet` 单页重构 + 删自选 slug（含 `BotSlugRule` 引用）
- `ManageBotSheet`（slug 编辑退役，分享区只读，#124 反向）
- `Features/Friends/ModelPicker.swift` —— `ArenaModelPoolEditor` 接受 preset seed；catalog 缓存收口
- 新 `Storage/ModelCatalog.swift` 磁盘缓存（ETag）
- 新 `Stores/PlaceNames.swift` + bundle `Resources/place_names.txt`
- `Models/APIModels.swift` —— `RandomModelConfig` 加 `presets`；新 `ModelPreset` 解码
- 新 `ModelPresetsAPI`（`GET /v1/model-presets`）
- `project.yml` —— 新资源进 bundle，跑 xcodegen

## 测试

- Edge vitest：`resolveModelPreset` 各 `resolver_kind`（mock OpenRouter）；`/v1/model-presets` 缓存；池解析展开 presets；board CRUD + 审计；放宽后的删除策略（有/无外部采用者）。
- iOS：build（iOS + iPad），模拟器实测建私有 + 建公有 + 自定义路径 + "换一个"；catalog 缓存命中。
- 迁移：`db push` → `types:db` regen → edge typecheck。

## 已知尾巴 / tech-debt 候选

- 旗舰策略默认"最贵"，但 `blended_usd_per_million` 是混合成本估算（缓存 0.7/输入 0.2/输出 0.1，`models.ts:122`），不完全等于"档位"，偶尔可能把 pro/ultra 排得不直观。遇到就把该预设切 `latest_in_series`。
- OpenRouter 厂商 author slug（尤其中国厂 deepseek/qwen/moonshotai/z-ai/minimax）+ 各厂旗舰在不在 OpenRouter、能否走统一计费，需拉实时目录核对，别凭印象（按 `feedback_official_docs_for_integrations`）。上线前核掉。
- 预设解析的 KV 刷新若用 cron，需单独排期；初期可被动 TTL。
- 放宽删除的子查询性能在 bot 采用者很多时需关注（但能删的前提就是采用者≤1，集合天然小）。
