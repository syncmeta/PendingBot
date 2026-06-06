// Prompt library loader. Langfuse is the SINGLE SOURCE OF TRUTH for prompts;
// this module only distributes them to the worker and fails loud when a
// prompt can't be resolved (there is deliberately no bundled fallback).
//
// Resolution layers (getPrompt is sync and reads L1 only):
//   L1  in-process Map (per isolate, 30s TTL)          ← what getPrompt reads
//   L2  PROMPTS_KV (cross-isolate, webhook-pushed + pull-on-miss)
//   pull Langfuse getPrompt(production) on KV miss, written back to KV
// If all come up empty, getPrompt THROWS. A wrong-but-plausible stale prompt
// is worse than a loud failure, so we don't keep a bundled copy. The worker's
// LLM paths surface the throw as an error.
//
// Editing flow: prompts are edited in the Langfuse console (production label).
// Changes reach the worker via the prompt-version webhook
// (routes/langfuse-prompts.ts → writes KV via putPromptRecord). pull-on-miss
// is just the cold-fill / webhook-missed safety net.
//
// NOTE: prompt sourcing is NOT gated by LANGFUSE_ENABLED — that flag now only
// gates trace ingestion (lib/llm-trace.ts). Prompts are infrastructure: with
// keys unset and KV empty, prompts are unavailable and the worker fails loud.

import { DEFAULT_LOCALE, type Locale } from '../i18n/types';
import type { Env } from '../types';
import { getLangfuseClient } from '../lib/langfuse-client';
import { PROMPT_NAMES, type PromptName } from './prompt-names';

export { PROMPT_NAMES, type PromptName } from './prompt-names';

const PRODUCTION_LABEL = 'production';
const CACHE_TTL_MS = 30_000;

// Prompts authored in a non-default locale. zh (DEFAULT_LOCALE) always has
// every prompt; only these have extra locale variants. getPrompt falls back
// to the zh version when a locale-specific one is absent.
const LOCALE_VARIANTS: Partial<Record<Locale, readonly PromptName[]>> = {
  en: ['session-world-model'],
};

export interface PromptRecord {
  body: string;
  version: number;
}

// ── caches ──────────────────────────────────────────────────────────────
const mem = new Map<string, PromptRecord>(); // key: `${locale}/${name}`
let cacheLoadedAt = 0;
let inflightLoad: Promise<void> | null = null;

const memKey = (name: PromptName, locale: Locale) => `${locale}/${name}`;
// Langfuse prompt name and KV key share the `<name>/<locale>` shape.
const langfuseName = (name: PromptName, locale: Locale) => `${name}/${locale}`;
const kvKey = (name: PromptName, locale: Locale) => `prompt:${name}/${locale}`;

function manifest(): Array<{ name: PromptName; locale: Locale }> {
  const out: Array<{ name: PromptName; locale: Locale }> = [];
  for (const name of PROMPT_NAMES) out.push({ name, locale: DEFAULT_LOCALE });
  for (const [locale, names] of Object.entries(LOCALE_VARIANTS) as Array<
    [Locale, readonly PromptName[]]
  >) {
    for (const name of names) out.push({ name, locale });
  }
  return out;
}

// Resolve one (name, locale): L2 KV → pull Langfuse (writing back to KV).
// Returns null when neither has it (caller falls back to the default locale,
// then getPrompt throws).
async function resolveRecord(
  env: Env,
  name: PromptName,
  locale: Locale,
): Promise<PromptRecord | null> {
  const kv = env.PROMPTS_KV;
  if (kv) {
    try {
      const raw = await kv.get(kvKey(name, locale));
      if (raw) {
        const rec = JSON.parse(raw) as PromptRecord;
        if (rec && typeof rec.body === 'string' && rec.body.length > 0) return rec;
      }
    } catch (err) {
      console.warn('[prompt-loader] KV get failed', langfuseName(name, locale), err);
    }
  }
  const lf = getLangfuseClient(env);
  if (!lf) return null;
  try {
    const p = await lf.getPrompt(langfuseName(name, locale), undefined, {
      label: PRODUCTION_LABEL,
      type: 'text',
      cacheTtlSeconds: 0,
    });
    const body = typeof p.prompt === 'string' ? p.prompt : null;
    if (!body) return null;
    const rec: PromptRecord = { body, version: p.version };
    if (kv) {
      try {
        await kv.put(kvKey(name, locale), JSON.stringify(rec));
      } catch (err) {
        console.warn('[prompt-loader] KV put failed', langfuseName(name, locale), err);
      }
    }
    return rec;
  } catch {
    // Not found at this locale (or fetch failed); caller falls back.
    return null;
  }
}

/**
 * Warm the in-memory prompt cache from KV (+ pull-on-miss from Langfuse).
 *
 * TTL-gated + inflight-deduped: at most one resolution burst per isolate per
 * 30s. Each async entry point (runChatTurn / runEnvelope / runTitle /
 * runLookback / renderSessionWorldModel) should `await` this early so the
 * subsequent sync getPrompt calls hit memory.
 *
 * Best-effort refresh: if a load resolves nothing (total outage) the prior
 * in-memory cache is kept rather than cleared, so a transient blip doesn't
 * empty a warm isolate.
 */
export async function ensurePromptOverridesLoaded(env: Env): Promise<void> {
  if (mem.size > 0 && Date.now() - cacheLoadedAt < CACHE_TTL_MS) return;
  if (inflightLoad) return inflightLoad;
  inflightLoad = (async () => {
    try {
      const next = new Map<string, PromptRecord>();
      await Promise.all(
        manifest().map(async ({ name, locale }) => {
          const rec = await resolveRecord(env, name, locale);
          if (rec) next.set(memKey(name, locale), rec);
        }),
      );
      if (next.size > 0) {
        mem.clear();
        for (const [k, v] of next) mem.set(k, v);
        cacheLoadedAt = Date.now();
      }
    } finally {
      inflightLoad = null;
    }
  })();
  return inflightLoad;
}

// Drop the in-memory cache so the next ensurePromptOverridesLoaded re-resolves.
// KV is left intact (it's maintained by the webhook).
export function invalidatePromptCache(): void {
  mem.clear();
  cacheLoadedAt = 0;
}

// Upsert a record into KV + the in-memory cache. Used by the prompt-version
// webhook so a change is live immediately without waiting for a pull.
export async function putPromptRecord(
  env: Env,
  name: PromptName,
  locale: Locale,
  rec: PromptRecord,
): Promise<void> {
  const kv = env.PROMPTS_KV;
  if (kv) await kv.put(kvKey(name, locale), JSON.stringify(rec));
  mem.set(memKey(name, locale), rec);
}

/**
 * Synchronous prompt body lookup, reading the in-memory cache filled by
 * ensurePromptOverridesLoaded. Falls back to the default locale, then THROWS
 * if unavailable — there is no bundled fallback by design.
 */
export function getPrompt(name: PromptName, locale: Locale = DEFAULT_LOCALE): string {
  const rec = mem.get(memKey(name, locale)) ?? mem.get(memKey(name, DEFAULT_LOCALE));
  if (!rec) {
    throw new Error(
      `[prompt-loader] prompt unavailable: ${name}/${locale} — not in KV or Langfuse. ` +
        `Ensure a 'production' version exists and ensurePromptOverridesLoaded ran first.`,
    );
  }
  return rec.body;
}

/**
 * Prompt version metadata for linking a generation to its prompt version in
 * Langfuse (analytics by prompt version). Returns null when unknown — callers
 * treat the link as optional.
 */
export function getPromptMeta(
  name: PromptName,
  locale: Locale = DEFAULT_LOCALE,
): { name: string; version: number } | null {
  const exact = mem.get(memKey(name, locale));
  if (exact) return { name: langfuseName(name, locale), version: exact.version };
  const def = mem.get(memKey(name, DEFAULT_LOCALE));
  if (def) return { name: langfuseName(name, DEFAULT_LOCALE), version: def.version };
  return null;
}
