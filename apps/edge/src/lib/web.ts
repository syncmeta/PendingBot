import type { Env } from '../types';
import type { WebSearchResult, WebReadResult } from './web-types';
import type { WebToolMeter } from './web-meter';

// Web tools — used by bot-reply (in-chat search_web / read_url) and by
// the scroll runner (envelope web_search / fetch_url). Every external
// HTTP call to a search or scrape provider goes through one of the two
// exported entry points below, which means *every call gets metered*
// into audit_web_tool_calls + the parent audit_log row's tool_cost_usd.
// There is no public per-provider export, so a future caller cannot
// accidentally bypass metering — the only way to invoke a provider is
// runWebSearch / runWebScrape with a WebToolMeter.
//
// Pricing lives in pendingbot.web_tool_prices (DB), loaded by
// WebToolMeter.create. Adding a new provider is: drop a fetch helper
// here, add a switch case in runWebSearch / runWebScrape, insert one
// row into web_tool_prices. Billing + audit auto-apply.

export type { WebSearchResult, WebReadResult } from './web-types';

export type SearchProvider = 'brave' | 'tavily' | 'exa' | 'serper';
export type ScrapeProvider = 'firecrawl' | 'tavily' | 'exa';

export const DEFAULT_SEARCH_PROVIDER: SearchProvider = 'brave';
export const DEFAULT_SCRAPE_PROVIDER: ScrapeProvider = 'tavily';

// ── Per-provider fetch helpers (private) ───────────────────────────────
// Kept module-internal so the only way to invoke them is via the
// metered runWebSearch / runWebScrape dispatchers below.

async function braveSearch(
  env: Env,
  query: string,
  signal?: AbortSignal,
): Promise<WebSearchResult[]> {
  const u = new URL('https://api.search.brave.com/res/v1/web/search');
  u.searchParams.set('q', query);
  u.searchParams.set('count', '8');
  const res = await fetch(u, {
    headers: {
      Accept: 'application/json',
      'X-Subscription-Token': env.BRAVE_API_KEY,
    },
    signal,
  });
  if (!res.ok) {
    throw new Error(`brave search ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    web?: { results?: Array<{ url: string; title?: string; description?: string }> };
  };
  const results = json.web?.results ?? [];
  return results.map((r) => ({
    url: r.url,
    title: r.title ?? '',
    snippet: r.description ?? '',
  }));
}

async function tavilySearch(
  env: Env,
  query: string,
  signal?: AbortSignal,
): Promise<WebSearchResult[]> {
  if (!env.TAVILY_API_KEY) throw new Error('TAVILY_API_KEY missing');
  const res = await fetch('https://api.tavily.com/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      api_key: env.TAVILY_API_KEY,
      query,
      max_results: 8,
      search_depth: 'basic',
    }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`tavily search ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    results?: Array<{ url: string; title?: string; content?: string }>;
  };
  return (json.results ?? []).map((r) => ({
    url: r.url,
    title: r.title ?? '',
    snippet: r.content ?? '',
  }));
}

async function exaSearch(
  env: Env,
  query: string,
  signal?: AbortSignal,
): Promise<WebSearchResult[]> {
  if (!env.EXA_API_KEY) throw new Error('EXA_API_KEY missing');
  const res = await fetch('https://api.exa.ai/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': env.EXA_API_KEY },
    body: JSON.stringify({
      query,
      numResults: 8,
      type: 'auto',
      contents: { text: { maxCharacters: 800 } },
    }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`exa search ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    results?: Array<{ url: string; title?: string; text?: string }>;
  };
  return (json.results ?? []).map((r) => ({
    url: r.url,
    title: r.title ?? '',
    snippet: (r.text ?? '').slice(0, 500),
  }));
}

async function serperSearch(
  env: Env,
  query: string,
  signal?: AbortSignal,
): Promise<WebSearchResult[]> {
  if (!env.SERPER_API_KEY) throw new Error('SERPER_API_KEY missing');
  const res = await fetch('https://google.serper.dev/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-KEY': env.SERPER_API_KEY },
    body: JSON.stringify({ q: query, num: 8 }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`serper search ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    organic?: Array<{ title?: string; link: string; snippet?: string }>;
  };
  return (json.organic ?? []).map((r) => ({
    url: r.link,
    title: r.title ?? '',
    snippet: r.snippet ?? '',
  }));
}

async function firecrawlScrape(
  env: Env,
  pageUrl: string,
  signal?: AbortSignal,
): Promise<WebReadResult> {
  if (!env.FIRECRAWL_API_KEY) throw new Error('FIRECRAWL_API_KEY missing');
  const res = await fetch('https://api.firecrawl.dev/v1/scrape', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${env.FIRECRAWL_API_KEY}`,
    },
    body: JSON.stringify({ url: pageUrl, formats: ['markdown'] }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`firecrawl scrape ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    data?: { markdown?: string; metadata?: { title?: string; sourceURL?: string } };
  };
  const d = json.data ?? {};
  return {
    url: d.metadata?.sourceURL ?? pageUrl,
    title: d.metadata?.title ?? '',
    content: d.markdown ?? '',
  };
}

async function tavilyScrape(
  env: Env,
  pageUrl: string,
  signal?: AbortSignal,
): Promise<WebReadResult> {
  if (!env.TAVILY_API_KEY) throw new Error('TAVILY_API_KEY missing');
  const res = await fetch('https://api.tavily.com/extract', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ api_key: env.TAVILY_API_KEY, urls: [pageUrl] }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`tavily extract ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as { results?: Array<{ raw_content?: string }> };
  return { url: pageUrl, title: '', content: json.results?.[0]?.raw_content ?? '' };
}

async function exaScrape(
  env: Env,
  pageUrl: string,
  signal?: AbortSignal,
): Promise<WebReadResult> {
  if (!env.EXA_API_KEY) throw new Error('EXA_API_KEY missing');
  const res = await fetch('https://api.exa.ai/contents', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': env.EXA_API_KEY },
    body: JSON.stringify({ ids: [pageUrl], text: true }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`exa contents ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    results?: Array<{ title?: string; text?: string }>;
  };
  return {
    url: pageUrl,
    title: json.results?.[0]?.title ?? '',
    content: json.results?.[0]?.text ?? '',
  };
}

// ── Public metered entry points ─────────────────────────────────────────

/** Classify a thrown fetch error into a short stable string for audit. */
function errorClassFor(err: unknown): string {
  if (err && typeof err === 'object') {
    const e = err as { name?: string; message?: string };
    if (e.name === 'AbortError') return 'abort';
    const msg = (e.message ?? '').toLowerCase();
    if (msg.includes('etimedout') || msg.includes('timeout')) return 'timeout';
    if (msg.includes('econnreset') || msg.includes('econnrefused') || msg.includes('fetch failed')) {
      return 'network';
    }
    // HTTP status leak in our thrown messages (e.g. "brave search 429: ...")
    const httpMatch = (e.message ?? '').match(/\b(\d{3})\b/);
    if (httpMatch) {
      const code = Number(httpMatch[1]);
      if (code === 401 || code === 403) return 'auth';
      if (code === 429) return 'rate_limit';
      if (code >= 500) return 'server_error';
      if (code >= 400) return 'bad_request';
    }
    if (msg.includes('api_key missing') || msg.endsWith('missing')) return 'config';
    return e.name ?? 'unknown';
  }
  return 'unknown';
}

export interface RunWebSearchOpts {
  provider: SearchProvider;
  query: string;
  meter: WebToolMeter;
  signal?: AbortSignal;
}

/**
 * Dispatch a web search and record its outcome on the meter. Always
 * fires meter.record exactly once — on the success path with
 * `result_count`, or on the error path with the classified error before
 * re-throwing.
 */
export async function runWebSearch(
  env: Env,
  opts: RunWebSearchOpts,
): Promise<WebSearchResult[]> {
  const startedAt = Date.now();
  try {
    let results: WebSearchResult[];
    switch (opts.provider) {
      case 'brave':  results = await braveSearch(env, opts.query, opts.signal); break;
      case 'tavily': results = await tavilySearch(env, opts.query, opts.signal); break;
      case 'exa':    results = await exaSearch(env, opts.query, opts.signal); break;
      case 'serper': results = await serperSearch(env, opts.query, opts.signal); break;
    }
    opts.meter.record({
      provider: opts.provider,
      kind: 'search',
      target: opts.query,
      status: 'success',
      latencyMs: Date.now() - startedAt,
      resultCount: results.length,
    });
    return results;
  } catch (err) {
    opts.meter.record({
      provider: opts.provider,
      kind: 'search',
      target: opts.query,
      status: 'error',
      errorClass: errorClassFor(err),
      latencyMs: Date.now() - startedAt,
    });
    throw err;
  }
}

export interface RunWebScrapeOpts {
  provider: ScrapeProvider;
  url: string;
  meter: WebToolMeter;
  signal?: AbortSignal;
}

/** See runWebSearch — same contract, for the scrape/extract endpoints. */
export async function runWebScrape(
  env: Env,
  opts: RunWebScrapeOpts,
): Promise<WebReadResult> {
  const startedAt = Date.now();
  try {
    let result: WebReadResult;
    switch (opts.provider) {
      case 'firecrawl': result = await firecrawlScrape(env, opts.url, opts.signal); break;
      case 'tavily':    result = await tavilyScrape(env, opts.url, opts.signal); break;
      case 'exa':       result = await exaScrape(env, opts.url, opts.signal); break;
    }
    opts.meter.record({
      provider: opts.provider,
      kind: 'scrape',
      target: opts.url,
      status: 'success',
      latencyMs: Date.now() - startedAt,
    });
    return result;
  } catch (err) {
    opts.meter.record({
      provider: opts.provider,
      kind: 'scrape',
      target: opts.url,
      status: 'error',
      errorClass: errorClassFor(err),
      latencyMs: Date.now() - startedAt,
    });
    throw err;
  }
}
