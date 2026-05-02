import type { Env } from '../types';

// Jina is the surf agent's eyes:
//   s.jina.ai/?q=<query>  → web search; returns ranked URL+title+snippet entries
//   r.jina.ai/<url>       → "Reader" — fetches the page and yields clean LLM-friendly markdown
//
// Both endpoints accept `Authorization: Bearer ${JINA_API_KEY}`. Asking for
// `Accept: application/json` flips to a structured response we can parse;
// without it the body is markdown directly.

export interface JinaSearchResult {
  url: string;
  title: string;
  snippet: string;
}

export async function jinaSearch(
  env: Env,
  query: string,
  signal?: AbortSignal,
): Promise<JinaSearchResult[]> {
  const url = `https://s.jina.ai/?q=${encodeURIComponent(query)}`;
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${env.JINA_API_KEY}`,
      Accept: 'application/json',
      // Trim noise (image embeds + social cruft) from the search index.
      'X-Respond-With': 'no-content',
    },
    signal,
  });
  if (!res.ok) {
    throw new Error(`jina search ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    data?: Array<{ url: string; title?: string; description?: string; snippet?: string }>;
  };
  const data = json.data ?? [];
  return data.map((d) => ({
    url: d.url,
    title: d.title ?? '',
    snippet: d.description ?? d.snippet ?? '',
  }));
}

export interface JinaReadResult {
  url: string;
  title: string;
  content: string; // clean markdown
}

export async function jinaRead(
  env: Env,
  pageUrl: string,
  signal?: AbortSignal,
): Promise<JinaReadResult> {
  const url = `https://r.jina.ai/${pageUrl}`;
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${env.JINA_API_KEY}`,
      Accept: 'application/json',
    },
    signal,
  });
  if (!res.ok) {
    throw new Error(`jina read ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const json = (await res.json()) as {
    data?: { url?: string; title?: string; content?: string };
  };
  const d = json.data ?? {};
  return {
    url: d.url ?? pageUrl,
    title: d.title ?? '',
    content: d.content ?? '',
  };
}
