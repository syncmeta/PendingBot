// Tiny SSE-over-fetch helper plus typed REST wrappers around the
// envelope-lab Hono server.

import type {
  ConfigResponse,
  FixtureFile,
  FixtureMeta,
  HistoryMsg,
  PromptsResponse,
  ResultEvent,
  ScrapeProvider,
  SearchProvider,
  StartEvent,
  TurnEvent,
} from './types';

export async function fetchConfig(): Promise<ConfigResponse> {
  const r = await fetch('/api/config');
  if (!r.ok) throw new Error(await r.text());
  return r.json() as Promise<ConfigResponse>;
}

export async function fetchPrompts(): Promise<PromptsResponse> {
  const r = await fetch('/api/prompts');
  if (!r.ok) throw new Error(await r.text());
  return r.json() as Promise<PromptsResponse>;
}

export async function savePrompts(body: {
  system?: string;
  injected?: string;
  write?: string;
  collaborator?: string;
}): Promise<void> {
  const r = await fetch('/api/prompts', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(await r.text());
}

export interface RunSummary {
  id: string;
  ts: string;
  model: string;
  collaboratorModel?: string;
  reason: string;
  turns: number;
  elapsedMs: number;
  totalTokens: number;
  title: string | null;
}

export async function fetchRunsList(): Promise<RunSummary[]> {
  const r = await fetch('/api/runs');
  if (!r.ok) throw new Error(await r.text());
  const j = (await r.json()) as { runs: RunSummary[] };
  return j.runs;
}

export async function fetchRun(id: string): Promise<unknown> {
  const r = await fetch(`/api/runs/${encodeURIComponent(id)}`);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export async function fetchFixtures(): Promise<FixtureMeta[]> {
  const r = await fetch('/api/fixtures');
  if (!r.ok) throw new Error(await r.text());
  const j = (await r.json()) as { fixtures: FixtureMeta[] };
  return j.fixtures;
}

export async function fetchFixture(id: string): Promise<FixtureFile> {
  const r = await fetch(`/api/fixtures/${encodeURIComponent(id)}`);
  if (!r.ok) throw new Error(await r.text());
  return r.json() as Promise<FixtureFile>;
}

export async function fetchOpenrouterCost(id: string): Promise<{
  data?: {
    total_cost?: number;
    native_tokens_prompt?: number;
    native_tokens_completion?: number;
    cache_discount?: number;
  };
}> {
  const r = await fetch(`/api/openrouter-generation/${encodeURIComponent(id)}`);
  if (!r.ok) return {};
  return r.json();
}

export interface RunRequest {
  model: string;
  systemPrompt: string;
  injectedPrompt: string;
  history: HistoryMsg[];
  memory?: string;
  searchProvider: SearchProvider;
  scrapeProvider: ScrapeProvider;
  stubSearch?: boolean;
  stubFetch?: boolean;
  turns?: number;
  collaboratorModel?: string;
  collaboratorPrompt?: string;
  writeModel?: string;
  writePhasePrompt?: string;
  showTurnsRemaining?: boolean;
  collaboratorShowTurnsRemaining?: boolean;
  resumeFromRunId?: string;
  initialResearchUnlocked?: boolean;
}

export async function setResearchUnlocked(runId: string, value: boolean): Promise<void> {
  const r = await fetch(`/api/runs/${encodeURIComponent(runId)}/state`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ researchUnlocked: value }),
  });
  if (!r.ok) throw new Error(await r.text());
}

export interface RunHandlers {
  onStart?: (e: StartEvent) => void;
  onTurn?: (e: TurnEvent) => void;
  onResult?: (e: ResultEvent) => void;
  onError?: (msg: string) => void;
  signal?: AbortSignal;
}

// Manual SSE parser — EventSource doesn't support POST so we read the
// streamed body and split on `\n\n` separators.
export async function runStream(req: RunRequest, h: RunHandlers): Promise<void> {
  const r = await fetch('/api/run', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
    signal: h.signal,
  });
  if (!r.ok) {
    const txt = await r.text().catch(() => '');
    h.onError?.(`HTTP ${r.status} ${txt.slice(0, 300)}`);
    return;
  }
  if (!r.body) {
    h.onError?.('no response body');
    return;
  }
  const reader = r.body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let sep: number;
    while ((sep = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, sep);
      buf = buf.slice(sep + 2);
      let event = 'message';
      let data = '';
      for (const line of chunk.split('\n')) {
        if (line.startsWith('event:')) event = line.slice(6).trim();
        else if (line.startsWith('data:')) data += line.slice(5).trimStart();
      }
      try {
        if (event === 'start') h.onStart?.(JSON.parse(data) as StartEvent);
        else if (event === 'turn') h.onTurn?.(JSON.parse(data) as TurnEvent);
        else if (event === 'result') h.onResult?.(JSON.parse(data) as ResultEvent);
        else if (event === 'error') h.onError?.(data);
      } catch (err) {
        h.onError?.(`bad SSE event ${event}: ${(err as Error).message}`);
      }
    }
  }
}
