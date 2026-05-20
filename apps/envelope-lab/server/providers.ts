// Multi-provider search + scrape, modeled on surf-test/server/index.ts.
// All keys come from the loaded .dev.vars; provider selection is per-call.

export interface SearchHit {
  url: string;
  title: string;
  snippet: string;
}

export interface ScrapeResult {
  url: string;
  title: string;
  content: string;
}

export type SearchProvider = 'brave' | 'tavily' | 'exa' | 'serper';
export type ScrapeProvider = 'firecrawl' | 'tavily' | 'exa';

export interface ProviderKeys {
  BRAVE_API_KEY?: string;
  TAVILY_API_KEY?: string;
  EXA_API_KEY?: string;
  SERPER_API_KEY?: string;
  FIRECRAWL_API_KEY?: string;
}

async function fetchWithRetry(url: string | URL, init: RequestInit, tries = 2): Promise<Response> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, init);
      if (!r.ok && r.status >= 500 && i < tries - 1) {
        last = new Error(`upstream ${r.status}`);
        await new Promise((res) => setTimeout(res, 400 * (i + 1)));
        continue;
      }
      if (!r.ok) {
        const body = await r.text().catch(() => '');
        throw new Error(`${r.status} ${body.slice(0, 300)}`);
      }
      return r;
    } catch (e) {
      last = e;
      if (i < tries - 1) await new Promise((res) => setTimeout(res, 400 * (i + 1)));
    }
  }
  throw last;
}

export async function searchBrave(key: string, q: string): Promise<SearchHit[]> {
  const u = new URL('https://api.search.brave.com/res/v1/web/search');
  u.searchParams.set('q', q);
  u.searchParams.set('count', '8');
  const r = await fetchWithRetry(u, {
    headers: { Accept: 'application/json', 'X-Subscription-Token': key },
  });
  const j = (await r.json()) as { web?: { results?: Array<{ url: string; title?: string; description?: string }> } };
  return (j.web?.results ?? []).map((x) => ({
    url: x.url,
    title: x.title ?? '',
    snippet: x.description ?? '',
  }));
}

export async function searchTavily(key: string, q: string): Promise<SearchHit[]> {
  const r = await fetchWithRetry('https://api.tavily.com/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ api_key: key, query: q, max_results: 8, search_depth: 'basic' }),
  });
  const j = (await r.json()) as { results?: Array<{ url: string; title?: string; content?: string }> };
  return (j.results ?? []).map((x) => ({
    url: x.url,
    title: x.title ?? '',
    snippet: x.content ?? '',
  }));
}

export async function searchExa(key: string, q: string): Promise<SearchHit[]> {
  const r = await fetchWithRetry('https://api.exa.ai/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': key },
    body: JSON.stringify({
      query: q,
      numResults: 8,
      type: 'auto',
      contents: { text: { maxCharacters: 800 } },
    }),
  });
  const j = (await r.json()) as { results?: Array<{ url: string; title?: string; text?: string }> };
  return (j.results ?? []).map((x) => ({
    url: x.url,
    title: x.title ?? '',
    snippet: (x.text ?? '').slice(0, 500),
  }));
}

export async function searchSerper(key: string, q: string): Promise<SearchHit[]> {
  const r = await fetchWithRetry('https://google.serper.dev/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-KEY': key },
    body: JSON.stringify({ q, num: 8 }),
  });
  const j = (await r.json()) as { organic?: Array<{ title?: string; link: string; snippet?: string }> };
  return (j.organic ?? []).map((x) => ({
    url: x.link,
    title: x.title ?? '',
    snippet: x.snippet ?? '',
  }));
}

export function makeSearch(
  provider: SearchProvider,
  keys: ProviderKeys,
): (q: string) => Promise<SearchHit[]> {
  return async (q) => {
    if (provider === 'brave') {
      if (!keys.BRAVE_API_KEY) throw new Error('BRAVE_API_KEY missing');
      return searchBrave(keys.BRAVE_API_KEY, q);
    }
    if (provider === 'tavily') {
      if (!keys.TAVILY_API_KEY) throw new Error('TAVILY_API_KEY missing');
      return searchTavily(keys.TAVILY_API_KEY, q);
    }
    if (provider === 'exa') {
      if (!keys.EXA_API_KEY) throw new Error('EXA_API_KEY missing');
      return searchExa(keys.EXA_API_KEY, q);
    }
    if (provider === 'serper') {
      if (!keys.SERPER_API_KEY) throw new Error('SERPER_API_KEY missing');
      return searchSerper(keys.SERPER_API_KEY, q);
    }
    throw new Error(`unknown search provider: ${provider as string}`);
  };
}

export async function scrapeFirecrawl(key: string, url: string): Promise<ScrapeResult> {
  const r = await fetchWithRetry('https://api.firecrawl.dev/v1/scrape', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({ url, formats: ['markdown'] }),
  });
  const j = (await r.json()) as {
    data?: { markdown?: string; metadata?: { title?: string; sourceURL?: string } };
  };
  const d = j.data ?? {};
  return { url: d.metadata?.sourceURL ?? url, title: d.metadata?.title ?? '', content: d.markdown ?? '' };
}

export async function scrapeTavily(key: string, url: string): Promise<ScrapeResult> {
  const r = await fetchWithRetry('https://api.tavily.com/extract', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ api_key: key, urls: [url] }),
  });
  const j = (await r.json()) as { results?: Array<{ raw_content?: string }> };
  return { url, title: '', content: j.results?.[0]?.raw_content ?? '' };
}

export async function scrapeExa(key: string, url: string): Promise<ScrapeResult> {
  const r = await fetchWithRetry('https://api.exa.ai/contents', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': key },
    body: JSON.stringify({ ids: [url], text: true }),
  });
  const j = (await r.json()) as { results?: Array<{ title?: string; text?: string }> };
  return { url, title: j.results?.[0]?.title ?? '', content: j.results?.[0]?.text ?? '' };
}

export function makeScrape(
  provider: ScrapeProvider,
  keys: ProviderKeys,
): (url: string) => Promise<ScrapeResult> {
  return async (url) => {
    if (provider === 'firecrawl') {
      if (!keys.FIRECRAWL_API_KEY) throw new Error('FIRECRAWL_API_KEY missing');
      return scrapeFirecrawl(keys.FIRECRAWL_API_KEY, url);
    }
    if (provider === 'tavily') {
      if (!keys.TAVILY_API_KEY) throw new Error('TAVILY_API_KEY missing');
      return scrapeTavily(keys.TAVILY_API_KEY, url);
    }
    if (provider === 'exa') {
      if (!keys.EXA_API_KEY) throw new Error('EXA_API_KEY missing');
      return scrapeExa(keys.EXA_API_KEY, url);
    }
    throw new Error(`unknown scrape provider: ${provider as string}`);
  };
}
