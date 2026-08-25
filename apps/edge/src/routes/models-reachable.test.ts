// 模型目录必须只装「这个账号真调得通的模型」。
//
// 病根（Todo #15）：目录一直是从 OpenRouter **不带钥匙**的公开接口拉的 ——
// 那是整个平台的菜单（实测 419 个），跟我们账号够不够得着无关。账号的隐私 /
// 数据政策要到**真正发请求那一刻**才生效。于是池子机器人开局可能抽到一个
// 本账号永远调不通的模型，用户拿到一句 404。
//
// 带钥匙的 `GET /api/v1/models/user` 返回的才是「按本账号的供应商偏好、隐私
// 设置和 guardrail 过滤后」的清单。
//
// 这里钉住的重点不是「过滤生效」，而是**每一条退化路径都必须出声**：
// 静默用一个残缺或未过滤的池子，就是把这个 bug 原样埋回去。

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildModelCatalog, UNFILTERED_CATALOG_MARKER } from './models';

const PUBLIC_URL = 'https://openrouter.ai/api/v1/models';
const USER_URL = 'https://openrouter.ai/api/v1/models/user';

/// 20 non-native slugs — big enough that the "implausibly small" floor
/// (half the catalogue) has room on both sides of it.
const PUBLIC_SLUGS = Array.from({ length: 20 }, (_, i) => `vendor${i}/model-${i}`);

function catalogRow(id: string) {
  return {
    id,
    name: `Model ${id}`,
    context_length: 128000,
    created: 1_700_000_000,
    pricing: { prompt: '0.000001', completion: '0.000002' },
    architecture: { input_modalities: ['text'] },
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// Stub both catalogue endpoints. `userResponse` is what
/// /api/v1/models/user replies with (or a thrower).
function stubFetch(userResponse?: () => Response | Promise<Response>) {
  const calls: string[] = [];
  vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
    const url = String(input);
    calls.push(url);
    if (url.startsWith(PUBLIC_URL) && !url.startsWith(USER_URL)) {
      return jsonResponse({ data: PUBLIC_SLUGS.map(catalogRow) });
    }
    if (url.startsWith(USER_URL)) {
      if (!userResponse) throw new Error('unexpected call to /models/user');
      return await userResponse();
    }
    // LMArena rows are passed in directly by these tests; nothing else
    // should be reached.
    throw new Error(`unexpected fetch: ${url}`);
  });
  return calls;
}

function slugsOf(rows: Array<{ slug: string; source: string }>) {
  return rows.filter((r) => r.source === 'openrouter').map((r) => r.slug);
}

describe('buildModelCatalog — reachable-model filter', () => {
  let warn: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'log').mockImplementation(() => {});
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function markerCalls() {
    return warn.mock.calls.filter((c) => c[0] === UNFILTERED_CATALOG_MARKER);
  }

  it('keeps only what the account can reach', async () => {
    const reachable = PUBLIC_SLUGS.slice(0, 15);
    stubFetch(() =>
      jsonResponse({ data: reachable.map((id) => ({ id })), total_count: 15, links: { next: null } }),
    );

    const rows = await buildModelCatalog({}, 'sk-or-test');

    expect(slugsOf(rows).sort()).toEqual([...reachable].sort());
    // Nothing degraded — no marker.
    expect(markerCalls()).toHaveLength(0);
  });

  it('without a key, falls back to the whole menu AND says so', async () => {
    stubFetch();

    const rows = await buildModelCatalog({}, undefined);

    expect(slugsOf(rows).sort()).toEqual([...PUBLIC_SLUGS].sort());
    const marker = markerCalls();
    expect(marker).toHaveLength(1);
    expect(String(marker[0]![1])).toContain('no_catalog_key');
  });

  it('a rejected key falls back loudly rather than emptying the catalogue', async () => {
    stubFetch(() => jsonResponse({ error: 'Unauthorized' }, 401));

    const rows = await buildModelCatalog({}, 'sk-or-revoked');

    expect(slugsOf(rows).sort()).toEqual([...PUBLIC_SLUGS].sort());
    expect(String(markerCalls()[0]![1])).toContain('upstream_not_ok');
  });

  it('follows links.next across pages', async () => {
    // Live shape (2026-08-25): { data: [...], total_count, links: { next } }.
    // All 416 rows came back on one page, but next is the documented
    // paging handle — reading only page one is exactly the silent
    // pool-shrink this whole change exists to prevent.
    const PAGE_2 = 'https://openrouter.ai/api/v1/models/user?offset=10';
    let served = 0;
    vi.stubGlobal('fetch', async (input: RequestInfo | URL) => {
      const url = String(input);
      if (!url.startsWith(USER_URL)) {
        return jsonResponse({ data: PUBLIC_SLUGS.map(catalogRow) });
      }
      served += 1;
      return url === PAGE_2
        ? jsonResponse({
            data: PUBLIC_SLUGS.slice(10).map((id) => ({ id })),
            links: { next: null },
          })
        : jsonResponse({
            data: PUBLIC_SLUGS.slice(0, 10).map((id) => ({ id })),
            links: { next: PAGE_2 },
          });
    });

    const rows = await buildModelCatalog({}, 'sk-or-test');

    expect(served).toBe(2);
    // Both pages kept — page one alone (10 of 20) would have tripped the
    // truncation floor and fallen back instead.
    expect(slugsOf(rows).sort()).toEqual([...PUBLIC_SLUGS].sort());
    expect(markerCalls()).toHaveLength(0);
  });

  it('an unexpected response shape falls back loudly — we do not guess', async () => {
    // Anything that is not a plain `data` array must degrade, not be
    // interpreted.
    stubFetch(() => jsonResponse({ models: PUBLIC_SLUGS.map((id) => ({ id })) }));

    const rows = await buildModelCatalog({}, 'sk-or-test');

    expect(slugsOf(rows).sort()).toEqual([...PUBLIC_SLUGS].sort());
    expect(String(markerCalls()[0]![1])).toContain('unexpected_shape');
  });

  it('an implausibly small list is treated as truncation, not as policy', async () => {
    // What "we only read page one" looks like. Silently shrinking the
    // pool is the exact failure this change exists to prevent.
    stubFetch(() => jsonResponse({ data: PUBLIC_SLUGS.slice(0, 3).map((id) => ({ id })) }));

    const rows = await buildModelCatalog({}, 'sk-or-test');

    expect(slugsOf(rows).sort()).toEqual([...PUBLIC_SLUGS].sort());
    const detail = String(markerCalls()[0]![1]);
    expect(detail).toContain('implausibly_small');
    expect(detail).toContain('"kept_count":3');
  });

  it('an empty list falls back — never an empty catalogue', async () => {
    stubFetch(() => jsonResponse({ data: [] }));

    const rows = await buildModelCatalog({}, 'sk-or-test');

    expect(slugsOf(rows)).toHaveLength(PUBLIC_SLUGS.length);
    expect(String(markerCalls()[0]![1])).toContain('empty_list');
  });

  it('a network failure on the authenticated call cannot break the catalogue', async () => {
    stubFetch(() => {
      throw new Error('econnreset');
    });

    const rows = await buildModelCatalog({}, 'sk-or-test');

    expect(slugsOf(rows)).toHaveLength(PUBLIC_SLUGS.length);
    expect(String(markerCalls()[0]![1])).toContain('fetch_threw');
  });

  it('sends the key as a bearer, and only to the models/user endpoint', async () => {
    const seen: Array<{ url: string; auth: string | null }> = [];
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const auth = new Headers(init?.headers).get('Authorization');
      seen.push({ url, auth });
      if (url.startsWith(USER_URL)) {
        return jsonResponse({ data: PUBLIC_SLUGS.map((id) => ({ id })) });
      }
      return jsonResponse({ data: PUBLIC_SLUGS.map(catalogRow) });
    });

    await buildModelCatalog({}, 'sk-or-secret');

    const pub = seen.find((s) => !s.url.startsWith(USER_URL))!;
    const authed = seen.find((s) => s.url.startsWith(USER_URL))!;
    // The public catalogue call must stay anonymous — no reason to show
    // the key to a request that does not need it.
    expect(pub.auth).toBeNull();
    expect(authed.auth).toBe('Bearer sk-or-secret');
  });
});
