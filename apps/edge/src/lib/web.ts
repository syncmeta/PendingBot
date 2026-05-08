import type { Env } from '../types';
import type { WebSearchResult, WebReadResult } from './web-types';

// Web tools used by bot-reply (in-chat search / read) and scroll-runner
// (奏折 article research). Two providers, picked to mirror what the user's
// design sandbox in PendingBot/surf-test settled on:
//
//   Brave Search       — https://api.search.brave.com/res/v1/web/search
//   Firecrawl scrape   — https://api.firecrawl.dev/v1/scrape  (formats: markdown)
//
// Both expect API keys via secrets — see types.ts (BRAVE_API_KEY /
// FIRECRAWL_API_KEY). The shapes here are deliberately small so the agent
// loop's prompt format stays stable across provider swaps. Result types
// re-exported below for back-compat with existing callers.

export type { WebSearchResult, WebReadResult } from './web-types';

export async function braveSearch(
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

export async function firecrawlScrape(
  env: Env,
  pageUrl: string,
  signal?: AbortSignal,
): Promise<WebReadResult> {
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

// ── Envelope runner: selectable providers ─────────────────────────────
// The Envelope (来信) feature exposes a per-conversation choice of search
// and scrape provider. We mirror what scroll-lab settled on so behavior
// matches the lab harness end-to-end. Brave + Firecrawl are the defaults
// and the only providers in-chat search/read uses; the rest are opt-in
// via conversation settings and only surface keys-missing errors when
// actually invoked.

export type SearchProvider = 'brave' | 'tavily' | 'exa' | 'serper';
export type ScrapeProvider = 'firecrawl' | 'tavily' | 'exa';

export const DEFAULT_SEARCH_PROVIDER: SearchProvider = 'brave';
export const DEFAULT_SCRAPE_PROVIDER: ScrapeProvider = 'firecrawl';

export async function tavilySearch(
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

export async function exaSearch(
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

export async function serperSearch(
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

export async function tavilyScrape(
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

export async function exaScrape(
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

// Dispatchers — pick the implementation by provider id. The agent loop
// passes only the query / url string, so we close over `env` here.
export function makeSearch(
  env: Env,
  provider: SearchProvider,
): (query: string) => Promise<WebSearchResult[]> {
  switch (provider) {
    case 'brave':  return (q) => braveSearch(env, q);
    case 'tavily': return (q) => tavilySearch(env, q);
    case 'exa':    return (q) => exaSearch(env, q);
    case 'serper': return (q) => serperSearch(env, q);
  }
}

export function makeScrape(
  env: Env,
  provider: ScrapeProvider,
): (url: string) => Promise<WebReadResult> {
  switch (provider) {
    case 'firecrawl': return (u) => firecrawlScrape(env, u);
    case 'tavily':    return (u) => tavilyScrape(env, u);
    case 'exa':       return (u) => exaScrape(env, u);
  }
}
