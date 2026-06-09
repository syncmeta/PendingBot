# Board 功能开关（feature flags）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Billing / PostHog / Langfuse 三个服务开关从"部署时 env 常量"升级成"board 上运行时可切",机制为 **KV 覆盖 ?? env 默认**;Sentry 因 `withSentry` 同步 init 约束 + kill-switch 零依赖原则,保持 env-only,在 board 页只读展示。

**Architecture:** `env.MEMORY` KV 存一个覆盖 blob `cfg:feature-flags`(JSON `{billing?,posthog?,langfuse?}`)。`feature-flags.ts` 的三个 getter 改异步:`override ?? (env.X==='true')`,带 isolate-local 60s TTL 缓存(避免每次热路径读 KV),KV 失败静默回退 env(绝不抛)。board 端点 `GET/PUT /v1/board/feature-flags` 读/写该 KV blob + 落 admin_audit。前端 board 加「功能开关」页:3 个可切 + Sentry 只读行。

**Tech Stack:** Hono · Cloudflare KV(`env.MEMORY`)· Zod · vitest(fake KV)· Refine v5 + Ant Design。

**设计依据 / 边界**:
- Sentry **不**上 board 切:`withSentry` 的 options 回调签名是 `(env)=>CloudflareOptions|undefined`(同步,不收 Promise),KV 异步读塞不进;且 Sentry 作错误捕获器,开关必须零运行时依赖。board 页给它只读行 + "改这个要重部署"说明。
- 为什么 KV 当源而非现成 `kvConfig`:`kvConfig` miss 时回退查 Supabase,会给 kill-switch 重新引入 DB 依赖。这里要 **KV 当源 + env 当唯一兜底**,方向相反,所以单写一个读取器。
- 传播延迟:board PUT 写 KV 后,worker 端 ≤60s(isolate TTL)+ KV 全球传播(秒级)生效。对 pre-launch 开关够用,不加显式 cache-bust。

依赖:本计划基于 `feat/board-console`(board 框架 + `boardResource` + `recordBoardAudit` 已落地)。

---

## File Structure

**Edge**
- Modify `apps/edge/src/lib/feature-flags.ts` — 加 KV 覆盖读取器 + isolate TTL 缓存;billing/posthog/langfuse 改 async(`override ?? env`);sentry 保持 sync env-only。
- Modify(9 个消费点,加 `await`):`lib/billing.ts:206`、`lib/billing-grant.ts:110`、`billing/usage-gate.ts:118`、`billing/group-wallet.ts:498`、`billing/wallet-client.ts:53`、`routes/me.ts:370`(billing×6);`lib/analytics.ts:42`(posthog×1);`lib/llm-trace.ts:58`、`lib/llm-trace.ts:135`(langfuse×2)。
- Create `apps/edge/src/routes/board-feature-flags.ts` — `GET`/`PUT /v1/board/feature-flags`(singleton KV blob,非 boardResource)。
- Modify `apps/edge/src/routes/board.ts` — 挂 `boardRoutes.route('/feature-flags', boardFeatureFlagsRoutes)`。
- Create `apps/edge/tests/board-feature-flags.test.ts` — 读取器 override/env/KV-fail + 端点 GET/PUT+audit + 门禁。
- Modify `apps/edge/tests/_helpers/fake-supabase.ts` 的 `makeFakeEnv` **仅当**它现在没给 `MEMORY` KV 一个可用 fake 时才补(先查;若已有 KV fake 就不动)。

**前端 `apps/admin`**
- Create `apps/admin/src/pages/feature-flags.tsx` — 单例配置页(非 Refine resource):3 个 antd Switch(billing/posthog/langfuse,显示 effective + 是否被 override + env 默认)+ Sentry 只读行;读 `GET`、写 `PUT`,走 `edgeFetch`(`providers/http.ts`)。
- Modify `apps/admin/src/App.tsx` — 加一条非资源路由 `/feature-flags` + 侧栏入口。

**约定**:GET 返回 `{ data: {...} }`;PUT 返回 `{ data: {...更新后...} }`;门禁复用 `boardRoutes` 已挂的 `requireSession + requireAdmin`(子路由自动继承)。

---

## Task 1: feature-flags.ts —— KV 覆盖 ?? env 默认 + 缓存

**Files:**
- Modify: `apps/edge/src/lib/feature-flags.ts`
- Test: `apps/edge/tests/board-feature-flags.test.ts`(本任务建文件,测读取器)

- [ ] **Step 1: 先确认 fake KV**

读 `apps/edge/tests/_helpers/fake-supabase.ts` 的 `makeFakeEnv`,确认它返回的 env 里 `MEMORY` 是个可 `.get/.put` 的 fake KV。若不是(或没有),给它补一个最小内存 KV(`get(key,'json')` 返回存的对象、`put(key,val)` 存下),供本套测试用。若已有则不动。

- [ ] **Step 2: 重写 feature-flags.ts**

```ts
// apps/edge/src/lib/feature-flags.ts
//
// 运行时 kill-switch。两种源,合成规则:override ?? env 默认。
//   - env 变量(wrangler.jsonc vars):部署时烧入,同步、不可失败 → 永远是兜底地板。
//   - KV 覆盖(env.MEMORY 的 cfg:feature-flags):board 运行时写,可切,KV 失败则回退 env。
// Sentry 例外:保持纯 env(同步),见下方注释。
import type { Env } from '../types';

const FLAGS_KV_KEY = 'cfg:feature-flags';
const FLAGS_TTL_MS = 60_000;

// board 可切的三个开关(Sentry 不在内 —— 见文件尾)。
export type ToggleableFlag = 'billing' | 'posthog' | 'langfuse';
export type FlagOverrides = Partial<Record<ToggleableFlag, boolean>>;

// isolate-local 缓存:避免billing门禁/每事件/每代际在热路径上每次读 KV。
// 缓存覆盖 blob;过期或冷启动读一次 KV。KV 失败 → 沿用上次缓存或空(=回退 env)。
let cache: { at: number; v: FlagOverrides } | null = null;

// 测试可调:注入"现在时间"避免依赖 Date.now()(本仓库部分环境禁用)。
async function loadOverrides(env: Env, now: number): Promise<FlagOverrides> {
  if (cache && now - cache.at < FLAGS_TTL_MS) return cache.v;
  try {
    const v = (await env.MEMORY.get<FlagOverrides>(FLAGS_KV_KEY, 'json')) ?? {};
    cache = { at: now, v };
    return v;
  } catch {
    // KV 读失败:用上次缓存,否则空(→ 全部回退 env 默认)。绝不抛。
    return cache?.v ?? {};
  }
}

// 仅测试用:重置 isolate 缓存。
export function __resetFlagCacheForTest(): void {
  cache = null;
}

async function flagValue(env: Env, name: ToggleableFlag, envVal: string | undefined, now: number): Promise<boolean> {
  const ov = await loadOverrides(env, now);
  if (typeof ov[name] === 'boolean') return ov[name] as boolean;
  return envVal === 'true';
}

/** Billing gate + debit。override ?? env。默认 false。 */
export function billingEnabled(env: Env, now: number = nowMs()): Promise<boolean> {
  return flagValue(env, 'billing', env.BILLING_ENABLED, now);
}

/** PostHog 产品分析。override ?? env。 */
export function posthogEnabled(env: Env, now: number = nowMs()): Promise<boolean> {
  return flagValue(env, 'posthog', env.POSTHOG_ENABLED, now);
}

/** Langfuse LLM tracing。override ?? env。 */
export function langfuseEnabled(env: Env, now: number = nowMs()): Promise<boolean> {
  return flagValue(env, 'langfuse', env.LANGFUSE_ENABLED, now);
}

// Sentry 例外:保持同步纯 env。原因:
//   1. withSentry 的 options 回调是同步签名 (env)=>CloudflareOptions|undefined,
//      容不下异步 KV 读;
//   2. 错误捕获器的 kill-switch 必须零运行时依赖,不能让它依赖 KV/DB ——
//      否则一次边缘存储抽风会顺手静音它。
// 改 Sentry 开关 = 改 wrangler.jsonc vars + 重部署。board 页只读展示。
export function sentryEnabled(env: Env): boolean {
  return env.SENTRY_ENABLED === 'true';
}

// Date.now() 在本仓库部分环境被禁(会破坏 resume)。这里用一个可注入的薄封装:
// 默认走 Date.now();测试传入固定值。生产读 KV 缓存对"现在"精度无要求(60s 量级)。
function nowMs(): number {
  return Date.now();
}
```

> 注:若 `Date.now()` 在 edge 运行环境/测试里被禁用(本仓库 workflow 脚本里禁,但 worker 运行时通常可用),实现时先确认。若 worker 运行时 `Date.now()` 可用(几乎肯定可用,只有 workflow 脚本禁),保留上述写法;测试里调用方传入固定 `now` 即可绕开。若连 worker 也禁,改用 `cache` 的存在性 + 一次性读(去掉 TTL,改为 board PUT 时主动 bust)——但这是下策,先验证。

- [ ] **Step 3: 写读取器测试(测文件开头 + 3 个用例)**

```ts
// apps/edge/tests/board-feature-flags.test.ts
import { afterEach, describe, expect, it } from 'vitest';
import {
  billingEnabled,
  posthogEnabled,
  __resetFlagCacheForTest,
} from '../src/lib/feature-flags';
import type { Env } from '../src/types';

afterEach(() => __resetFlagCacheForTest());

// 最小 env：env 默认 + 可控 MEMORY KV。
function envWith(opts: { billingEnv?: string; kv?: Record<string, unknown>; kvThrows?: boolean }): Env {
  const store = opts.kv ?? {};
  return {
    BILLING_ENABLED: opts.billingEnv,
    POSTHOG_ENABLED: undefined,
    LANGFUSE_ENABLED: undefined,
    MEMORY: {
      get: async (key: string, _type?: string) => {
        if (opts.kvThrows) throw new Error('kv down');
        return store[key] ?? null;
      },
      put: async () => {},
    },
  } as unknown as Env;
}

describe('feature flag: KV override ?? env default', () => {
  it('uses env default when no KV override', async () => {
    const env = envWith({ billingEnv: 'true', kv: {} });
    expect(await billingEnabled(env, 1)).toBe(true);
  });

  it('KV override wins over env default', async () => {
    const env = envWith({ billingEnv: 'true', kv: { 'cfg:feature-flags': { billing: false } } });
    expect(await billingEnabled(env, 1)).toBe(false);  // override false 压过 env true
  });

  it('falls back to env when KV read throws (never blocks)', async () => {
    const env = envWith({ billingEnv: 'true', kvThrows: true });
    expect(await billingEnabled(env, 1)).toBe(true);  // KV 挂 → 回退 env true
    expect(await posthogEnabled(env, 1)).toBe(false); // env undefined → false
  });
});
```

- [ ] **Step 4: 跑读取器测试**

Run: `cd apps/edge && ./node_modules/.bin/vitest run tests/board-feature-flags.test.ts`
Expected: 3 个用例 PASS。（端点测试本任务还没加,Task 3 追加。）

- [ ] **Step 5: 提交**

```bash
git add apps/edge/src/lib/feature-flags.ts apps/edge/tests/board-feature-flags.test.ts apps/edge/tests/_helpers/fake-supabase.ts
git commit -m "edge(flags): KV override ?? env default for billing/posthog/langfuse (async)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: 转换 9 个消费点为 await

**Files(逐个改）:** `lib/billing.ts:206`、`lib/billing-grant.ts:110`、`billing/usage-gate.ts:118`、`billing/group-wallet.ts:498`、`billing/wallet-client.ts:53`、`routes/me.ts:370`、`lib/analytics.ts:42`、`lib/llm-trace.ts:58`、`lib/llm-trace.ts:135`

机械转换规则(对每个站点):
1. 把 `billingEnabled(env)` / `posthogEnabled(env)` / `langfuseEnabled(env)`(现在返回 `Promise<boolean>`)改成 `await billingEnabled(env)` 等。
2. 确认所在函数是 `async`。本仓库这些站点都在做 DB/网络的 async 函数里,理应已是 async;若发现某个调用方是同步函数,把它改 async 并向上传播 `await`(typecheck 会逼出所有遗漏)。
3. **不要碰 `sentryEnabled`**(`index.ts:224`)—— 它仍是同步。

- [ ] **Step 1: 逐站点加 await + 确保 async**

读每个文件的对应行,按上面规则改。`wallet-client.ts:53` 注意:若它在一个对象字面量/同步求值里(不是函数体顶部 guard),需要把那段逻辑挪进 async 或预先 await 出一个布尔再用。以真实代码为准。

- [ ] **Step 2: typecheck —— 用类型系统兜出所有遗漏的 await**

Run: `bun --filter='@pendingbot/edge' run typecheck`
Expected: 0 error。若报 "Promise<boolean> not assignable to boolean" 或 "await has no effect" 类错误,说明某站点漏改/改错 —— 按提示补,直到 0。

- [ ] **Step 3: 全量 vitest**

Run: `cd apps/edge && ./node_modules/.bin/vitest run`
Expected: 既有全套 + 新套全绿(540+ passed)。billing / analytics / llm-trace 相关既有测试若因 `billingEnabled` 变 async 而失败(它们可能 mock 了同步返回),按新签名修测试 mock(返回 Promise),不要改弱断言。

- [ ] **Step 4: 提交**

```bash
git add apps/edge/src/lib/billing.ts apps/edge/src/lib/billing-grant.ts apps/edge/src/billing/usage-gate.ts apps/edge/src/billing/group-wallet.ts apps/edge/src/billing/wallet-client.ts apps/edge/src/routes/me.ts apps/edge/src/lib/analytics.ts apps/edge/src/lib/llm-trace.ts
# 若改了既有测试也一并 add
git commit -m "edge(flags): await async billing/posthog/langfuse flag reads at all call sites

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: board 端点 GET/PUT /v1/board/feature-flags

**Files:**
- Create: `apps/edge/src/routes/board-feature-flags.ts`
- Modify: `apps/edge/src/routes/board.ts`(挂子路由)
- Test: `apps/edge/tests/board-feature-flags.test.ts`(追加端点用例)

- [ ] **Step 1: 写 board-feature-flags.ts**

```ts
// apps/edge/src/routes/board-feature-flags.ts
//
// 功能开关的 board 端点(单例 KV blob,非表行,故不走 boardResource)。
//   GET  /v1/board/feature-flags  → 每个开关的 {override, envDefault, effective}
//   PUT  /v1/board/feature-flags  → 写 cfg:feature-flags 覆盖 + admin_audit
// Sentry 只读(envDefault/effective),不接受 PUT 改。
import { Hono } from 'hono';
import { z } from 'zod';
import { jsonError } from '../lib/http-error';
import { recordBoardAudit } from '../lib/board-audit';
import type { AppBindings } from '../types';
import type { FlagOverrides } from '../lib/feature-flags';

export const boardFeatureFlagsRoutes = new Hono<AppBindings>();
const KEY = 'cfg:feature-flags';

async function readOverrides(env: AppBindings['Bindings']): Promise<FlagOverrides> {
  try {
    return (await env.MEMORY.get<FlagOverrides>(KEY, 'json')) ?? {};
  } catch {
    return {};
  }
}

function envDefault(v: string | undefined): boolean {
  return v === 'true';
}

boardFeatureFlagsRoutes.get('/', async (c) => {
  const ov = await readOverrides(c.env);
  const row = (name: 'billing' | 'posthog' | 'langfuse', env: string | undefined) => {
    const d = envDefault(env);
    const override = typeof ov[name] === 'boolean' ? (ov[name] as boolean) : null;
    return { override, envDefault: d, effective: override ?? d };
  };
  return c.json({
    data: {
      billing: row('billing', c.env.BILLING_ENABLED),
      posthog: row('posthog', c.env.POSTHOG_ENABLED),
      langfuse: row('langfuse', c.env.LANGFUSE_ENABLED),
      // Sentry 只读:无 override 概念,改它要重部署。
      sentry: { override: null, envDefault: envDefault(c.env.SENTRY_ENABLED), effective: envDefault(c.env.SENTRY_ENABLED), readonly: true },
    },
  });
});

// PUT body:每个键可为 boolean(设覆盖)或 null(清覆盖→回退 env)。缺省=不动。
const PutBody = z.object({
  billing: z.boolean().nullable().optional(),
  posthog: z.boolean().nullable().optional(),
  langfuse: z.boolean().nullable().optional(),
});

boardFeatureFlagsRoutes.put('/', async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = PutBody.safeParse(body);
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });

  const before = await readOverrides(c.env);
  const next: FlagOverrides = { ...before };
  for (const k of ['billing', 'posthog', 'langfuse'] as const) {
    const v = parsed.data[k];
    if (v === undefined) continue;       // 没传 = 不动
    if (v === null) delete next[k];       // null = 清覆盖
    else next[k] = v;                     // boolean = 设覆盖
  }
  try {
    await c.env.MEMORY.put(KEY, JSON.stringify(next));
  } catch (err) {
    return jsonError(c, 500, 'database_error', { detail: String(err) });
  }
  await recordBoardAudit(c, {
    action: 'update',
    targetKind: 'feature_flags',
    targetId: KEY,
    before,
    after: next,
  });
  return c.json({ data: next });
});
```

> 注:`AppBindings['Bindings']` 取 env 类型;若该写法不被工具链接受,用 `import type { Env }` 并 `env: Env`。以真实类型为准。

- [ ] **Step 2: 在 board.ts 挂子路由**

`apps/edge/src/routes/board.ts` 顶部 import:
```ts
import { boardFeatureFlagsRoutes } from './board-feature-flags';
```
在 preset-bots 那行附近加:
```ts
boardRoutes.route('/feature-flags', boardFeatureFlagsRoutes);
```
(`boardRoutes` 顶部已 `use('*', requireSession())` + `use('*', requireAdmin(isBoardAdmin))`,子路由自动继承门禁。)

- [ ] **Step 3: 追加端点测试**

在 `apps/edge/tests/board-feature-flags.test.ts` 追加一个 describe,复用 board 套件已有的 identity mock + fake env 模式(参照 `tests/board-preset-bots.test.ts` 的 `vi.mock('@pendingbot/identity')` + `appFor` + `makeFakeEnv`,把 boardFeatureFlagsRoutes 挂在 `/v1/board/feature-flags`)。用例:
- GET 返回 4 个键,每个含 override/envDefault/effective;sentry.readonly=true。
- 非 admin → 403(经 board 根门禁)。
- PUT `{billing:false}` → KV 写入 `{billing:false}` + admin_audit(action:update, target_kind:'feature_flags')落一条。
- PUT `{billing:null}` → 清掉 billing 覆盖(KV 写入不含 billing 键)。
- PUT 非法 body(如 `{billing:"yes"}`)→ 400 invalid_body。

> 由于本端点直接读 `c.env.MEMORY`(不经 supabase fake),测试的 fake env 要给 MEMORY 一个内存 KV(Task 1 Step 1 已确保)。audit 落库经 `recordBoardAudit` → supabase fake 的 `admin_audit` insert,断言用 `db.inserts.filter(i=>i.table==='admin_audit')`。

- [ ] **Step 4: 跑测 + typecheck + 全量**

Run:
```
cd apps/edge && ./node_modules/.bin/vitest run tests/board-feature-flags.test.ts
bun --filter='@pendingbot/edge' run typecheck
cd apps/edge && ./node_modules/.bin/vitest run
```
Expected: 新套全绿;typecheck 0;全量全绿。

- [ ] **Step 5: 提交**

```bash
git add apps/edge/src/routes/board-feature-flags.ts apps/edge/src/routes/board.ts apps/edge/tests/board-feature-flags.test.ts
git commit -m "edge(board): GET/PUT /v1/board/feature-flags singleton + audit

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: 前端 board 功能开关页

**Files:**
- Create: `apps/admin/src/pages/feature-flags.tsx`
- Modify: `apps/admin/src/App.tsx`(加 `/feature-flags` 路由 + 侧栏入口)

- [ ] **Step 1: 写 feature-flags.tsx**

单例配置页(非 Refine CRUD resource)。用 `edgeFetch`(`../providers/http`)直接 GET/PUT,antd 渲染。要点:
- 进页 `GET feature-flags`,渲染 billing/posthog/langfuse 三行,每行:`Switch`(绑 effective)+ 小字标注「env 默认: on/off」+ 若 override≠null 标「已覆盖」。
- Sentry 行:`Switch` `disabled` + tooltip「改 Sentry 需改 env 并重部署(错误捕获器开关必须零运行时依赖)」。
- 切某个 Switch → `PUT { [name]: 新值 }` → 成功后用返回值刷新本地状态 + antd message 提示「已更新,数秒内全球生效」。
- 加一个「恢复为 env 默认」按钮/每行一个清除图标 → `PUT { [name]: null }`。

```tsx
// apps/admin/src/pages/feature-flags.tsx
import { useEffect, useState } from 'react';
import { Card, Switch, Typography, Space, Button, App as AntdApp, Spin, Tooltip } from 'antd';
import { edgeFetch } from '../providers/http';

type FlagRow = { override: boolean | null; envDefault: boolean; effective: boolean; readonly?: boolean };
type FlagsResp = { data: Record<'billing' | 'posthog' | 'langfuse' | 'sentry', FlagRow> };

const LABELS: Record<string, string> = {
  billing: '计费(门禁+扣费)',
  posthog: 'PostHog 产品分析',
  langfuse: 'Langfuse LLM 追踪',
  sentry: 'Sentry 错误追踪',
};

export function FeatureFlagsPage() {
  const { message } = AntdApp.useApp();
  const [flags, setFlags] = useState<FlagsResp['data'] | null>(null);
  const [saving, setSaving] = useState<string | null>(null);

  const load = async () => {
    const r = await edgeFetch<FlagsResp>({ method: 'GET', path: 'board/feature-flags' });
    setFlags(r.data);
  };
  useEffect(() => { load().catch((e) => message.error(String(e))); }, []);

  const put = async (name: string, value: boolean | null) => {
    setSaving(name);
    try {
      const r = await edgeFetch<{ data: unknown }>({ method: 'PUT', path: 'board/feature-flags', body: { [name]: value } });
      await load();
      message.success('已更新,数秒内全球生效');
      void r;
    } catch (e) {
      message.error(String(e));
    } finally {
      setSaving(null);
    }
  };

  if (!flags) return <Spin />;

  const order: Array<'billing' | 'posthog' | 'langfuse' | 'sentry'> = ['billing', 'posthog', 'langfuse', 'sentry'];
  return (
    <Card title="功能开关">
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        {order.map((name) => {
          const f = flags[name];
          const ro = !!f.readonly;
          return (
            <Space key={name} align="center" style={{ justifyContent: 'space-between', width: '100%' }}>
              <Space direction="vertical" size={0}>
                <Typography.Text strong>{LABELS[name]}</Typography.Text>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  env 默认: {f.envDefault ? 'on' : 'off'}
                  {f.override !== null ? ` · 已覆盖为 ${f.effective ? 'on' : 'off'}` : ''}
                  {ro ? ' · 只读(改需重部署)' : ''}
                </Typography.Text>
              </Space>
              <Space>
                {f.override !== null && !ro && (
                  <Button size="small" type="link" loading={saving === name} onClick={() => put(name, null)}>
                    恢复 env 默认
                  </Button>
                )}
                {ro ? (
                  <Tooltip title="改 Sentry 需改 wrangler.jsonc env 并重部署:错误捕获器的开关必须零运行时依赖,不能走 KV/DB。">
                    <Switch checked={f.effective} disabled />
                  </Tooltip>
                ) : (
                  <Switch checked={f.effective} loading={saving === name} onChange={(v) => put(name, v)} />
                )}
              </Space>
            </Space>
          );
        })}
      </Space>
    </Card>
  );
}
```

- [ ] **Step 2: App.tsx 加路由 + 入口**

在 `apps/admin/src/App.tsx`:
- import:`import { FeatureFlagsPage } from './pages/feature-flags';`
- 在受保护 `<Route>` 区加:`<Route path="/feature-flags" element={<FeatureFlagsPage />} />`
- 让它出现在侧栏:在 `resources` 数组加一条**无 list/create 的纯导航项**,或用 ThemedLayout 的方式。最简做法:加一个 resource `{ name: 'feature_flags', list: '/feature-flags', meta: { label: '功能开关' } }`(list 指向该路由,点击即进页)。注意它不是 CRUD resource,但 Refine 用 list 路径做侧栏跳转没问题;dataProvider 不会被调用(页面自己 edgeFetch)。

- [ ] **Step 3: build 验证**

Run: `cd apps/admin && bun run build`
Expected: `tsc --noEmit` + `vite build` 绿。若 `AntdApp.useApp()` / message API 报错,确认 App.tsx 外层已包 `<AntdApp>`(board CMS Task 4 已包)。

- [ ] **Step 4: 提交**

```bash
git add apps/admin/src/pages/feature-flags.tsx apps/admin/src/App.tsx
git commit -m "admin(board): 功能开关页 — billing/posthog/langfuse 运行时切,sentry 只读

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: 验证 + 账本

- [ ] **Step 1: 合并后全量自验**（合并方跑,非子代理）

```
bun --filter='@pendingbot/edge' run typecheck
cd apps/edge && ./node_modules/.bin/vitest run
cd ../admin && bun run build
```
全绿。

- [ ] **Step 2: 账本**

- `docs/progress.md` 顶部加一行:功能开关上 board(billing/posthog/langfuse 运行时切,sentry env-only 只读)。
- `docs/tech-debt.md`:记一条 🟢/🟡 —— 「flag override 走 isolate 60s TTL 缓存,board 改后最长 60s + KV 传播才全节点生效;若将来需要即时,改成 PUT 时主动 bust(但 isolate 多,bust 不可靠,届时考虑 DO 或更短 TTL)」。Sentry env-only 的设计取舍也记一笔(便于将来回看为什么它不在 board)。
- 提交:`docs: board feature-flags 落地对账`。

---

## Self-Review

- **Spec 覆盖**:billing/posthog/langfuse 运行时切(Task1 读取器 + Task2 接线 + Task3 端点 + Task4 UI)✓;Sentry env-only 只读(Task3 GET 返 readonly + Task4 disabled 行)✓;KV 覆盖 ?? env 兜底 + KV 失败不阻断(Task1 测试覆盖)✓;audit 留痕(Task3 PUT)✓。
- **占位扫描**:无 TBD;读取器/端点/页面代码完整;9 个消费点列了 file:line + 机械规则 + typecheck 兜底(非"自行处理"占位 —— 是可枚举的确定转换 + 编译器强制验证)。
- **类型一致**:`FlagOverrides`/`ToggleableFlag` Task1 定义、Task3 import 一致;`billingEnabled` 等改 `Promise<boolean>` 后 Task2 全站 await;board 端点 KV key `cfg:feature-flags` 与读取器 `FLAGS_KV_KEY` 一致(实现时确保两处同值或共享常量 —— **实现注意:把 `cfg:feature-flags` 抽成 feature-flags.ts 导出的常量,board 端点 import 它,避免两处字符串漂移**)。
- **风险点(已在步骤标注)**:`Date.now()` 在 edge 运行时是否可用(Task1 Step2 注,需先验)、`wallet-client.ts:53` 是否同步上下文(Task2 Step1 注)、`AppBindings['Bindings']` 类型写法(Task3 Step1 注)。
