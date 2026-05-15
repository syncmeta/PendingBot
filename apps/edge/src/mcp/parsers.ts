// Pure parsers for Exa MCP tool payloads. The hosted MCP returns the
// upstream JSON verbatim in content[0].text; callers (bot-reply,
// envelope-runner) flatten that and feed it here.
//
// Both parsers degrade gracefully on shape drift — an empty result is
// always preferable to throwing during an LLM turn.

import type { WebReadResult, WebSearchResult } from '../lib/web-types';

export function parseExaSearchPayload(text: string): WebSearchResult[] {
  const json = safeJson(text) as {
    results?: Array<{ url?: string; title?: string; text?: string }>;
  } | null;
  if (!json?.results) return [];
  return json.results
    .filter((r): r is { url: string; title?: string; text?: string } => !!r.url)
    .map((r) => ({
      url: r.url,
      title: r.title ?? '',
      snippet: (r.text ?? '').slice(0, 500),
    }));
}

export function parseExaFetchPayload(reqUrl: string, text: string): WebReadResult {
  // Exa's web_fetch_exa returns either a single result object or a
  // results[] array depending on call shape. Handle both.
  const json = safeJson(text) as
    | { url?: string; title?: string; text?: string }
    | { results?: Array<{ url?: string; title?: string; text?: string }> }
    | null;
  if (!json) return { url: reqUrl, title: '', content: '' };
  const single = 'text' in json && json.text !== undefined ? json : null;
  const first =
    single ??
    ((json as { results?: Array<unknown> }).results?.[0] as
      | { url?: string; title?: string; text?: string }
      | undefined);
  return {
    url: first?.url ?? reqUrl,
    title: first?.title ?? '',
    content: first?.text ?? '',
  };
}

function safeJson(text: string): unknown {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
