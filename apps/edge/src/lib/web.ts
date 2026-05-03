import type { Env } from '../types';

// Web tools used by bot-reply (in-chat search / read) and scroll-runner
// (奏折 article research). Two providers, picked to mirror what the user's
// design sandbox in PendingBot/surf-test settled on:
//
//   Brave Search       — https://api.search.brave.com/res/v1/web/search
//   Firecrawl scrape   — https://api.firecrawl.dev/v1/scrape  (formats: markdown)
//
// Both expect API keys via secrets — see types.ts (BRAVE_API_KEY /
// FIRECRAWL_API_KEY). The shapes here are deliberately small so the agent
// loop's prompt format stays stable across provider swaps.

export interface WebSearchResult {
  url: string;
  title: string;
  snippet: string;
}

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

export interface WebReadResult {
  url: string;
  title: string;
  content: string; // clean markdown
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
