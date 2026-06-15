# 新建机器人 — 一页式 + 模型预设 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"新建机器人"收敛成单页（名字 + 模型预设多选 + 自定义入口 + 公开程度），预设由 board 管理定义、OpenRouter 目录动态解析，bot 存预设引用对话时解析；名字走 GeoNames 世界地名；退役用户自选 slug。

**Architecture:** 新表 `model_presets`（board CRUD）存预设"规则"，边端 `model-presets.ts` 解析器按 `resolver_kind` 从 `buildModelCatalog()` 产物（+ 速度快额外拉 per-model endpoints）算出模型集、KV 缓存；`GET /v1/model-presets` 给 iOS 第一屏；bot `config.modelPool.presets` 在 `pickRandomModel` 里展开成 `models` 并集，复用现有池逻辑。iOS 单页重构 + 地名 bundle + 目录磁盘缓存。

**Tech Stack:** Supabase Postgres（迁移 + RLS）、Hono/CF Workers（TS, vitest）、Refine+AntD（board）、SwiftUI（iOS）。

**Spec:** `docs/superpowers/specs/2026-06-15-create-bot-presets-design.md`（含实测的 OpenRouter 数据源结论）。

**全局约定（每个 task 都适用）：**
- 迁移文件名用时间戳前缀：`supabase migration new <name>` 生成 `supabase/migrations/<timestamp>_<name>.sql`（别手填编号）。
- 应用迁移：在主 worktree 跑 `supabase db push --linked`（worktree 里先把主 worktree 的 `supabase/.temp` 复制进来，见 memory `feedback_worktree_deps_and_dbpush`），再 `bun --filter='@pendingbot/edge' run types:db` regen `schema.ts`（脚本带 `2>/dev/null`，别用裸命令）。
- 新 worktree 跑 edge vitest/typecheck 前先 `bun install`（`prepare` exit 1 可无视）。
- edge typecheck：`bun --filter='@pendingbot/edge' run typecheck`；vitest：`cd apps/edge && ./node_modules/.bin/vitest run <file>`。
- 提交粒度小、英文/中文前缀照仓库习惯（`db:` / `edge:` / `ios:` / `chore(...)`）；co-author trailer 用短式。
- pre-commit 钩子：暂存了 `supabase/migrations/*.sql` 必须同时暂存 `apps/edge/src/db/schema.ts`。

---

## Phase 0 — Edge：schema + config 管道

### Task 0.1: 迁移 — `model_presets` 表 + seed 5 个预设

**Files:**
- Create: `supabase/migrations/<timestamp>_model_presets.sql`（用 `supabase migration new model_presets`）

- [ ] **Step 1: 生成迁移文件**

Run: `supabase migration new model_presets`
Expected: 打印新建的 `supabase/migrations/<timestamp>_model_presets.sql` 路径。

- [ ] **Step 2: 写表 + RLS + seed**

写入该文件（RLS 锁死：仅 service role 读写——`/v1/model-presets` 端点与 board 都走 service client；普通用户无直接访问）：

```sql
-- 模型预设：board 管理"规则"，内容由 OpenRouter 目录动态解析（见 model-presets.ts）。
create table pendingbot.model_presets (
  slug text primary key,
  title text not null,
  description text not null default '',
  resolver_kind text not null check (resolver_kind in (
    'top_flagship', 'chinese_flagship', 'latest_per_vendor', 'fastest', 'most_popular', 'manual'
  )),
  params jsonb not null default '{}'::jsonb,
  default_selected boolean not null default false,
  enabled boolean not null default true,
  sort_order integer not null default 100,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table pendingbot.model_presets enable row level security;
-- 无 policy = 默认拒绝所有 anon/authenticated 直接访问；service role 绕过 RLS。

insert into pendingbot.model_presets (slug, title, description, resolver_kind, params, default_selected, sort_order) values
  ('top-flagship', '头两家旗舰', 'OpenAI 与 Anthropic 的旗舰模型', 'top_flagship',
   '{"authors":["openai","anthropic"],"flagship":"most_expensive"}'::jsonb, true, 10),
  ('cn-flagship', '中国旗舰', '国内头部厂商的旗舰模型', 'chinese_flagship',
   '{"authors":["deepseek","qwen","moonshotai","z-ai","minimax"],"flagship":"most_expensive"}'::jsonb, true, 20),
  ('latest-per-vendor', '各家最新', '每家厂商最新发布的模型', 'latest_per_vendor',
   '{"count":8}'::jsonb, true, 30),
  ('fastest', '速度快', '吞吐最高的模型', 'fastest',
   '{"count":5,"min_rating":1200}'::jsonb, false, 40),
  ('most-popular', '最热门', '评分最高的热门模型', 'most_popular',
   '{"count":5}'::jsonb, false, 50);
```

- [ ] **Step 3: 应用 + regen + typecheck**（见全局约定的 db push 流程）

Run: `supabase db push --linked` → `bun --filter='@pendingbot/edge' run types:db` → `bun --filter='@pendingbot/edge' run typecheck`
Expected: push 成功；`apps/edge/src/db/schema.ts` 出现 `model_presets`；typecheck 通过。

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/<timestamp>_model_presets.sql apps/edge/src/db/schema.ts
git commit -m "db: model_presets 表 + seed 5 个预设"
```

---

### Task 0.2: 迁移 — 放宽公有 bot 删除（仅 RLS DELETE 策略）

**背景核对（写迁移前先确认，别凭印象）：** 公有 bot 的"不可变"由 `bots_guard_public_update` 触发器实现，**它只在 UPDATE 触发**——删除只受 `bots_creator_delete` RLS 策略约束。所以本 task 只改 DELETE 策略，不碰触发器。"只有自己一个好友"= `user_bot_contacts` 里除创建者外无其他人。

**Files:**
- Create: `supabase/migrations/<timestamp>_relax_public_bot_delete.sql`

- [ ] **Step 1: 先确认现状**

Run: `supabase db query --linked "select polname, pg_get_expr(polqual, polrelid) from pg_policy p join pg_class c on c.oid=p.polrelid where c.relname='bots' and polcmd='d';"`
Expected: 看到 `bots_creator_delete` 的 `USING (creator_id = auth.uid() AND visibility = 'private')`。同时确认是否存在 `bot_invites` 表：`supabase db query --linked "select to_regclass('pendingbot.bot_invites');"`。

- [ ] **Step 2: 生成 + 写迁移**

Run: `supabase migration new relax_public_bot_delete`，写入：

```sql
-- 公有 bot 默认永久（不可删/改/转私有），但若除创建者外无人采用（user_bot_contacts
-- 无他人行、无待处理 bot_invites），允许创建者删除自己误建/弃用的公有 bot。
-- 只改 DELETE 策略；UPDATE 不可变规则（bots_guard_public_update 触发器）保持不变。
drop policy if exists bots_creator_delete on pendingbot.bots;
create policy bots_creator_delete on pendingbot.bots for delete
  using (
    creator_id = auth.uid()
    and (
      visibility = 'private'
      or (
        not exists (
          select 1 from pendingbot.user_bot_contacts c
          where c.bot_id = bots.id and c.user_id <> bots.creator_id
        )
        and not exists (
          select 1 from pendingbot.bot_invites bi where bi.bot_id = bots.id
        )
      )
    )
  );
```

> 若 Step 1 确认 `bot_invites` 不存在（已被某次迁移 drop），删掉那段 `and not exists (... bot_invites ...)`，只留 `user_bot_contacts` 判据。

- [ ] **Step 3: 应用 + typecheck**

Run: `supabase db push --linked` → `bun --filter='@pendingbot/edge' run types:db`（本迁移不改表结构，schema.ts 通常无 diff，但仍跑以保持一致）→ `bun --filter='@pendingbot/edge' run typecheck`
Expected: push 成功。

- [ ] **Step 4: 验证策略（手测）**

Run: `supabase db query --linked "set local role authenticated; -- 模拟某 creator 删一个无他人 contact 的 public_invite bot 应成功；有他人 contact 的应 0 行"`（按现状数据构造；无数据可跳过，留到 iOS 阶段真机验）
Expected: 逻辑符合预期或记为待真机验。

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/<timestamp>_relax_public_bot_delete.sql apps/edge/src/db/schema.ts
git commit -m "db: 放宽公有 bot 删除 — 无外部采用者可删"
```

---

### Task 0.3: `RandomModelConfig` 加 `presets` 字段（TS 类型 + parse + Zod）

**Files:**
- Modify: `apps/edge/src/llm/random-model.ts:25-41`（interface）、`:66-88`（parse）
- Modify: `apps/edge/src/routes/bots.ts:39-49`（Zod modelPool）
- Test: `apps/edge/src/llm/random-model.test.ts`（新建或追加）

- [ ] **Step 1: 写失败测试 — parseRandomModelConfig 解析 presets**

`apps/edge/src/llm/random-model.test.ts`：

```ts
import { describe, it, expect } from 'vitest';
import { parseRandomModelConfig } from './random-model';

describe('parseRandomModelConfig presets', () => {
  it('parses presets array', () => {
    const cfg = parseRandomModelConfig({ presets: ['top-flagship', 'cn-flagship'] });
    expect(cfg?.presets).toEqual(['top-flagship', 'cn-flagship']);
  });
  it('null presets when absent', () => {
    const cfg = parseRandomModelConfig({ models: ['openai/gpt-5.1'] });
    expect(cfg?.presets).toBeNull();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/llm/random-model.test.ts`
Expected: FAIL（`presets` 不存在于返回类型 / undefined）。

- [ ] **Step 3: 实现**

`random-model.ts` interface 追加（在 `release_window_days` 后）：
```ts
  // 选中的模型预设 slug（model_presets.slug）。对话时展开成模型并集并入 models。
  // null/empty = 无预设（纯显式/自定义）。
  presets: string[] | null;
```
`parseRandomModelConfig` 返回对象追加：`presets: strs(o.presets),`

`bots.ts` modelPool zod 对象内追加：
```ts
    presets: z.array(z.string().min(1).max(100)).max(20).nullable().optional(),
```

- [ ] **Step 4: 跑测试确认通过 + typecheck**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/llm/random-model.test.ts` → `bun --filter='@pendingbot/edge' run typecheck`
Expected: PASS + typecheck 通过。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/llm/random-model.ts apps/edge/src/routes/bots.ts apps/edge/src/llm/random-model.test.ts
git commit -m "edge: RandomModelConfig 加 presets 字段(parse+zod)"
```

---

## Phase 1 — Edge：预设解析器 + 端点 + 对话时展开

### Task 1.1: `model-presets.ts` 解析器（旗舰/最新/最热门，从目录算 + KV 缓存）

**Files:**
- Create: `apps/edge/src/lib/model-presets.ts`
- Test: `apps/edge/src/lib/model-presets.test.ts`

**设计：** `resolvePresetModels(env, def, catalog)` 纯函数式按 `resolver_kind` 从 catalog 算出 slug 列表（`fastest` 在 Task 1.2 接 endpoints）。`resolveModelPreset(env, slug)` 读 DB 定义 + 调上面 + KV 缓存。`resolveEnabledPresets(env)` 给端点用。

- [ ] **Step 1: 写失败测试（纯解析，喂假 catalog）**

`apps/edge/src/lib/model-presets.test.ts`：

```ts
import { describe, it, expect } from 'vitest';
import { resolvePresetModelsFromCatalog, type PresetDef } from './model-presets';
import type { OpenRouterModelOut } from '../routes/models';

const M = (over: Partial<OpenRouterModelOut>): OpenRouterModelOut => ({
  slug: 'x', display_name: 'X', provider: 'openai', release_date: '2026-01-01',
  context_length: null, supports_vision: false, blended_usd_per_million: 1,
  lmarena_license: null, lmarena_organization: null, lmarena_scores: {},
  source: 'openrouter', model_provider: null, ...over,
});

const catalog: OpenRouterModelOut[] = [
  M({ slug: 'gpt-5.1', provider: 'openai', source: 'openai', model_provider: 'openai', blended_usd_per_million: 10, release_date: '2026-05-01' }),
  M({ slug: 'gpt-5.1-mini', provider: 'openai', source: 'openai', model_provider: 'openai', blended_usd_per_million: 1, release_date: '2026-06-01' }),
  M({ slug: 'claude-opus-4-8', provider: 'anthropic', source: 'anthropic', model_provider: 'anthropic', blended_usd_per_million: 20, release_date: '2026-04-01' }),
  M({ slug: 'deepseek/deepseek-v3', provider: 'deepseek', source: 'openrouter', blended_usd_per_million: 0.5, release_date: '2026-03-01' }),
  M({ slug: 'meta-llama/llama-4', provider: 'meta-llama', source: 'openrouter', blended_usd_per_million: 0.2, release_date: '2026-06-10', lmarena_scores: { text: { rating: 1400, rank: 1, vote_count: 99, category: 'overall', leaderboard_publish_date: null } } }),
];

it('top_flagship most_expensive picks priciest per author, native row', () => {
  const def: PresetDef = { slug: 'top-flagship', resolver_kind: 'top_flagship', params: { authors: ['openai', 'anthropic'], flagship: 'most_expensive' }, title: '', description: '' };
  expect(resolvePresetModelsFromCatalog(def, catalog).sort()).toEqual(['claude-opus-4-8', 'gpt-5.1']);
});

it('latest_per_vendor picks newest per provider', () => {
  const def: PresetDef = { slug: 'latest', resolver_kind: 'latest_per_vendor', params: { count: 8 }, title: '', description: '' };
  const out = resolvePresetModelsFromCatalog(def, catalog);
  expect(out).toContain('gpt-5.1-mini'); // 06-01 > 05-01 for openai
  expect(out).toContain('meta-llama/llama-4');
});

it('most_popular ranks by lmarena text rating', () => {
  const def: PresetDef = { slug: 'pop', resolver_kind: 'most_popular', params: { count: 1 }, title: '', description: '' };
  expect(resolvePresetModelsFromCatalog(def, catalog)).toEqual(['meta-llama/llama-4']);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/lib/model-presets.test.ts`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 实现解析器（不含 fastest 的 endpoints 拉取）**

`apps/edge/src/lib/model-presets.ts`：

```ts
import type { Env } from '../types';
import {
  buildModelCatalog,
  fetchLMArenaRows,
  isNativeBackedOpenRouterSlug,
  looksNonChat,
  type OpenRouterModelOut,
} from '../routes/models';

export type ResolverKind =
  | 'top_flagship' | 'chinese_flagship' | 'latest_per_vendor'
  | 'fastest' | 'most_popular' | 'manual';

export interface PresetParams {
  authors?: string[];
  flagship?: 'most_expensive' | 'latest' | 'latest_in_series';
  series?: string;            // glob 前缀，如 'claude-opus-'，latest_in_series 用
  count?: number;
  min_rating?: number;
  manual_models?: string[];
}

export interface PresetDef {
  slug: string;
  title: string;
  description: string;
  resolver_kind: ResolverKind;
  params: PresetParams;
  default_selected?: boolean;
}

export interface ResolvedPreset {
  slug: string;
  title: string;
  description: string;
  default_selected: boolean;
  models: { slug: string; display_name: string; provider: string }[];
}

const PRESET_CACHE_PREFIX = 'model_preset:v1:';
const PRESET_TTL_SEC = 6 * 60 * 60;

// chat-only catalog 行（排除 native-backed OpenRouter 双胞胎 + 非 chat）
function chatRows(catalog: OpenRouterModelOut[]): OpenRouterModelOut[] {
  return catalog.filter((m) => {
    if (m.source === 'openrouter' && isNativeBackedOpenRouterSlug(m.slug)) return false;
    const slash = m.slug.indexOf('/');
    const tail = slash > 0 ? m.slug.slice(slash + 1) : m.slug;
    return !looksNonChat(tail);
  });
}

function ratingOf(m: OpenRouterModelOut): number | null {
  return m.lmarena_scores?.text?.rating ?? null;
}

function flagshipForAuthor(rows: OpenRouterModelOut[], strategy: PresetParams['flagship'], series?: string): OpenRouterModelOut | null {
  let pool = rows;
  if (strategy === 'latest_in_series' && series) {
    pool = rows.filter((m) => m.slug.includes(series));
  }
  if (pool.length === 0) return null;
  if (strategy === 'latest' || strategy === 'latest_in_series') {
    return [...pool].sort((a, b) => (b.release_date ?? '').localeCompare(a.release_date ?? ''))[0];
  }
  // most_expensive (default)
  return [...pool].sort((a, b) => (b.blended_usd_per_million ?? -1) - (a.blended_usd_per_million ?? -1))[0];
}

// 纯函数：从给定 catalog 算出 slug 列表（fastest 由 Task 1.2 覆盖）。
export function resolvePresetModelsFromCatalog(def: PresetDef, catalog: OpenRouterModelOut[]): string[] {
  const rows = chatRows(catalog);
  const p = def.params ?? {};
  switch (def.resolver_kind) {
    case 'manual':
      return p.manual_models ?? [];
    case 'top_flagship':
    case 'chinese_flagship': {
      const authors = p.authors ?? [];
      const out: string[] = [];
      for (const a of authors) {
        const f = flagshipForAuthor(rows.filter((m) => m.provider === a || providerMatchesAuthor(m, a)), p.flagship, p.series);
        if (f) out.push(f.slug);
      }
      return out;
    }
    case 'latest_per_vendor': {
      const byVendor = new Map<string, OpenRouterModelOut>();
      for (const m of rows) {
        const cur = byVendor.get(m.provider);
        if (!cur || (m.release_date ?? '') > (cur.release_date ?? '')) byVendor.set(m.provider, m);
      }
      return [...byVendor.values()]
        .sort((a, b) => (b.release_date ?? '').localeCompare(a.release_date ?? ''))
        .slice(0, p.count ?? 8)
        .map((m) => m.slug);
    }
    case 'most_popular': {
      return rows
        .filter((m) => ratingOf(m) != null)
        .sort((a, b) => (ratingOf(b) ?? 0) - (ratingOf(a) ?? 0))
        .slice(0, p.count ?? 5)
        .map((m) => m.slug);
    }
    case 'fastest':
      return []; // Task 1.2 覆盖（需 endpoints 吞吐）
  }
}

// native 行的 provider 是 'openai'/'anthropic'/'google-ai-studio'；OpenRouter 行
// provider 是厂商段（'openai'/'deepseek'/...）。author 匹配两者。
function providerMatchesAuthor(m: OpenRouterModelOut, author: string): boolean {
  if (author === 'google') return m.provider === 'google' || m.provider === 'google-ai-studio';
  return m.provider === author;
}

function enrich(slugs: string[], catalog: OpenRouterModelOut[]): ResolvedPreset['models'] {
  const bySlug = new Map(catalog.map((m) => [m.slug, m]));
  return slugs.flatMap((s) => {
    const m = bySlug.get(s);
    return m ? [{ slug: m.slug, display_name: m.display_name, provider: m.provider }] : [];
  });
}

// 读 DB 定义 + 算 + KV 缓存。Task 1.2 会在这里接入 fastest 的 endpoints 分支。
export async function resolveModelPreset(env: Env, def: PresetDef): Promise<ResolvedPreset> {
  const cacheKey = PRESET_CACHE_PREFIX + def.slug;
  const cached = await env.MEMORY.get<ResolvedPreset>(cacheKey, 'json').catch(() => null);
  if (cached) return cached;
  const catalog = await buildModelCatalog(await fetchLMArenaRows(env));
  const slugs = resolvePresetModelsFromCatalog(def, catalog);
  const resolved: ResolvedPreset = {
    slug: def.slug, title: def.title, description: def.description,
    default_selected: def.default_selected ?? false,
    models: enrich(slugs, catalog),
  };
  await env.MEMORY.put(cacheKey, JSON.stringify(resolved), { expirationTtl: PRESET_TTL_SEC }).catch(() => {});
  return resolved;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/lib/model-presets.test.ts`
Expected: PASS（3 个用例）。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/lib/model-presets.ts apps/edge/src/lib/model-presets.test.ts
git commit -m "edge: 模型预设解析器(旗舰/最新/最热门) + KV 缓存"
```

---

### Task 1.2: `fastest` — per-model endpoints 吞吐（候选集 + KV 缓存）

**Files:**
- Modify: `apps/edge/src/lib/model-presets.ts`
- Test: `apps/edge/src/lib/model-presets.test.ts`（追加）

**设计：** 候选 = chat 行 ∩ `rating >= min_rating`（默认 1200）∩ 非 free（`blended_usd_per_million > 0`）。对候选并发拉 `https://openrouter.ai/api/v1/models/{slug}/endpoints` 取 `max(throughput_last_30m)`，排序取前 count。整体结果走 Task 1.1 的同一 KV（已按 preset slug 缓存 6h，无需逐 endpoint 缓存——一次解析就缓住）。候选规模上限 40，避免拉爆。

- [ ] **Step 1: 写失败测试（注入 fetcher）**

追加：
```ts
import { resolveFastest } from './model-presets';

it('fastest ranks candidates by injected throughput, respects min_rating', async () => {
  const cat = [
    M({ slug: 'a/fast-strong', provider: 'a', blended_usd_per_million: 1, lmarena_scores: { text: { rating: 1300, rank: 1, vote_count: 1, category: 'overall', leaderboard_publish_date: null } } }),
    M({ slug: 'a/slow-strong', provider: 'a', blended_usd_per_million: 1, lmarena_scores: { text: { rating: 1300, rank: 2, vote_count: 1, category: 'overall', leaderboard_publish_date: null } } }),
    M({ slug: 'a/fast-weak', provider: 'a', blended_usd_per_million: 1, lmarena_scores: { text: { rating: 900, rank: 9, vote_count: 1, category: 'overall', leaderboard_publish_date: null } } }),
  ];
  const tput: Record<string, number> = { 'a/fast-strong': 200, 'a/slow-strong': 10, 'a/fast-weak': 999 };
  const out = await resolveFastest(cat, { count: 2, min_rating: 1200 }, async (slug) => tput[slug] ?? null);
  expect(out).toEqual(['a/fast-strong', 'a/slow-strong']); // weak 被 min_rating 滤掉
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/lib/model-presets.test.ts`
Expected: FAIL（`resolveFastest` 未导出）。

- [ ] **Step 3: 实现 `resolveFastest` + 真实 endpoints fetcher，接入 resolver switch**

```ts
const FASTEST_CANDIDATE_CAP = 40;

export type ThroughputFetcher = (slug: string) => Promise<number | null>;

export async function fetchThroughput(slug: string): Promise<number | null> {
  try {
    const res = await fetch(`https://openrouter.ai/api/v1/models/${slug}/endpoints`, {
      cf: { cacheTtlByStatus: { '200-299': 3600, '400-599': 0 }, cacheEverything: true },
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { data?: { endpoints?: { throughput_last_30m?: number | null }[] } };
    const eps = json.data?.endpoints ?? [];
    const vals = eps.map((e) => e.throughput_last_30m).filter((v): v is number => typeof v === 'number');
    return vals.length ? Math.max(...vals) : null;
  } catch {
    return null;
  }
}

export async function resolveFastest(
  catalog: OpenRouterModelOut[],
  params: PresetParams,
  fetcher: ThroughputFetcher = fetchThroughput,
): Promise<string[]> {
  const minRating = params.min_rating ?? 1200;
  const candidates = chatRows(catalog)
    .filter((m) => (m.blended_usd_per_million ?? 0) > 0 && (ratingOf(m) ?? 0) >= minRating)
    .slice(0, FASTEST_CANDIDATE_CAP);
  const scored = await Promise.all(
    candidates.map(async (m) => ({ slug: m.slug, tput: await fetcher(m.slug) })),
  );
  return scored
    .filter((s) => s.tput != null)
    .sort((a, b) => (b.tput ?? 0) - (a.tput ?? 0))
    .slice(0, params.count ?? 5)
    .map((s) => s.slug);
}
```

在 `resolveModelPreset` 里把 `fastest` 分支接上（替换 `resolvePresetModelsFromCatalog` 返回 `[]` 的情况）：
```ts
  const slugs = def.resolver_kind === 'fastest'
    ? await resolveFastest(catalog, def.params ?? {})
    : resolvePresetModelsFromCatalog(def, catalog);
```

- [ ] **Step 4: 跑测试确认通过 + typecheck**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/lib/model-presets.test.ts` → `bun --filter='@pendingbot/edge' run typecheck`
Expected: PASS + 通过。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/lib/model-presets.ts apps/edge/src/lib/model-presets.test.ts
git commit -m "edge: 速度快预设 — per-model endpoints 吞吐+质量下限"
```

---

### Task 1.3: `GET /v1/model-presets` 端点 + 挂载

**Files:**
- Create: `apps/edge/src/routes/model-presets.ts`
- Modify: `apps/edge/src/index.ts:179` 附近（挂 `v1.route('/model-presets', ...)`）

**设计：** 用 service client 读 `model_presets`（enabled、按 sort_order），对每个 `resolveModelPreset`，返回数组。整体响应也短 KV 缓存（避免每次都解析；用一个聚合 key，TTL 1h）。需要 service client 的拿法照 `board.ts` 现有用法（service client `.schema('pendingbot')`）。

- [ ] **Step 1: 写路由**

`apps/edge/src/routes/model-presets.ts`（按仓库现有 service-client 取法核对 import）：

```ts
import { Hono } from 'hono';
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase'; // ← 按 board.ts 实际 import 路径核对
import { resolveModelPreset, type PresetDef } from '../lib/model-presets';

export const modelPresetsRoutes = new Hono<{ Bindings: Env }>();

const LIST_CACHE_KEY = 'model_presets:list:v1';
const LIST_TTL_SEC = 60 * 60;

modelPresetsRoutes.get('/', async (c) => {
  const cached = await c.env.MEMORY.get(LIST_CACHE_KEY, 'json').catch(() => null);
  if (cached) return c.json(cached);

  const db = serviceClient(c.env).schema('pendingbot'); // ← 按实际 API 核对
  const { data, error } = await db
    .from('model_presets')
    .select('slug, title, description, resolver_kind, params, default_selected')
    .eq('enabled', true)
    .order('sort_order', { ascending: true });
  if (error) throw error;

  const defs = (data ?? []) as PresetDef[];
  const resolved = await Promise.all(defs.map((d) => resolveModelPreset(c.env, d)));
  await c.env.MEMORY.put(LIST_CACHE_KEY, JSON.stringify(resolved), { expirationTtl: LIST_TTL_SEC }).catch(() => {});
  return c.json(resolved);
});
```

- [ ] **Step 2: 挂载**

`index.ts` 在 `v1.route('/models', modelCatalogRoutes);` 后加：
```ts
import { modelPresetsRoutes } from './routes/model-presets';
// ...
v1.route('/model-presets', modelPresetsRoutes);
```

- [ ] **Step 3: typecheck**

Run: `bun --filter='@pendingbot/edge' run typecheck`
Expected: 通过（若 `serviceClient`/`.schema` 形态对不上，照 `board.ts` 实际写法改）。

- [ ] **Step 4: 冒烟（wrangler dev 或部署后）**

Run: `curl -s "$EDGE/v1/model-presets" | python3 -m json.tool | head -40`（`$EDGE` = 本地 wrangler 或 api.pendingname.com）
Expected: 5 个预设，每个含 `models[]`（旗舰/最新/最热门有内容；速度快有内容或为空但不报错）。**这里实测核对中国旗舰落到的真实 slug + 原生路由**（spec 待办项）。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/routes/model-presets.ts apps/edge/src/index.ts
git commit -m "edge: GET /v1/model-presets 端点 + KV 缓存"
```

---

### Task 1.4: 对话时展开 presets（`pickRandomModel` 注入）

**Files:**
- Modify: `apps/edge/src/llm/random-model.ts`（加 `expandPresets`，在 `pickRandomModel` 里调用）
- Test: `apps/edge/src/llm/random-model.test.ts`（追加）

**设计：** 把 `cfg.presets` 解析成 slug 并集，并入 `cfg.models`，再走现有 `filterPool`。无 presets 时 cfg 不变。解析复用 `resolveModelPreset`（KV 缓存，turn 路径便宜）。需要 preset 定义——`expandPresets` 用 service client 读 `model_presets`（按 slug in），或复用聚合缓存。为可测，`expandPresets` 接受一个 `resolve: (slugs) => Promise<string[]>` 注入。

- [ ] **Step 1: 写失败测试**

```ts
import { expandPresets } from './random-model';

it('expandPresets unions resolved preset slugs into models', async () => {
  const cfg = { price_min: null, price_max: null, models: ['x/explicit'], exclude: null, vendors: null, release_window_days: null, presets: ['top-flagship'] };
  const out = await expandPresets(cfg, async (slugs) => slugs.includes('top-flagship') ? ['openai/gpt-5.1', 'anthropic/claude'] : []);
  expect(out.models?.sort()).toEqual(['anthropic/claude', 'openai/gpt-5.1', 'x/explicit']);
  expect(out.presets).toBeNull(); // 展开后清空，避免下游重复解析
});

it('expandPresets passthrough when no presets', async () => {
  const cfg = { price_min: null, price_max: null, models: ['a'], exclude: null, vendors: null, release_window_days: null, presets: null };
  const out = await expandPresets(cfg, async () => { throw new Error('should not call'); });
  expect(out.models).toEqual(['a']);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/llm/random-model.test.ts`
Expected: FAIL（`expandPresets` 未导出）。

- [ ] **Step 3: 实现**

`random-model.ts` 加：
```ts
export type PresetResolver = (presetSlugs: string[]) => Promise<string[]>;

// 把 cfg.presets 解析成模型并集并入 cfg.models；展开后清空 presets。
export async function expandPresets(cfg: RandomModelConfig, resolve: PresetResolver): Promise<RandomModelConfig> {
  if (!cfg.presets || cfg.presets.length === 0) return cfg;
  const presetSlugs = await resolve(cfg.presets);
  const merged = [...new Set([...(cfg.models ?? []), ...presetSlugs])];
  return { ...cfg, models: merged.length ? merged : null, presets: null };
}
```

实现真实 resolver（读 DB 定义 + resolveModelPreset 并 union），并在 `pickRandomModel` 顶部调用：
```ts
import { resolveModelPreset, type PresetDef } from '../lib/model-presets';
import { serviceClient } from '../lib/supabase'; // 按实际核对

async function resolvePresetsToSlugs(env: Env, presetSlugs: string[]): Promise<string[]> {
  const db = serviceClient(env).schema('pendingbot');
  const { data } = await db.from('model_presets')
    .select('slug, title, description, resolver_kind, params, default_selected')
    .in('slug', presetSlugs).eq('enabled', true);
  const defs = (data ?? []) as PresetDef[];
  const resolved = await Promise.all(defs.map((d) => resolveModelPreset(env, d)));
  return [...new Set(resolved.flatMap((r) => r.models.map((m) => m.slug)))];
}
```
`pickRandomModel` 改：
```ts
  const pool = await getPool(env);
  if (!pool || pool.length === 0) return null;
  const effectiveCfg = await expandPresets(cfg, (slugs) => resolvePresetsToSlugs(env, slugs));
  let candidates = filterPool(pool, effectiveCfg);
```

- [ ] **Step 4: 跑测试 + typecheck**

Run: `cd apps/edge && ./node_modules/.bin/vitest run src/llm/random-model.test.ts` → `bun --filter='@pendingbot/edge' run typecheck`
Expected: PASS + 通过。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/llm/random-model.ts apps/edge/src/llm/random-model.test.ts
git commit -m "edge: pickRandomModel 对话时展开 preset 引用"
```

---

## Phase 2 — Board：model_presets 管理页

### Task 2.1: board.ts 注册 `model_presets` 资源

**Files:**
- Modify: `apps/edge/src/routes/board.ts`

- [ ] **Step 1: 加 Zod + boardResource（mirror `preset-conversations`）**

```ts
const modelPresetCreate = z.object({
  slug: z.string().min(1),
  title: z.string().min(1),
  description: z.string().default(''),
  resolver_kind: z.enum(['top_flagship', 'chinese_flagship', 'latest_per_vendor', 'fastest', 'most_popular', 'manual']),
  params: z.record(z.unknown()).default({}),
  default_selected: z.boolean().default(false),
  enabled: z.boolean().default(true),
  sort_order: z.number().int().default(100),
});
boardRoutes.route(
  '/model-presets',
  boardResource({
    table: 'model_presets',
    pk: 'slug',
    targetKind: 'model_preset',
    cols: 'slug, title, description, resolver_kind, params, default_selected, enabled, sort_order, updated_at',
    orderBy: { col: 'sort_order', ascending: true },
    createSchema: modelPresetCreate,
    updateSchema: modelPresetCreate.partial(),
  }),
);
```

- [ ] **Step 2: typecheck**

Run: `bun --filter='@pendingbot/edge' run typecheck`
Expected: 通过。

- [ ] **Step 3: Commit**

```bash
git add apps/edge/src/routes/board.ts
git commit -m "edge(board): model_presets CRUD 资源"
```

---

### Task 2.2: admin 页 `model-presets.tsx` + 注册

**Files:**
- Create: `apps/admin/src/pages/model-presets.tsx`
- Modify: `apps/admin/src/providers/resource-map.ts`、`apps/admin/src/App.tsx`

- [ ] **Step 1: resource-map 加条目**

```ts
model_presets: {
  basePath: 'board/model-presets',
  exists: true,
  listKey: 'items',
  note: 'EXISTING: /v1/board/model-presets CRUD.',
},
```

- [ ] **Step 2: App.tsx 加 resource + 路由**

resources[] 加：
```tsx
{ name: 'model_presets', list: '/model-presets', create: '/model-presets/create', edit: '/model-presets/edit/:id', meta: { label: '模型预设' } },
```
Routes 加：
```tsx
<Route path="/model-presets" element={<ModelPresetList />} />
<Route path="/model-presets/create" element={<ModelPresetCreate />} />
<Route path="/model-presets/edit/:id" element={<ModelPresetEdit />} />
```
并 import 三个组件。

- [ ] **Step 3: 写页面（mirror preset-conversations.tsx；params 用 JsonField kind="object"）**

`pages/model-presets.tsx`：List（列 slug/title/resolver_kind/default_selected/enabled/sort_order）+ Create/Edit 共用 `PresetFields`：`slug`(create 可编辑)、`title`、`description`、`resolver_kind`（AntD `Select` 六选项）、`default_selected`/`enabled`（Switch）、`sort_order`（InputNumber）、`params`（`<JsonField name="params" label="参数 (JSON)" kind="object" rows={8} placeholder='{"authors":["openai","anthropic"],"flagship":"most_expensive"}' />`）。结构与 `preset-conversations.tsx` 一致，rowKey="slug"，resource='model_presets'。

- [ ] **Step 4: build admin + edge typecheck**

Run: `cd apps/admin && bun run build`（`tsc --noEmit && vite build`）
Expected: 构建成功，`apps/admin/dist` 更新。

- [ ] **Step 5: Commit**

```bash
git add apps/admin/src/pages/model-presets.tsx apps/admin/src/providers/resource-map.ts apps/admin/src/App.tsx
git commit -m "board: 模型预设管理页"
```

---

## Phase 3 — iOS：一页式 create + 地名 + 性能 + slug 退役

### Task 3.1: ModelPresetsAPI + 模型 + `RandomModelConfig.presets`

**Files:**
- Modify: `apps/pendingbot/Sources/Models/APIModels.swift`（`RandomModelConfig` 加 `presets`；新 `ModelPreset`/`ModelPresetEntry` 解码）
- Create: `apps/pendingbot/Sources/Networking/ModelPresetsAPI.swift`（`func modelPresets() async throws -> [ModelPreset]`，走 `APIClient().get("v1/model-presets")`）

- [ ] **Step 1: 加模型**

`APIModels.swift` `RandomModelConfig` 加 `var presets: [String]?`。新增：
```swift
struct ModelPreset: Codable, Identifiable, Hashable {
    let slug: String
    let title: String
    let description: String
    let default_selected: Bool
    let models: [Entry]
    var id: String { slug }
    struct Entry: Codable, Hashable { let slug: String; let display_name: String; let provider: String }
}
```

- [ ] **Step 2: API + build**

`ModelPresetsAPI.swift`：`func get() async throws -> [ModelPreset] { try await APIClient().get("v1/model-presets") }`（或扩展 APIClient，照仓库风格）。
Run: iOS build（见 Task 3.6 命令）
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Models/APIModels.swift apps/pendingbot/Sources/Networking/ModelPresetsAPI.swift
git commit -m "ios: ModelPreset 模型 + /v1/model-presets API + RandomModelConfig.presets"
```

---

### Task 3.2: GeoNames 世界地名 bundle + `PlaceNames`

**Files:**
- Create: `apps/pendingbot/Resources/place_names.txt`（展示友好：带空格的城市名，如 `Casablanca`、`Buenos Aires`）
- Create: `apps/pendingbot/Sources/Stores/PlaceNames.swift`
- Modify: `apps/pendingbot/project.yml`（确保 Resources 进 bundle）

- [ ] **Step 1: 生成地名文件**

从 GeoNames cities15000 生成展示友好列表（保留空格、去重、ASCII）。可复用现成数据源；命令示例（执行者按可用数据调整）：
```bash
# 下载 cities15000（GeoNames，CC BY 4.0），取 asciiname 列（第3列），人口>50000 优先，去重排序
curl -s https://download.geonames.org/export/dump/cities15000.zip -o /tmp/c.zip && cd /tmp && unzip -o c.zip
awk -F'\t' '$15>50000 {print $3}' /tmp/cities15000.txt | sort -u > apps/pendingbot/Resources/place_names.txt
```
首行加注释：`# Source: GeoNames cities15000 (CC BY 4.0) https://www.geonames.org/`（`PlaceNames` 会跳过 `#` 行）。

- [ ] **Step 2: 写 PlaceNames（mirror pendingcrew 的 PlaceNames.swift）**

```swift
enum PlaceNames {
    static let all: [String] = {
        guard let url = Bundle.main.url(forResource: "place_names", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return ["Atlantis"] }
        let names = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return names.isEmpty ? ["Atlantis"] : names
    }()
    static func random(excluding used: Set<String> = []) -> String {
        let pool = all.filter { !used.contains($0.lowercased()) }
        return (pool.isEmpty ? all : pool).randomElement() ?? "Atlantis"
    }
}
```

- [ ] **Step 3: project.yml + xcodegen + build**

确保 `Resources/` 在 PendingBot target 的 sources/resources；改后 `cd apps/pendingbot && xcodegen`。Build（Task 3.6）。
Expected: bundle 含 place_names.txt，编译通过。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Resources/place_names.txt apps/pendingbot/Sources/Stores/PlaceNames.swift apps/pendingbot/project.yml apps/pendingbot/PendingBot.xcodeproj/project.pbxproj
git commit -m "ios: GeoNames 世界地名 bundle + PlaceNames"
```

---

### Task 3.3: `CreateBotSheet` 单页重构

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Friends/BotManagement.swift`（重写 `CreateBotSheet`）

**目标形态（替换现有两步 sheet）：** 单 `Form`，无 `CreateStep`、无"下一步"。Sections：
1. **名字** — `TextField` + "换一个"按钮（`displayName = PlaceNames.random(excluding: usedNames)`）。默认 `seedDefaultName` 改用 `PlaceNames.random`（去掉 `loremTokens`）。
2. **模型预设（可多选）** — `@State var presets: [ModelPreset]`（`.task` 拉 `ModelPresetsAPI`），`@State var selectedPresetSlugs: Set<String>`（首拉后置为 `default_selected` 的）。每行：勾选 toggle + title + 副标题（前几个 `models.display_name`）+ `NavigationLink` 进二级看完整 `models`。
3. **自定义模型池** — 一行 `NavigationLink` → `ArenaModelPoolEditor`，**seed = 当前选中预设的模型并集**（把并集塞进一个 `ArenaModelSelection(models: union, ...)` 传入）。确认后置 `customSelection`，主页面显示"自定义 · N 个"，并把 `usingCustom = true`（选中预设转为起点、不再用 presets 引用）。
4. **公开程度** — 私有(默认)/公有·邀请制 radio。**无 slug 字段。**

**创建逻辑：**
- `model_id`（fallback）：usingCustom 时 = `customSelection.fallbackModel`；否则 = 选中预设并集的第一个 slug（拉取时记下，或用 `presets` 里第一个 model）。
- `config.modelPool`：usingCustom → `customSelection.persistedConfig`（显式，presets 留空）；否则 → `RandomModelConfig(presets: Array(selectedPresetSlugs), ...其余 nil)`。
- `slug`：**永远自动** = `"u_" + UUID...prefix(16)`（私有公有都用，不再区分；不读用户输入）。
- `visibility`、`tz`（公有带 tz）、`user_bot_contacts` 插入：照旧。
- `canCreate` = 名字非空 && (selectedPresetSlugs 非空 || usingCustom)。删掉 slug 校验、`canAdvanceFromModels`、`selectedModelSlug`(改成上面的 fallback 逻辑)。

- [ ] **Step 1: 重写 CreateBotSheet**

按上述形态重写。`Visibility` enum 保留（去掉 subtitle 里"不能删"的措辞，因为现在无外部采用者可删——改为"你邀请的人才能聊；无人加入前仍可删除"）。删除 `loremTokens`、`step`/`CreateStep`、slug `@State` 与 slug Section。

- [ ] **Step 2: build**

Run: iOS build（Task 3.6）
Expected: 编译通过。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Features/Friends/BotManagement.swift
git commit -m "ios: CreateBotSheet 单页重构(预设多选+自定义+地名+公开程度,自动slug)"
```

---

### Task 3.4: slug 退役 — ManageBotSheet + BotSlugRule 清理

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Friends/BotManagement.swift`（ManageBotSheet slug 编辑 Section 删除；分享区只读保留；删 `BotSlugRule` 及其全部引用）

**清理点（来自 grep，全部在 BotManagement.swift）：** ManageBotSheet 的 slug `@State` + slug Section（~473-490）、save 的 slug dirty/payload（~660/729）、重复名报错（~754）、`isValid` 在 save disable（~573）。CreateBotSheet 的引用已在 Task 3.3 移除。最后删 `enum BotSlugRule`（22-43）。分享区（NavigationLink → BotSharePage）保留——它用 `initial.id`/`display_name`，不依赖用户改 slug。

- [ ] **Step 1: 删 ManageBotSheet slug 编辑 + save 里 slug 逻辑**

ManageBotSheet 公有 bot 不再展示/提交 slug（slug 已永久不可改，符合"自动 id"模型）。save payload 去掉 slug 字段；dirty 检查去掉 slug；重复名报错分支删除（slug 自动不会撞）。

- [ ] **Step 2: 删 `BotSlugRule` enum**

确认全仓 grep 无残留：`grep -rn BotSlugRule apps/pendingbot/Sources` → 应为空。

- [ ] **Step 3: build**

Run: iOS build（Task 3.6）
Expected: 编译通过，无 `BotSlugRule` 未定义错误。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Features/Friends/BotManagement.swift
git commit -m "ios: 退役 vanity slug(ManageBotSheet 去 slug 编辑 + 删 BotSlugRule)"
```

---

### Task 3.5: 模型目录磁盘缓存 + 收口 + 排序离主线程

**Files:**
- Modify: `apps/pendingbot/Sources/Storage/ModelCatalog.swift`（加磁盘持久缓存：先显缓存、后台刷新；带 ETag/Last-Modified 最好，最低限度 JSON 落盘 + 启动读）
- Modify: `apps/pendingbot/Sources/Features/Friends/ModelPicker.swift`（`ArenaModelPoolEditor.load()` 改走 `ModelCatalog` 单一来源，不再独立 `api.get("v1/models")`；`resort()` 放 `Task.detached`/`await` 后台再回主线程赋值）

- [ ] **Step 1: ModelCatalog 磁盘缓存**

`loadIfNeeded()`：启动先从 `Caches/model_catalog.json` 读并填 `bySlug`（瞬显），再后台 `api.get("v1/models")` 刷新并落盘。失败保留旧缓存。

- [ ] **Step 2: ArenaModelPoolEditor 走 catalog**

`load()` 改成等 `catalog.loadIfNeeded()` 完成后用 `catalog.bySlug.values` 构建 `allModels`，去掉自有 `api.get`。排序在后台算好再赋值。

- [ ] **Step 3: build + 冒烟**

Run: iOS build（Task 3.6）
Expected: 编译通过；进自定义页秒显（缓存命中）。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Storage/ModelCatalog.swift apps/pendingbot/Sources/Features/Friends/ModelPicker.swift
git commit -m "ios: 模型目录磁盘缓存 + ArenaPoolEditor 收口单一来源 + 排序离主线程"
```

---

### Task 3.6: project.yml/xcodegen + iOS/iPad build 验证

**Files:** （无新文件；构建验证）

- [ ] **Step 1: xcodegen（如改了 project.yml）**

Run: `cd apps/pendingbot && xcodegen`

- [ ] **Step 2: iOS build**

Run: `cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit（若 pbxproj 有 diff）**

```bash
git add apps/pendingbot/PendingBot.xcodeproj/project.pbxproj
git commit -m "ios: xcodegen 重生成 — 预设/地名资源进 bundle"
```

---

## Phase 4 — 验证 + 账本

### Task 4.1: Edge 全量验证

- [ ] **Step 1: typecheck + vitest**

Run: `bun --filter='@pendingbot/edge' run typecheck` && `cd apps/edge && ./node_modules/.bin/vitest run`
Expected: 全绿。

- [ ] **Step 2: 端点冒烟（部署或 wrangler dev）**

Run: `curl -s "$EDGE/v1/model-presets" | python3 -m json.tool`
Expected: 5 个预设有合理内容；**实测核对中国旗舰真实 slug + 原生路由是否生效**（spec 待办）。

---

### Task 4.2: iOS 模拟器真机验证（按 memory `feedback_ios_simulator_verify` 装进模拟器截图）

- [ ] **Step 1: 装进模拟器 + 截图核对**

走一遍：建私有 bot（默认勾 3 预设、换一个名字、一页创建）→ 建公有 bot（默认私有需手切公有，无 slug 字段）→ 自定义（进 ArenaPoolEditor，seed 是预设并集）→ 点预设看包含模型 → 进自定义页是否秒显。
Expected: 截图逐项符合；进自定义页无"等好几秒"。

- [ ] **Step 2: 删除验证**

建一个公有 bot（无人加入）→ 管理里能删；模拟有他人 contact 的不能删（或留真机/后端验，记录结论）。

---

### Task 4.3: 账本对账

- [ ] **Step 1: progress / tech-debt**

- `docs/progress.md` 顶部"最近对账"更新日期 + 本 feature 状态。
- `docs/tech-debt.md` 记两条：①最热门=LMArena 评测质量榜代理（非真实使用量榜，将来加 OR key 可换真用量）；②旗舰策略"最贵"依赖 blended 估算，可能偏 pro/ultra，必要时切 latest_in_series。
- Task 系统：为本 plan 各 task 建条目并随提交翻状态（completed = 已验证）。中国旗舰真实覆盖/原生路由的实测若未真机确认，相应 task 保持 open 或加注。

- [ ] **Step 2: Commit**

```bash
git add docs/progress.md docs/tech-debt.md
git commit -m "chore: 账本对账 — 新建机器人预设 feature"
```

---

## Self-Review（spec 覆盖核对）

- 一页式（名字/预设多选/自定义/公开程度，无下一步）→ Task 3.3 ✓
- 预设 board 管理 + OpenRouter 动态 → Task 0.1 / 1.1 / 1.2 / 2.1 / 2.2 ✓
- 5 预设规则驱动（头两家固定 OpenAI+Anthropic、旗舰策略、各家最新、速度快 endpoints、最热门 LMArena）→ Task 1.1 / 1.2 + seed 0.1 ✓
- 存预设引用、对话时解析 → Task 0.3 / 1.4 ✓
- 默认私有 + 公有无外部采用者可删 → Task 0.2 + 3.3 ✓
- 名字 GeoNames 随机 + 换一个 → Task 3.2 / 3.3 ✓
- vanity slug 彻底退役（create + manage + BotSlugRule）→ Task 3.3 / 3.4 ✓
- 性能（目录磁盘缓存 + 懒加载 + 离主线程 + 端点 KV）→ Task 1.3 / 3.5 ✓
- 验证（edge typecheck/vitest + iOS/iPad build + 模拟器实测）→ Phase 4 ✓
- 待实测项（中国旗舰覆盖/原生路由）→ Task 1.3 Step4 / 4.1 Step2 显式标注 ✓
