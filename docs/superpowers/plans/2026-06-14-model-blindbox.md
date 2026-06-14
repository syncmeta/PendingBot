# Model Blind Box Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the arena feature from LMArena-style model *evaluation* (A/B blind voting + Bradley-Terry leaderboard) into a gacha-style *blind box*: hide the model name as `PendingModel` until the user guesses it, reveal conversation-wide, re-roll only on regenerate / manual switch (cache-friendly), with a per-bot surprise/disclose toggle and an LLM tool that pops the guess UI.

**Architecture:** A conversation draws one model and **keeps it fixed** across turns (prompt-cache friendly). `conversations.model_revealed` (new bool) drives a single conversation-level pill: `false` → `PendingModel`, `true` → friendly name. Reveal happens by guessing (or giving up) via a new `POST /v1/conversations/:id/reveal-model`. Re-roll happens only on manual regenerate (gated by bot `blindBox.regenReroll`) or manual model switch (`POST /v1/conversations/:id/model`), both of which reset `model_revealed=false` (random) or set it `true` (specific pick). An LLM tool `prompt_model_guess` inserts a `log_kind='guess_prompt'` message the client renders as an interactive card. The old A/B compare + leaderboard + `model_comparisons` table are deleted outright.

**Tech Stack:** Cloudflare Workers + Hono + Zod (edge, `apps/edge`), Supabase Postgres (migrations), Vitest (edge tests), SwiftUI iOS/iPad/macOS (`apps/pendingbot`).

**Design doc:** `docs/superpowers/specs/2026-06-14-model-blindbox-design.md`

---

## Key facts the implementer must know

- **Conversation model is fixed once drawn.** First user turn draws from the bot pool and persists `conversations.current_model_slug` (see `chooseConversationMainModel` in `apps/edge/src/lib/conversation-model.ts`). Every later normal turn reuses it. **Do not** re-pick per message — that destroys prompt caching.
- **`model_revealed` is display-only.** It never affects model selection or the LLM call. Lifecycle: `false` on draw/re-roll/switch-to-random; `true` on reveal (guess/give-up) and switch-to-specific.
- **The conversation header pill currently shows the BOT's model** (`effectiveBot?.model` in `ConversationView.swift:307-314`), not the per-conversation drawn model. This plan repoints it to the conversation's `current_model_slug` + `model_revealed`.
- **There is no per-conversation model-switch endpoint today.** The only writer of `current_model_slug` outside first-draw was `arena.ts` (being deleted). This plan adds `POST /v1/conversations/:id/model`.
- **`messages` bot-row insert sets no explicit `kind`** (relies on DB default). The `log_kind` column is what the client reads (`MessageRow.log_kind` in `MessagesFetch.swift`). `role='log'` rows are filtered out of normal bubbles (`ChatDataSource.swift:230`) and dispatched by `log_kind` in `ConversationView+Loading.swift` (the crew_proposal / permission_request pattern). The guess card mirrors `permission_request`.
- **`ConfigPatch` in `bots.ts` ends with `.strict()`** — a new `blindBox` object MUST be added to the zod schema or PATCH 400s.
- **Tools must have a `pendingbot.tools` DB row** (`enabled=true`) or `applyToolRegistry` strips them at turn-assembly. Seed `prompt_model_guess` via migration.
- **Edge tests:** `cd apps/edge && ./node_modules/.bin/vitest run`. No vitest config; tests are colocated `*.test.ts` exercising **pure functions** (route handlers are not unit-tested in this repo — verify them via typecheck + manual). Typecheck: `bun --filter='@pendingbot/edge' run typecheck`.
- **iOS build:** `cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build`; macOS: `-destination 'platform=macOS'`. No iOS unit tests for this UI — verification is build + (final) simulator smoke.
- **Commit cadence:** small units, auto-commit, co-author trailer `Co-Authored-By: Claude <noreply@anthropic.com>`. `git add` only the unit's files.

---

## Phase 0 — DB migration + schema regen

### Task 0.1: Write the blind-box migration

**Files:**
- Create: `supabase/migrations/<timestamp>_model_blindbox.sql` (generate the name; do NOT hand-pick a number)

- [ ] **Step 1: Generate the migration file**

Run from the main worktree dir (where `supabase/.temp/linked-project.json` lives) OR this worktree if linked:
```bash
supabase migration new model_blindbox
```
If `supabase` is unavailable, create the file directly with `date -u +%Y%m%d%H%M%S` as the prefix.

- [ ] **Step 2: Write the migration body**

```sql
-- model_blindbox
--
-- arena(模型评价)→ 盲盒(娱乐猜模型)。
--   1) conversations.model_revealed —— 当前会话模型是否已揭示。
--      false = 显示 "PendingModel";true = 显示真名。抽/重抽/换随机时置 false,
--      猜中/放弃揭晓/换具体模型时置 true。仅影响显示,不影响模型选择。
--   2) model_guesses —— 持久猜测记录(每揭示一条)。
--   3) DROP model_comparisons —— 旧 A/B 盲投评价框架连根拔。

BEGIN;

SET search_path TO pendingbot, public;

-- 1. 揭示状态
ALTER TABLE pendingbot.conversations
  ADD COLUMN model_revealed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN pendingbot.conversations.model_revealed IS
  '盲盒:当前会话模型是否已揭示。false=显示 PendingModel。抽/重抽/换随机=false;猜中/放弃/换具体=true。';

-- 2. 持久猜测记录
CREATE TABLE pendingbot.model_guesses (
  id              uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  conversation_id uuid        NOT NULL REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  actual_slug     text        NOT NULL,
  actual_provider text,
  guessed_slug    text,                 -- 不想猜 = NULL
  correct         boolean,              -- 不想猜 = NULL;否则 guessed_slug == actual_slug
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX model_guesses_user_conv_idx
  ON pendingbot.model_guesses (user_id, conversation_id, created_at DESC);

ALTER TABLE pendingbot.model_guesses ENABLE ROW LEVEL SECURITY;

-- 只读自己的;写入走 edge service_role(绕过 RLS)。
CREATE POLICY model_guesses_self_read
  ON pendingbot.model_guesses FOR SELECT
  USING (user_id = auth.uid());

GRANT SELECT ON TABLE pendingbot.model_guesses TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.model_guesses TO service_role;

-- 3. 旧评价框架连根拔(policy/index 随表自动 drop)
DROP TABLE IF EXISTS pendingbot.model_comparisons;

-- 4. 盲盒猜模型 tool 注册(否则 applyToolRegistry 会在 turn-assembly 时滤掉)
INSERT INTO pendingbot.tools (key, scopes, enabled, model_description)
VALUES (
  'prompt_model_guess',
  ARRAY['chat'],
  true,
  '当你想邀请用户猜一猜本会话背后是哪个模型时调用(无参)。会在聊天里插入一张"猜一猜"互动卡片。仅在盲盒模式(用户尚未揭示)下有意义;若用户已知道模型,不要调用。'
)
ON CONFLICT (key) DO UPDATE
  SET scopes = EXCLUDED.scopes,
      enabled = EXCLUDED.enabled,
      model_description = EXCLUDED.model_description;

COMMIT;
```

> If the `pendingbot.tools` table's unique key is not `key`, adjust the `ON CONFLICT` target — check `schema.ts` for the tools table PK before writing. (Item 5 of the edge recon confirmed the loader reads `key, scopes, model_description, enabled`.)

- [ ] **Step 3: Apply + regen schema + typecheck**

```bash
supabase db push --linked
bun --filter='@pendingbot/edge' run types:db
bun --filter='@pendingbot/edge' run typecheck
```
Expected: push applies cleanly; `src/db/schema.ts` now has `model_guesses`, `conversations.model_revealed`, and no `model_comparisons`; typecheck passes (it will still fail to compile `arena.ts` which references `model_comparisons` — that's expected and removed in Phase 1; if you want a green typecheck here, do Phase 1 Task 1.1 first, then return. Recommended order: do 0.1 steps 1-2, then 1.1, then 0.1 step 3.)

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/<timestamp>_model_blindbox.sql apps/edge/src/db/schema.ts
git commit -m "db: model blind box schema — model_revealed + model_guesses, drop model_comparisons, seed prompt_model_guess

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 1 — Edge teardown (delete the evaluation framework)

### Task 1.1: Delete arena routes, lib, tests, and unmount

**Files:**
- Delete: `apps/edge/src/routes/arena.ts`
- Delete: `apps/edge/src/lib/arena-bradley-terry.ts`
- Delete: `apps/edge/src/lib/arena-bradley-terry.test.ts`
- Delete: `apps/edge/src/routes/arena-switch.test.ts`
- Modify: `apps/edge/src/index.ts` (remove import line 40 + mount line 177)

- [ ] **Step 1: Delete the files**

```bash
git rm apps/edge/src/routes/arena.ts \
       apps/edge/src/lib/arena-bradley-terry.ts \
       apps/edge/src/lib/arena-bradley-terry.test.ts \
       apps/edge/src/routes/arena-switch.test.ts
```

- [ ] **Step 2: Remove the import + mount in `index.ts`**

Delete line 40 `import { arenaRoutes } from './routes/arena';` and line 177 `v1.route('/arena', arenaRoutes);`.

- [ ] **Step 3: Grep for stragglers**

```bash
grep -rn "arena\|model_comparisons\|bradley\|computeLeaderboard\|modelSwitchForOutcome" apps/edge/src
```
Expected: only `modelPoolConfigFromBotConfig`'s legacy `record.arena` read in `conversation-model.ts:31` (keep — that's the legacy config key, not the route) and possibly comments. Remove any other live references.

- [ ] **Step 4: Typecheck**

```bash
bun --filter='@pendingbot/edge' run typecheck
```
Expected: PASS (assuming Phase 0 schema regen done; otherwise schema.ts still has model_comparisons and that's fine for typecheck).

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/index.ts
git commit -m "edge: remove arena A/B compare + Bradley-Terry leaderboard

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 2 — Edge: blindBox config + conversation-model helpers (TDD)

### Task 2.1: `parseBlindBoxConfig` helper

**Files:**
- Modify: `apps/edge/src/lib/conversation-model.ts`
- Test: `apps/edge/src/lib/conversation-model.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `conversation-model.test.ts`:
```ts
import {
  parseBlindBoxConfig,
} from './conversation-model';

describe('parseBlindBoxConfig', () => {
  it('defaults to surprise + regenReroll when absent', () => {
    expect(parseBlindBoxConfig(null)).toEqual({ revealMode: 'surprise', regenReroll: true });
    expect(parseBlindBoxConfig({})).toEqual({ revealMode: 'surprise', regenReroll: true });
  });
  it('reads disclose + regenReroll=false', () => {
    expect(parseBlindBoxConfig({ blindBox: { revealMode: 'disclose', regenReroll: false } }))
      .toEqual({ revealMode: 'disclose', regenReroll: false });
  });
  it('ignores garbage and falls back to defaults', () => {
    expect(parseBlindBoxConfig({ blindBox: { revealMode: 'nonsense', regenReroll: 'x' } }))
      .toEqual({ revealMode: 'surprise', regenReroll: true });
  });
});
```

- [ ] **Step 2: Run, verify fail**

```bash
cd apps/edge && ./node_modules/.bin/vitest run src/lib/conversation-model.test.ts
```
Expected: FAIL — `parseBlindBoxConfig is not a function`.

- [ ] **Step 3: Implement**

Add to `apps/edge/src/lib/conversation-model.ts`:
```ts
export type RevealMode = 'surprise' | 'disclose';

export interface BlindBoxConfig {
  revealMode: RevealMode;
  regenReroll: boolean;
}

export function parseBlindBoxConfig(config: unknown): BlindBoxConfig {
  const fallback: BlindBoxConfig = { revealMode: 'surprise', regenReroll: true };
  if (!config || typeof config !== 'object' || Array.isArray(config)) return fallback;
  const bb = (config as Record<string, unknown>).blindBox;
  if (!bb || typeof bb !== 'object' || Array.isArray(bb)) return fallback;
  const record = bb as Record<string, unknown>;
  const revealMode: RevealMode = record.revealMode === 'disclose' ? 'disclose' : 'surprise';
  const regenReroll = typeof record.regenReroll === 'boolean' ? record.regenReroll : true;
  return { revealMode, regenReroll };
}
```

- [ ] **Step 4: Run, verify pass**

```bash
cd apps/edge && ./node_modules/.bin/vitest run src/lib/conversation-model.test.ts
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/lib/conversation-model.ts apps/edge/src/lib/conversation-model.test.ts
git commit -m "edge: parseBlindBoxConfig helper (revealMode + regenReroll)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 2.2: Accept `blindBox` in the bot config zod schema

**Files:**
- Modify: `apps/edge/src/routes/bots.ts` (`ConfigPatch`, before the closing `.strict()` at line 119)

- [ ] **Step 1: Add the schema fragment**

Inside the `ConfigPatch = z.object({ ... })`, alongside `modelPool`/`voice`, add:
```ts
    // 盲盒:revealMode='disclose' 直接显示真名不让猜;regenReroll 控制手动 regen 是否重抽。
    blindBox: z
      .object({
        revealMode: z.enum(['surprise', 'disclose']).optional(),
        regenReroll: z.boolean().optional(),
      })
      .optional(),
```

- [ ] **Step 2: Typecheck**

```bash
bun --filter='@pendingbot/edge' run typecheck
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/edge/src/routes/bots.ts
git commit -m "edge: accept config.blindBox in bot PATCH

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 3 — Edge: conversation model endpoints

### Task 3.1: New conversations route file with reveal + switch + state endpoints

**Files:**
- Create: `apps/edge/src/routes/conversation-model-routes.ts`
- Modify: `apps/edge/src/index.ts` (add import + mount under `/conversations`)
- Modify: `apps/edge/src/lib/conversation-model.ts` (export a `rerollConversationModel` helper used by both this route and Phase 4)

- [ ] **Step 1: Add a model-state writer helper to `conversation-model.ts`**

These helpers centralise the `model_revealed` lifecycle so the route + regenerate agree. Add to `apps/edge/src/lib/conversation-model.ts`:
```ts
import { pickRandomModel } from '../llm/random-model';
import { serviceClient } from './supabase';
import { deleteCachedConv } from './conv-cache';
import type { AppBindings } from '../types';

type Env = AppBindings['Bindings'];

export interface ConvModelStateRow {
  current_model_slug: string | null;
  current_model_provider: string | null;
  model_revealed: boolean;
}

export async function readConvModelStateRow(
  env: Env,
  conversationId: string,
): Promise<ConvModelStateRow | null> {
  const { data } = await serviceClient(env)
    .from('conversations')
    .select('current_model_slug, current_model_provider, model_revealed')
    .eq('id', conversationId)
    .maybeSingle();
  if (!data) return null;
  return {
    current_model_slug: (data.current_model_slug ?? null) as string | null,
    current_model_provider: (data.current_model_provider ?? null) as string | null,
    model_revealed: Boolean(data.model_revealed),
  };
}

/** Set the conversation model + reveal flag, busting the conv cache. */
export async function writeConvModel(
  env: Env,
  conversationId: string,
  patch: { slug: string; provider: string | null; revealed: boolean },
): Promise<void> {
  const { error } = await serviceClient(env)
    .from('conversations')
    .update({
      current_model_slug: patch.slug,
      current_model_provider: patch.provider,
      model_revealed: patch.revealed,
    })
    .eq('id', conversationId);
  if (error) throw new Error(error.message);
  await deleteCachedConv(env, conversationId).catch(() => undefined);
}

/** Just flip the reveal flag (used by reveal-model). Busts cache. */
export async function markConvRevealed(env: Env, conversationId: string): Promise<void> {
  const { error } = await serviceClient(env)
    .from('conversations')
    .update({ model_revealed: true })
    .eq('id', conversationId);
  if (error) throw new Error(error.message);
  await deleteCachedConv(env, conversationId).catch(() => undefined);
}

/**
 * Re-draw the conversation main model from the bot pool, excluding the
 * current one, persist it, and reset reveal=false. Returns the chosen
 * {slug, provider}, or null if the bot has no pool (nothing to re-roll —
 * caller keeps the current model).
 */
export async function rerollConversationModel(
  env: Env,
  conversationId: string,
  bot: BotModelSelectionInput,
  currentSlug: string | null,
): Promise<{ slug: string; provider: string | null } | null> {
  const cfg = modelPoolConfigFromBotConfig(bot.config);
  if (!cfg) return null;
  const picked = await pickRandomModel(env, cfg, {
    excludeSlugs: currentSlug ? [currentSlug] : [],
  });
  if (!picked) return null;
  const provider = picked.modelProvider ?? 'openrouter';
  await writeConvModel(env, conversationId, { slug: picked.slug, provider, revealed: false });
  return { slug: picked.slug, provider };
}
```

> Verify the import paths (`./supabase`, `./conv-cache`, `../types`, `../llm/random-model`) resolve from `lib/conversation-model.ts` — they're all siblings/parents already used elsewhere in `lib/`.

- [ ] **Step 2: Create the route file**

`apps/edge/src/routes/conversation-model-routes.ts`:
```ts
import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { resolveConv } from '../lib/conv-cache';
import { resolveBot } from '../lib/bot-cache'; // adjust to actual resolveBot location
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import {
  parseBlindBoxConfig,
  readConvModelStateRow,
  markConvRevealed,
  writeConvModel,
  rerollConversationModel,
  modelPoolConfigFromBotConfig,
} from '../lib/conversation-model';
import type { AppBindings } from '../types';

// Per-conversation blind-box model surface.
//   GET  /v1/conversations/:id/model          — current model + reveal + bot blindBox settings
//   POST /v1/conversations/:id/reveal-model    — guess / give up → reveal
//   POST /v1/conversations/:id/model           — switch (specific | random)

export const conversationModelRoutes = new Hono<AppBindings>();
conversationModelRoutes.use('*', requireSession());

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface ConvWithBot {
  conversation_id: string;
  bot: { model_id: string; model_provider: string | null; config: unknown } | null;
}

// Resolve conv membership + the bot behind it (for pool + blindBox config).
async function loadConvBot(
  c: Parameters<Parameters<typeof conversationModelRoutes.get>[1]>[0],
  conversationId: string,
): Promise<ConvWithBot | null> {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);
  const conv = await resolveConv(c.env, supaUser, conversationId, userId, (p) =>
    safeWaitUntil(c, p),
  ).catch(() => null);
  if (!conv) return null;
  const botId = (conv as { bot_id: string | null }).bot_id;
  if (!botId) return { conversation_id: conversationId, bot: null };
  const bot = await resolveBot(c.env, serviceClient(c.env), botId, (p) => safeWaitUntil(c, p));
  return {
    conversation_id: conversationId,
    bot: bot
      ? { model_id: bot.model_id, model_provider: bot.model_provider, config: bot.config }
      : null,
  };
}

conversationModelRoutes.get('/:id/model', async (c) => {
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  const cb = await loadConvBot(c, id);
  if (!cb) return jsonError(c, 404, 'conversation_no_access');
  const state = await readConvModelStateRow(c.env, id);
  if (!state) return jsonError(c, 404, 'not_found');
  const bb = parseBlindBoxConfig(cb.bot?.config);
  const hasPool = cb.bot ? modelPoolConfigFromBotConfig(cb.bot.config) !== null : false;
  // disclose mode → always treated as revealed for display.
  const revealed = bb.revealMode === 'disclose' ? true : state.model_revealed;
  return c.json({
    current_model_slug: state.current_model_slug,
    current_model_provider: state.current_model_provider,
    model_revealed: revealed,
    reveal_mode: bb.revealMode,
    regen_reroll: bb.regenReroll,
    has_pool: hasPool,
  });
});

const RevealBody = z.object({ guess: z.string().min(1).max(200).nullable().optional() });

conversationModelRoutes.post('/:id/reveal-model', async (c) => {
  const userId = c.var.userId!;
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  let parsed: z.infer<typeof RevealBody>;
  try {
    parsed = RevealBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const cb = await loadConvBot(c, id);
  if (!cb) return jsonError(c, 404, 'conversation_no_access');
  const state = await readConvModelStateRow(c.env, id);
  if (!state || !state.current_model_slug) {
    return jsonError(c, 404, 'not_found', { message: '该会话还没有抽定模型' });
  }
  const guess = parsed.guess ?? null;
  const correct = guess === null ? null : guess === state.current_model_slug;

  // Persist the guess record + flip reveal (idempotent: re-reveal just logs again).
  const supa = serviceClient(c.env);
  await supa.from('model_guesses').insert({
    conversation_id: id,
    user_id: userId,
    actual_slug: state.current_model_slug,
    actual_provider: state.current_model_provider,
    guessed_slug: guess,
    correct,
  });
  await markConvRevealed(c.env, id).catch((e: Error) =>
    jsonError(c, 500, 'database_error', { detail: e.message }),
  );

  return c.json({
    actual_slug: state.current_model_slug,
    actual_provider: state.current_model_provider,
    correct,
  });
});

const SwitchBody = z.discriminatedUnion('mode', [
  z.object({ mode: z.literal('specific'), slug: z.string().min(1).max(200), provider: z.string().max(100).nullable().optional() }),
  z.object({ mode: z.literal('random') }),
]);

conversationModelRoutes.post('/:id/model', async (c) => {
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  let parsed: z.infer<typeof SwitchBody>;
  try {
    parsed = SwitchBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const cb = await loadConvBot(c, id);
  if (!cb) return jsonError(c, 404, 'conversation_no_access');
  const state = await readConvModelStateRow(c.env, id);
  if (!state) return jsonError(c, 404, 'not_found');

  if (parsed.mode === 'specific') {
    // Self-chosen model → revealed (you know what you picked).
    await writeConvModel(c.env, id, {
      slug: parsed.slug,
      provider: parsed.provider ?? 'openrouter',
      revealed: true,
    });
    return c.json({ current_model_slug: parsed.slug, current_model_provider: parsed.provider ?? 'openrouter', model_revealed: true });
  }

  // random → re-roll from pool, reset reveal.
  if (!cb.bot) return jsonError(c, 400, 'conversation_has_no_bot');
  const rolled = await rerollConversationModel(c.env, id, cb.bot, state.current_model_slug);
  if (!rolled) return jsonError(c, 400, 'no_model_pool', { message: '该机器人没有配置模型池,无法随机' });
  return c.json({ current_model_slug: rolled.slug, current_model_provider: rolled.provider, model_revealed: false });
});
```

> **Resolve `resolveBot`'s real import.** The recon shows `resolveBot(c.env, supaService, botId, waitUntil)` used in `messages.ts`. Find its export (`grep -rn "export.*function resolveBot\|export const resolveBot" apps/edge/src`) and fix the import line. Same for `bot.config`/`bot.model_id`/`bot.model_provider` field names on the resolved bot.

- [ ] **Step 3: Mount in `index.ts`**

Add near the other `/conversations` mounts (after `conversationListRoutes`):
```ts
import { conversationModelRoutes } from './routes/conversation-model-routes';
// ...
v1.route('/conversations', conversationModelRoutes);
```

- [ ] **Step 4: Typecheck**

```bash
bun --filter='@pendingbot/edge' run typecheck
```
Expected: PASS. Fix any import/field-name mismatches surfaced (esp. `resolveBot`, conv `bot_id`).

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/routes/conversation-model-routes.ts apps/edge/src/lib/conversation-model.ts apps/edge/src/index.ts
git commit -m "edge: per-conversation model endpoints — GET state, reveal-model, switch (specific/random)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 4 — Edge: regenerate re-rolls the conversation model

### Task 4.1: Regenerate re-draws + persists the main model (gated by regenReroll)

**Files:**
- Modify: `apps/edge/src/routes/messages.ts` (regenerate handler ~898-1074 and `resolveMessageBotTurnRoute` ~1621-1700)

Current behavior: regenerate uses `candidateOnly: true` → `chooseCandidateModel` (a throwaway candidate, NOT persisted, NOT a re-roll of the conversation model). New behavior: regenerate **re-rolls the conversation main model and persists it** (reset reveal) when the bot's `blindBox.regenReroll` is true; otherwise keeps the current model.

- [ ] **Step 1: Replace the candidate logic in the regenerate handler**

In the regenerate handler, find:
```ts
  const turnRoute = await resolveMessageBotTurnRoute(
    c.env,
    {
      model_id: bot.model_id,
      model_provider: bot.model_provider,
      config: bot.config,
    },
    { candidateOnly: true },
  );
```
Replace with:
```ts
  const blindBox = parseBlindBoxConfig(bot.config);
  let turnRoute: { modelId: string; providerOverride: string | null };
  if (blindBox.regenReroll) {
    // 盲盒:手动重抽 → 重新抽主模型并持久化,reveal 重置;新模型此后成为会话模型。
    const current = await readConvModelStateRow(c.env, parsed.conversationId);
    const rolled = await rerollConversationModel(
      c.env,
      parsed.conversationId,
      { model_id: bot.model_id, model_provider: bot.model_provider, config: bot.config },
      current?.current_model_slug ?? null,
    );
    turnRoute = rolled
      ? { modelId: rolled.slug, providerOverride: rolled.provider }
      // No pool → keep current (or bot default) and don't reset reveal.
      : await resolveMessageBotTurnRoute(
          c.env,
          { model_id: bot.model_id, model_provider: bot.model_provider, config: bot.config, conversationId: parsed.conversationId },
        );
  } else {
    // 保持当前会话模型(不重抽,不动 reveal)。
    turnRoute = await resolveMessageBotTurnRoute(
      c.env,
      { model_id: bot.model_id, model_provider: bot.model_provider, config: bot.config, conversationId: parsed.conversationId },
    );
  }
```

- [ ] **Step 2: Add imports**

At the top of `messages.ts`, extend the `conversation-model` import to include `parseBlindBoxConfig`, `readConvModelStateRow`, `rerollConversationModel` (alongside the existing `chooseCandidateModel`, `chooseConversationMainModel`).

- [ ] **Step 3: Remove now-dead `chooseCandidateModel` usage if fully unused**

```bash
grep -rn "chooseCandidateModel\|candidateOnly" apps/edge/src
```
If `chooseCandidateModel` and the `candidateOnly` branch are now unused, delete them from `conversation-model.ts` and the `resolveMessageBotTurnRoute` `opts?.candidateOnly` branch (and the test for it in `conversation-model.test.ts`). If still referenced elsewhere, leave them.

- [ ] **Step 4: Typecheck**

```bash
bun --filter='@pendingbot/edge' run typecheck
```
Expected: PASS.

- [ ] **Step 5: Run edge tests**

```bash
cd apps/edge && ./node_modules/.bin/vitest run
```
Expected: PASS (the `parseBlindBoxConfig` tests; updated/removed candidate tests).

- [ ] **Step 6: Commit**

```bash
git add apps/edge/src/routes/messages.ts apps/edge/src/lib/conversation-model.ts apps/edge/src/lib/conversation-model.test.ts
git commit -m "edge: regenerate re-rolls + persists the conversation model (gated by blindBox.regenReroll)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 5 — Edge: `prompt_model_guess` tool

### Task 5.1: `emitGuessPrompt` closure on ToolCtx + the tool

**Files:**
- Modify: `apps/edge/src/lib/bot-reply/tool-runner.ts` (ToolCtx interface + runTool dispatch)
- Modify: `apps/edge/src/lib/bot-reply/index.ts` (build the `emitGuessPrompt` closure, pass into ctx)
- Modify: `apps/edge/src/lib/bot-reply/tool-defs.ts` (append the tool object to `CHAT_TOOLS`)
- Create: `apps/edge/src/lib/bot-reply/tools/prompt-model-guess.ts`

- [ ] **Step 1: Add `emitGuessPrompt` to `ToolCtx`**

In `tool-runner.ts`, add to the `ToolCtx` interface (after `emitImagesMessage`):
```ts
  /// Insert a `log_kind='guess_prompt'` message — the blind-box "猜一猜"
  /// interactive card. Returns true if the row landed. Closure in
  /// runChatTurn so the tool needn't know conversation/parent plumbing.
  emitGuessPrompt: () => Promise<boolean>;
```

- [ ] **Step 2: Implement the closure in `index.ts`**

Next to `emitImagesMessage` (around line 689), add:
```ts
  const emitGuessPrompt = async (): Promise<boolean> => {
    const { error } = await supa.from('messages').insert({
      id: randomUUID(),
      client_message_id: randomUUID(),
      conversation_id: conversationId,
      sender_bot_id: bot.id,
      role: 'log',
      log_kind: 'guess_prompt',
      log_payload: {},
      status: 'done',
      content: '',
      parent_message_id: parentMessageId,
    });
    if (error) {
      console.warn('[bot-reply] guess-prompt insert', error.message);
      return false;
    }
    return true;
  };
```
Then add `emitGuessPrompt,` to the `ToolCtx` object literal where `emitImagesMessage` is passed in.

> Confirm `messages` accepts `role: 'log'` + `log_kind` (the recon shows `log_kind` exists and `role` enum includes `'log'`). Check how existing `log_kind` rows (e.g. permission_request) are inserted in this file or in `request-permission.ts` and mirror their column set exactly (esp. whether `log_payload` is required).

- [ ] **Step 3: Create the tool impl**

`apps/edge/src/lib/bot-reply/tools/prompt-model-guess.ts`:
```ts
import type { Env } from '../../../types';
import type { ToolCtx } from '../tool-runner';

// Terminal-ish tool: pop a "猜一猜" card into the chat. No model-visible
// result beyond ok/failed. The card itself drives the reveal via
// POST /v1/conversations/:id/reveal-model on the client.
export async function promptModelGuessTool(
  _env: Env,
  _args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  ctx.emit('tool_call', { name: 'prompt_model_guess' });
  const ok = await ctx.emitGuessPrompt();
  ctx.emit('tool_result', { name: 'prompt_model_guess', ok });
  return JSON.stringify(ok ? { ok: true } : { ok: false, error: 'insert failed' });
}
```

- [ ] **Step 4: Wire the dispatch in `runTool`**

In `tool-runner.ts`, add the import (with the other tool imports) and a branch in the if-chain:
```ts
import { promptModelGuessTool } from './tools/prompt-model-guess';
// ...
    if (name === 'prompt_model_guess') {
      return await promptModelGuessTool(env, args, ctx);
    }
```

- [ ] **Step 5: Add the tool definition**

Append to `CHAT_TOOLS` in `tool-defs.ts`:
```ts
  {
    type: 'function',
    function: {
      name: 'prompt_model_guess',
      // Blind-box "guess which model" card. No args. Description lives in
      // pendingbot.tools.model_description (seeded by the model_blindbox
      // migration) and is swapped in by applyToolRegistry.
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
```

- [ ] **Step 6: Typecheck**

```bash
bun --filter='@pendingbot/edge' run typecheck
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/edge/src/lib/bot-reply/tool-runner.ts apps/edge/src/lib/bot-reply/index.ts apps/edge/src/lib/bot-reply/tool-defs.ts apps/edge/src/lib/bot-reply/tools/prompt-model-guess.ts
git commit -m "edge: prompt_model_guess tool — inserts guess_prompt card

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 6 — iOS teardown (delete arena UI)

### Task 6.1: Delete arena structs, compare card, leaderboard

**Files:**
- Modify: `apps/pendingbot/Sources/Models/APIModels.swift` (delete lines 307-325: `ArenaStanding`/`ArenaLeaderboard`/`ArenaCompareResult`; KEEP `RandomModelConfig` 298-305)
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView.swift` (delete arena MARK 2478-2824, render block 600-617, 再生成 menu item 542-553 will be re-added in Phase 8, `@State var arenaCollapsed` line 250, `var arenaGroups` 1049-1075, variant-hiding filter in `displayedMessages` ~1037-1042)
- Modify: `apps/pendingbot/Sources/Features/Me/MeTabView.swift` (delete NavigationLink 180-187, `ArenaLeaderboardView` 428-531)

- [ ] **Step 1: Delete the arena structs in `APIModels.swift`**

Remove `ArenaStanding`, `ArenaLeaderboard`, `ArenaCompareResult` (lines 307-325). Leave `RandomModelConfig`.

- [ ] **Step 2: Delete the leaderboard in `MeTabView.swift`**

Remove the `NavigationLink { ArenaLeaderboardView()... } label: { OptionRow(title: "猜你喜欢") }` block (180-187, plus stray divider) and the entire `ArenaLeaderboardView` (428-531).

- [ ] **Step 3: Delete the compare card + arena plumbing in `ConversationView.swift`**

Delete:
- The whole `// MARK: - Arena inline blind compare` section (2478-2824): `arenaParentId`, `regenerateArenaAnswer`, `ArenaVariant`, `ArenaCompareCard`.
- The render block that instantiates `ArenaCompareCard` (600-617).
- The 再生成 context-menu item (542-553) — **will be re-added in Phase 8** as a plain "重新生成" that re-rolls. For now delete it.
- `@State var arenaCollapsed` (250), `var arenaGroups` (1049-1075).
- In `displayedMessages` (~1031-1044) remove the filter that hides arena variant bubbles, so any multi-answer variants now render as normal sequential bot bubbles.

- [ ] **Step 4: Grep for stragglers**

```bash
grep -rn "Arena\|arena\|leaderboard\|model_comparisons\|/compare" apps/pendingbot/Sources | grep -v "ArenaModelSelection\|ArenaModelPickerSheet\|ArenaModelPoolEditor\|arenaSelection\|arenaConfig\|arenaConfigDict"
```
Expected: empties out except the kept pool-editor names (`ArenaModelSelection`, `ArenaModelPickerSheet`, `ArenaModelPoolEditor`, `arenaSelection`, `arenaConfig`). Remove anything else live.

- [ ] **Step 5: Build (iOS)**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add apps/pendingbot/Sources/Models/APIModels.swift apps/pendingbot/Sources/Features/Me/MeTabView.swift apps/pendingbot/Sources/Features/Message/ConversationView.swift
git commit -m "ios: remove arena A/B compare card + leaderboard

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 7 — iOS: conversation model state + PendingModel pill

### Task 7.1: API models + client for conversation model state

**Files:**
- Modify: `apps/pendingbot/Sources/Models/APIModels.swift` (add `ConvModelState`, `RevealResult`)
- Modify: `apps/pendingbot/Sources/Networking/` (use existing `APIClient` — no new file needed)

- [ ] **Step 1: Add response models**

In `APIModels.swift`:
```swift
struct ConvModelState: Codable, Equatable {
    let current_model_slug: String?
    let current_model_provider: String?
    let model_revealed: Bool
    let reveal_mode: String      // "surprise" | "disclose"
    let regen_reroll: Bool
    let has_pool: Bool
}

struct RevealResult: Codable {
    let actual_slug: String
    let actual_provider: String?
    let correct: Bool?           // nil = gave up
}
```

- [ ] **Step 2: Build**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add apps/pendingbot/Sources/Models/APIModels.swift
git commit -m "ios: ConvModelState + RevealResult response models

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 7.2: Fetch + hold conversation model state; repoint the pill

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView.swift` (add `@State var convModelState: ConvModelState?`, fetch on appear + after reveal/switch/regen, repoint `botName`)

- [ ] **Step 1: Add state + fetch**

Add near the other `@State` (around 120-164):
```swift
@State var convModelState: ConvModelState? = nil
```
Add a fetch method (new extension or near loading code):
```swift
extension ConversationView {
    func loadConvModelState() async {
        guard conversation.conversation_type != "user_user" else { return }
        guard let api else { return }
        do {
            let s: ConvModelState = try await api.get("v1/conversations/\(conversation.id)/model")
            await MainActor.run { self.convModelState = s }
        } catch {
            // non-fatal: pill falls back to bot model name
        }
    }
}
```
Call it from `.task`/`onAppear` where history loads, and after any reveal/switch/regen completes.

- [ ] **Step 2: Repoint the pill (`botName`)**

Change `botName` (307-314) so the model segment reflects the conversation's drawn model + reveal state:
```swift
private var botName: String {
    let base = effectiveBot?.display_name ?? conversation.bot_name ?? conversation.bot_id
    guard conversation.conversation_type != "user_user" else { return base }
    let modelTag: String?
    if let s = convModelState {
        if s.reveal_mode == "disclose" || s.model_revealed {
            modelTag = s.current_model_slug.map { modelCatalog.displayName(for: $0) }
        } else {
            modelTag = "PendingModel"   // 盲盒未揭示
        }
    } else {
        // 未取到会话状态 → 回落 bot 模型(老行为)
        modelTag = effectiveBot?.model.flatMap { $0.isEmpty ? nil : modelCatalog.displayName(for: $0) }
    }
    guard let tag = modelTag else { return base }
    return "\(base) · \(tag)"
}
```

- [ ] **Step 3: Build**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Features/Message/ConversationView.swift
git commit -m "ios: conversation model state drives PendingModel pill

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 8 — iOS: `+` menu entries + guess/switch sheets

### Task 8.1: ChatActionSheet — add 猜模型 / 换模型 tiles

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Message/ChatActionSheet.swift` (add `onGuessModel`/`onSwitchModel` optional closures + tiles)
- Modify: `apps/pendingbot/Sources/Features/Message/ComposerView.swift` (pass the closures, ~183-194)
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView.swift` (own the sheet presentation state + wire closures into ComposerView)

- [ ] **Step 1: Add optional closures + tiles to `ChatActionSheet`**

Mirror the existing optional `onLookback` pattern (27-30, 71-80). Add params:
```swift
var onGuessModel: (() -> Void)? = nil
var onSwitchModel: (() -> Void)? = nil
```
In the tile `HStack`, add (conditionally, like `onLookback`):
```swift
if let onGuessModel {
    Button { onGuessModel(); onDismiss() } label: {
        actionTileLabel(icon: "questionmark.app", label: "猜模型")
    }
}
if let onSwitchModel {
    Button { onSwitchModel(); onDismiss() } label: {
        actionTileLabel(icon: "cube.transparent", label: "换模型")
    }
}
```

- [ ] **Step 2: Pass closures from `ComposerView`**

`ComposerView` needs to forward two optional closures to `ChatActionSheet`. Add `var onGuessModel: (() -> Void)? = nil` and `var onSwitchModel: (() -> Void)? = nil` to `ComposerView` and pass them through at the `ChatActionSheet(...)` call (183-194).

- [ ] **Step 3: Wire from `ConversationView`**

Where `ConversationView` constructs `ComposerView`, pass:
```swift
onGuessModel: shouldOfferGuess ? { showGuessSheet = true } : nil,
onSwitchModel: { showSwitchSheet = true },
```
with new `@State var showGuessSheet = false`, `@State var showSwitchSheet = false`, and:
```swift
private var shouldOfferGuess: Bool {
    guard let s = convModelState else { return false }
    return s.has_pool && s.reveal_mode == "surprise" && !s.model_revealed
}
```

- [ ] **Step 4: Build**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED (sheets are wired in 8.2/8.3; for now `showGuessSheet`/`showSwitchSheet` may be unused — add `.sheet` stubs or do 8.2/8.3 before building).

- [ ] **Step 5: Commit**

```bash
git add apps/pendingbot/Sources/Features/Message/ChatActionSheet.swift apps/pendingbot/Sources/Features/Message/ComposerView.swift apps/pendingbot/Sources/Features/Message/ConversationView.swift
git commit -m "ios: + menu adds 猜模型/换模型 entries

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 8.2: Guess sheet

**Files:**
- Create: `apps/pendingbot/Sources/Features/Message/GuessModelSheet.swift`
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView.swift` (`.sheet(isPresented: $showGuessSheet)`)

- [ ] **Step 1: Build the sheet**

`GuessModelSheet.swift` — reuse `ModelPickerSheet`'s catalog list to pick a slug, plus a "不想猜(直接揭晓)" button. On pick or give-up, call the reveal endpoint and report the result.
```swift
import SwiftUI

struct GuessModelSheet: View {
    let conversationId: String
    var onRevealed: (RevealResult) -> Void   // parent refreshes pill + shows result

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var submitting = false
    @State private var result: RevealResult?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    resultView(result)
                } else {
                    // Reuse the catalog picker; selecting a slug submits a guess.
                    ModelPickerSheet(initial: "", showLegend: false, onPick: { picked in
                        guard let slug = picked?.slug else { return }
                        Task { await submit(guess: slug) }
                    })
                }
            }
            .navigationTitle("猜猜是哪个模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("不想猜,直接揭晓") { Task { await submit(guess: nil) } }
                        .disabled(submitting)
                }
            }
        }
    }

    @ViewBuilder private func resultView(_ r: RevealResult) -> some View {
        VStack(spacing: 16) {
            let actual = catalog.displayName(for: r.actual_slug)
            if r.correct == true {
                Text("🎉 猜对了!就是 \(actual)")
            } else if r.correct == false {
                Text("差一点!实际是 \(actual)")
            } else {
                Text("揭晓:\(actual)")
            }
            Button("好") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func submit(guess: String?) async {
        guard !submitting else { return }
        submitting = true; defer { submitting = false }
        struct Body: Encodable { let guess: String? }
        do {
            let r: RevealResult = try await APIClient().post(
                "v1/conversations/\(conversationId)/reveal-model", body: Body(guess: guess))
            await MainActor.run { self.result = r; onRevealed(r) }
            Haptics.success()
        } catch {
            Haptics.error()
        }
    }
}
```
> Verify `ModelPickerSheet`'s init signature (`initial:showLegend:onPick:`) from `ModelPicker.swift:6-53` usage; adjust if `showLegend`/labels differ.

- [ ] **Step 2: Present from `ConversationView`**

```swift
.sheet(isPresented: $showGuessSheet) {
    GuessModelSheet(conversationId: conversation.id) { _ in
        Task { await loadConvModelState() }   // refresh pill
    }
    .environmentObject(modelCatalog)
}
```

- [ ] **Step 3: Build**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Features/Message/GuessModelSheet.swift apps/pendingbot/Sources/Features/Message/ConversationView.swift
git commit -m "ios: guess-model sheet (guess / give up → reveal)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 8.3: Switch sheet (specific / random) + 重新生成 re-roll

**Files:**
- Create: `apps/pendingbot/Sources/Features/Message/SwitchModelSheet.swift`
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView.swift` (`.sheet(isPresented: $showSwitchSheet)` + re-add the 再生成 context-menu item as plain regenerate)

- [ ] **Step 1: Build the switch sheet**

Two actions: pick a specific model (→ `mode:'specific'`, becomes revealed) or "随机换一个" (→ `mode:'random'`, becomes PendingModel). Reuse `ModelPickerSheet` for the specific pick; a button for random.
```swift
import SwiftUI

struct SwitchModelSheet: View {
    let conversationId: String
    let hasPool: Bool
    var onSwitched: (ConvModelState) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ModelPickerSheet(initial: "", showLegend: false, onPick: { picked in
                guard let p = picked else { return }
                Task { await switchSpecific(slug: p.slug, provider: p.model_provider) }
            })
            .navigationTitle("换模型")
            .toolbar {
                if hasPool {
                    ToolbarItem(placement: .primaryAction) {
                        Button("随机换一个") { Task { await switchRandom() } }.disabled(busy)
                    }
                }
            }
        }
    }

    private func switchSpecific(slug: String, provider: String?) async {
        await call(SpecificBody(mode: "specific", slug: slug, provider: provider))
    }
    private func switchRandom() async { await call(RandomBody(mode: "random")) }

    private struct SpecificBody: Encodable { let mode: String; let slug: String; let provider: String? }
    private struct RandomBody: Encodable { let mode: String }

    private func call<B: Encodable>(_ body: B) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let s: ConvModelState = try await APIClient().post(
                "v1/conversations/\(conversationId)/model", body: body)
            await MainActor.run { onSwitched(s); dismiss() }
            Haptics.success()
        } catch { Haptics.error() }
    }
}
```
> The POST response is the `{current_model_slug, current_model_provider, model_revealed}` subset; decode into a small struct or reuse `ConvModelState` with the missing fields optional. Simplest: define a dedicated `ConvModelSwitchResult: Codable` with just those 3 fields and have `onSwitched` trigger a full `loadConvModelState()` refresh instead of trusting the partial. **Recommended:** make `onSwitched` a `() -> Void` that calls `loadConvModelState()`, and decode the POST into a throwaway struct.

- [ ] **Step 2: Present + re-add regenerate**

```swift
.sheet(isPresented: $showSwitchSheet) {
    SwitchModelSheet(conversationId: conversation.id,
                     hasPool: convModelState?.has_pool ?? false) { _ in
        Task { await loadConvModelState() }
    }
    .environmentObject(modelCatalog)
}
```
Re-add a context-menu "重新生成" item (where 542-553 was) that POSTs the regenerate SSE stream to `v1/messages/\(parentId)/regenerate` (the same call `regenerateArenaAnswer` made at 2532, minus the arena framing), then calls `await loadConvModelState()` when the stream finishes (the model may have re-rolled). Keep it simple: one regenerated answer appended; pill refreshes.

- [ ] **Step 3: Build**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apps/pendingbot/Sources/Features/Message/SwitchModelSheet.swift apps/pendingbot/Sources/Features/Message/ConversationView.swift
git commit -m "ios: switch-model sheet (specific/random) + plain regenerate

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 9 — iOS: `guess_prompt` interactive card

### Task 9.1: Render the tool-emitted guess card

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView+Loading.swift` (dispatch `log_kind == "guess_prompt"` → populate a `guessPromptMsgIds: Set<String>`)
- Modify: `apps/pendingbot/Sources/Features/Message/ConversationView.swift` (state + render block in the message loop)
- Create: `apps/pendingbot/Sources/Features/Message/GuessPromptCard.swift`

- [ ] **Step 1: Collect guess_prompt log rows**

In `loadHistory` (`ConversationView+Loading.swift`), mirror the `permission_request` dispatch: when a `MessageRow` has `role == "log"` and `log_kind == "guess_prompt"`, record its message id. Add `@State var guessPromptMsgIds: Set<String> = []` to `ConversationView` and populate it from loadHistory (and from the SSE path if a guess card can arrive live — the tool emits it as a DB row, so it arrives via the next history/realtime refresh; a `loadConvModelState()` + history refresh after `tool_result name==prompt_model_guess` is sufficient).

- [ ] **Step 2: Render the card in the message loop**

Where `log_kind` cards render (mirror the permission_request render site), add:
```swift
if guessPromptMsgIds.contains(msg.id) {
    GuessPromptCard(
        conversationId: conversation.id,
        revealed: (convModelState?.model_revealed ?? false) || (convModelState?.reveal_mode == "disclose"),
        revealedName: convModelState?.current_model_slug.map { modelCatalog.displayName(for: $0) },
        onTapGuess: { showGuessSheet = true }
    )
    .id("guess:\(msg.id)")
}
```

- [ ] **Step 3: Build the card**

`GuessPromptCard.swift`:
```swift
import SwiftUI

struct GuessPromptCard: View {
    let conversationId: String
    let revealed: Bool
    let revealedName: String?
    var onTapGuess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(revealed ? "已揭晓" : "🎁 猜猜我背后是哪个模型?")
                .font(Theme.Fonts.rounded(size: 14, weight: .semibold))
            if revealed, let name = revealedName {
                Text(name).foregroundStyle(Theme.Palette.accent)
            } else if !revealed {
                Button(action: onTapGuess) { Text("来猜一猜") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceMuted))
        .padding(.horizontal)
    }
}
```

- [ ] **Step 4: Build**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add apps/pendingbot/Sources/Features/Message/GuessPromptCard.swift apps/pendingbot/Sources/Features/Message/ConversationView.swift apps/pendingbot/Sources/Features/Message/ConversationView+Loading.swift
git commit -m "ios: render guess_prompt interactive card

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 10 — iOS: bot settings (revealMode / regenReroll)

### Task 10.1: Add the two toggles to `BotConfigView`

**Files:**
- Modify: `apps/pendingbot/Sources/Features/Friends/BotManagement.swift` (`BotConfigView`: `@State` + `Snapshot` + `applyConfig` + `save` cfg dict + UI)

- [ ] **Step 1: Add state + snapshot fields**

In `BotConfigView` (state block ~1157-1200): add
```swift
@State private var revealMode: String = "surprise"   // "surprise" | "disclose"
@State private var regenReroll: Bool = true
```
Add both to the `Snapshot: Equatable` struct (1189-1201) and to `private var snapshot` (1220-1229).

- [ ] **Step 2: Parse in `applyConfig`**

In `applyConfig` (1529-1558), mirror the `lookback.enabled` bool pattern:
```swift
if case let .object(bb)? = dict["blindBox"] {
    if case let .string(s)? = bb["revealMode"], s == "disclose" || s == "surprise" { revealMode = s }
    if case let .bool(b)? = bb["regenReroll"] { regenReroll = b }
}
```

- [ ] **Step 3: Serialize in `save`**

In `save()` cfg dict (~1614-1633), add:
```swift
"blindBox": [
    "revealMode": revealMode,
    "regenReroll": regenReroll,
] as [String: Any],
```

- [ ] **Step 4: Add the UI controls**

In the `body` form, near the model-pool section, add:
```swift
Section {
    Picker("模型身份", selection: $revealMode) {
        Text("保留惊喜(让用户猜)").tag("surprise")
        Text("直接披露(显示真名)").tag("disclose")
    }
    Toggle("重新生成时重抽模型", isOn: $regenReroll)
} header: {
    Text("盲盒")
} footer: {
    Text("保留惊喜:对话里模型名显示为 PendingModel,用户可以猜。直接披露:始终显示真实模型,不让猜。重抽:点重新生成时换一个新模型(否则保持当前)。")
        .font(Theme.Fonts.caption)
}
```
> If `revealMode`/`regenReroll` should only be editable when the bot has a model pool, gate the Section on `arenaConfig != nil`.

- [ ] **Step 5: Build (iOS + macOS — BotConfigView is cross-platform)**

```bash
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
cd apps/pendingbot && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED for both.

- [ ] **Step 6: Commit**

```bash
git add apps/pendingbot/Sources/Features/Friends/BotManagement.swift
git commit -m "ios: bot settings — blindBox revealMode + regenReroll toggles

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 11 — Verification & ledgers

### Task 11.1: Full verification sweep

- [ ] **Step 1: Edge typecheck + tests**

```bash
bun --filter='@pendingbot/edge' run typecheck
cd apps/edge && ./node_modules/.bin/vitest run
```
Expected: both PASS.

- [ ] **Step 2: iOS + iPad + macOS builds**

```bash
cd apps/pendingbot
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'generic/platform=iOS Simulator' build
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Simulator smoke (per memory: verify the real path, not just compile)**

Install in a simulator (Xcode GUI build for a signed session, per the project's keychain note) and walk:
1. New conversation with a pool-bot (surprise mode) → pill shows `PendingModel`.
2. `+` → 猜模型 → pick a model → see ✓/✗ result → pill flips to real name (conversation-wide).
3. `+` → 换模型 → 随机换一个 → pill back to `PendingModel`.
4. `+` → 换模型 → pick specific → pill shows that model immediately (no guess).
5. 重新生成 (regenReroll on) → new answer, pill back to `PendingModel`.
6. Bot with disclose mode → pill always real name, no 猜模型 entry.
7. (If reachable) a turn where the bot calls `prompt_model_guess` → guess card appears and is tappable.

Record any gaps in `docs/tech-debt.md` (e.g. live-arrival of the guess card if it only appears after refresh).

- [ ] **Step 4: Update ledgers**

- Mark the blind-box tasks in the Task system as `completed` (only those verified).
- Update `docs/progress.md` top "最近对账" date + a blind-box rollup line.
- If anything was deferred (e.g. guess card live-refresh, persisted-guess-record display on reload), log it in `docs/tech-debt.md`.

- [ ] **Step 5: Commit ledger updates**

```bash
git add docs/progress.md docs/tech-debt.md
git commit -m "docs: blind box progress + tech-debt rollup

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Spec coverage check

| Spec requirement | Task |
|---|---|
| Hide model as `PendingModel` until guessed | 7.2 (pill), 0.1 (`model_revealed`) |
| `+` → 猜模型 → reveal (with 不想猜) | 8.1, 8.2, 3.1 (reveal endpoint) |
| LLM tool pops guess UI | 5.1 (tool), 9.1 (card) |
| `+` → 直接换当前会话模型 | 8.1, 8.3, 3.1 (switch endpoint) |
| Bot setting surprise/disclose | 10.1, 2.2 (zod), 3.1 (GET reflects disclose) |
| Model fixed per conversation (cache) | (preserved — `chooseConversationMainModel` untouched) |
| Re-roll only on regen/switch | 4.1 (regen), 3.1 (switch), 0.1 (reveal lifecycle) |
| regen reroll bot-configurable | 10.1, 2.1 (`regenReroll`), 4.1 |
| Persist guess records | 0.1 (`model_guesses`), 3.1 (insert) |
| Reveal scope = whole conversation | 7.2 (single conversation-level pill) |
| Delete A/B compare + leaderboard + Bradley-Terry | 1.1 (edge), 6.1 (ios) |

## Open implementation notes (resolve during execution, not blockers)

- **`resolveBot` import + bot field names** (Task 3.1) — confirm from `messages.ts` usage.
- **`pendingbot.tools` PK** (Task 0.1) — confirm the `ON CONFLICT` target column.
- **`log_kind` insert column set** (Task 5.1) — mirror the existing `permission_request` log-row insert exactly.
- **Persisted guess display on reload** — v1 shows the result at guess time + the reveal flag persists; rendering the historical "you guessed X" line from `model_guesses` on reload is a nice-to-have. If skipped, log in tech-debt.
- **Guess card live arrival** — the tool inserts a DB row; the card may only appear after a history/realtime refresh. Trigger a refresh on `tool_result name==prompt_model_guess`; if imperfect, log in tech-debt.
