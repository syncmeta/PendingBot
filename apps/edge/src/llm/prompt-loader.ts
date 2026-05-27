// Single entry point for the markdown prompt library.
//
// Resolution order (per getPrompt call):
//   1. In-memory cache populated from pendingbot.i18n_prompts (DB override)
//   2. Bundled .md file under apps/edge/prompts/<locale>/  (wrangler inlines
//      these at build time via the [[rules]] Text rule in wrangler.jsonc)
//   3. zh-bundled fallback (DEFAULT_LOCALE)
//
// The DB layer lets Board (admin)/prompts/ tune prompts without redeploying
// the worker. Empty table = pure bundled behavior (no behavior change).
//
// Cache lifecycle: each isolate keeps a Map<`${locale}/${name}`, body_md>
// with a 30s TTL. Concurrent loads dedupe via the inflight Promise. Each
// async entry point (runChatTurn / runEnvelope / runTitle / runLookback /
// runGroupRouter) should `await ensurePromptOverridesLoaded(supa)` early so
// subsequent sync getPrompt calls hit the cache.
//
// Adding a new prompt:
//   1. drop a .md file into apps/edge/prompts/<locale>/
//   2. import it here under the matching locale block
//   3. add to PROMPTS_BY_LOCALE

import { DEFAULT_LOCALE, type Locale } from '../i18n/types';
import type { SupabaseClient } from '../lib/supabase';
import type { PromptName } from './prompt-names';

import system_zh from '../../prompts/zh/system.md';
import voice_zh from '../../prompts/zh/voice.md';
import groupVoice_zh from '../../prompts/zh/group-voice.md';
import identityQuest_zh from '../../prompts/zh/identity-quest.md';
import envelope_zh from '../../prompts/zh/envelope.md';
import envelopeInjected_zh from '../../prompts/zh/envelope-injected.md';
import envelopeWrite_zh from '../../prompts/zh/envelope-write.md';
import envelopeCollaborator_zh from '../../prompts/zh/envelope-collaborator.md';
import title_zh from '../../prompts/zh/title.md';
import groupRouter_zh from '../../prompts/zh/group-router.md';
import botSocialGraph_zh from '../../prompts/zh/bot-social-graph.md';

const PROMPTS_ZH = {
  'system': system_zh,
  'voice': voice_zh,
  'group-voice': groupVoice_zh,
  'identity-quest': identityQuest_zh,
  'envelope': envelope_zh,
  'envelope-injected': envelopeInjected_zh,
  'envelope-write': envelopeWrite_zh,
  'envelope-collaborator': envelopeCollaborator_zh,
  'title': title_zh,
  'group-router': groupRouter_zh,
  'bot-social-graph': botSocialGraph_zh,
} as const;

export { PROMPT_NAMES, type PromptName } from './prompt-names';

const PROMPTS_BY_LOCALE: Record<Locale, Partial<Record<PromptName, string>>> = {
  zh: PROMPTS_ZH,
  en: {},
};

// ── DB override cache ──────────────────────────────────────────────────
const overrideCache = new Map<string, string>(); // key: `${locale}/${name}`
let cacheLoadedAt = 0;
let inflightLoad: Promise<void> | null = null;
const CACHE_TTL_MS = 30_000;

export async function ensurePromptOverridesLoaded(supa: SupabaseClient): Promise<void> {
  if (Date.now() - cacheLoadedAt < CACHE_TTL_MS) return;
  if (inflightLoad) return inflightLoad;
  inflightLoad = (async () => {
    try {
      const { data, error } = await supa
        .from('i18n_prompts')
        .select('name, locale, body_md');
      if (error) {
        console.warn('[prompt-loader] override load failed, using bundled', error);
        return;
      }
      const next = new Map<string, string>();
      for (const row of data ?? []) {
        next.set(`${row.locale}/${row.name}`, row.body_md);
      }
      overrideCache.clear();
      for (const [k, v] of next) overrideCache.set(k, v);
      cacheLoadedAt = Date.now();
    } finally {
      inflightLoad = null;
    }
  })();
  return inflightLoad;
}

// Manual flush — call this after writing to i18n_prompts within the same
// isolate so the next read picks up the change without waiting for TTL.
export function invalidatePromptCache(): void {
  overrideCache.clear();
  cacheLoadedAt = 0;
}

export function getPrompt(name: PromptName, locale: Locale = DEFAULT_LOCALE): string {
  return (
    overrideCache.get(`${locale}/${name}`) ??
    overrideCache.get(`${DEFAULT_LOCALE}/${name}`) ??
    PROMPTS_BY_LOCALE[locale]?.[name] ??
    PROMPTS_ZH[name]
  );
}

// Expose bundled defaults so Board can preview them when a (name, locale)
// row hasn't been overridden yet.
export function getBundledPrompt(name: PromptName, locale: Locale = DEFAULT_LOCALE): string {
  return PROMPTS_BY_LOCALE[locale]?.[name] ?? PROMPTS_ZH[name];
}
