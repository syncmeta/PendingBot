// Single entry point for the markdown prompt library.
//
// Resolution order (per getPrompt call):
//   1. In-memory cache populated from Langfuse Prompt Management
//      (prompt named `<name>/<locale>`, label "production")
//   2. Bundled .md file under apps/edge/prompts/<locale>/  (wrangler inlines
//      these at build time via the [[rules]] Text rule in wrangler.jsonc)
//   3. zh-bundled fallback (DEFAULT_LOCALE)
//
// Langfuse Prompt Management lets the team tune prompts from its UI without
// redeploying the worker. The push pipeline keeps Langfuse in sync with the
// bundled .md files, so an empty / unreachable Langfuse = pure bundled
// behavior (no behavior change). The legacy pendingbot.i18n_prompts DB table
// has been retired — Langfuse is the single override source now.
//
// Feature flag: when LANGFUSE_ENABLED !== 'true' (or the keys are unset),
// the loader never touches Langfuse and serves bundled .md directly. So the
// flag that gates tracing also gates prompt sourcing — one switch, off by
// default, and the worker behaves identically to the bundled library.
//
// Cache lifecycle: each isolate keeps a Map<`${locale}/${name}`, body_md>
// with a 30s TTL. Concurrent loads dedupe via the inflight Promise. Each
// async entry point (runChatTurn / runEnvelope / runTitle / runLookback /
// runGroupRouter) should `await ensurePromptOverridesLoaded(env)` early so
// subsequent sync getPrompt calls hit the cache.
//
// Adding a new prompt:
//   1. drop a .md file into apps/edge/prompts/<locale>/
//   2. import it here under the matching locale block
//   3. add to PROMPTS_BY_LOCALE
//   4. push it to Langfuse via the prompt-push pipeline (named `<name>/<locale>`)

import { Langfuse } from 'langfuse';
import { DEFAULT_LOCALE, type Locale } from '../i18n/types';
import type { Env } from '../types';
import { langfuseEnabled } from '../lib/feature-flags';
import { PROMPT_NAMES, type PromptName } from './prompt-names';

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
import sessionWorldModel_zh from '../../prompts/zh/session-world-model.md';

import sessionWorldModel_en from '../../prompts/en/session-world-model.md';
import startCrewToolResult_zh from '../../prompts/zh/start-crew-tool-result.md';
import requestPermissionToolResult_zh from '../../prompts/zh/request-permission-tool-result.md';

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
  'session-world-model': sessionWorldModel_zh,
  'start-crew-tool-result': startCrewToolResult_zh,
  'request-permission-tool-result': requestPermissionToolResult_zh,
} as const;

export { PROMPT_NAMES, type PromptName } from './prompt-names';

const PROMPTS_BY_LOCALE: Record<Locale, Partial<Record<PromptName, string>>> = {
  zh: PROMPTS_ZH,
  en: {
    'session-world-model': sessionWorldModel_en,
  },
};

// (locale, name) pairs that actually have a bundled .md to override. Only
// these are fetched from Langfuse — there's no point asking Langfuse for a
// prompt that has no local fallback (en/* beyond session-world-model).
const OVERRIDABLE: Array<{ locale: Locale; name: PromptName }> = (
  Object.entries(PROMPTS_BY_LOCALE) as Array<[Locale, Partial<Record<PromptName, string>>]>
).flatMap(([locale, map]) =>
  PROMPT_NAMES.filter((n) => map[n] != null).map((name) => ({ locale, name })),
);

// ── Langfuse override cache ────────────────────────────────────────────
const overrideCache = new Map<string, string>(); // key: `${locale}/${name}`
let cacheLoadedAt = 0;
let inflightLoad: Promise<void> | null = null;
const CACHE_TTL_MS = 30_000;

// Langfuse Prompt Management naming: one prompt per (name, locale), named
// `<name>/<locale>`, served from the "production" label.
const PRODUCTION_LABEL = 'production';
function langfusePromptName(name: PromptName, locale: Locale): string {
  return `${name}/${locale}`;
}

/**
 * Warm the override cache from Langfuse Prompt Management.
 *
 * No-op (cache stays empty → bundled .md serves) when LANGFUSE_ENABLED is
 * off or the keys are unset. Best-effort otherwise: a fetch failure for any
 * single prompt is swallowed (that name falls through to bundled), and a
 * total Langfuse outage leaves the cache empty so nothing breaks.
 *
 * TTL-gated + inflight-deduped exactly like the old DB loader, so the hot
 * path pays at most one Langfuse round-trip burst per isolate per 30s.
 */
export async function ensurePromptOverridesLoaded(env: Env): Promise<void> {
  if (!langfuseEnabled(env) || !env.LANGFUSE_PUBLIC_KEY || !env.LANGFUSE_SECRET_KEY) return;
  if (Date.now() - cacheLoadedAt < CACHE_TTL_MS) return;
  if (inflightLoad) return inflightLoad;
  inflightLoad = (async () => {
    try {
      const langfuse = new Langfuse({
        publicKey: env.LANGFUSE_PUBLIC_KEY,
        secretKey: env.LANGFUSE_SECRET_KEY,
        baseUrl: env.LANGFUSE_BASE_URL,
      });
      const next = new Map<string, string>();
      await Promise.all(
        OVERRIDABLE.map(async ({ locale, name }) => {
          try {
            const prompt = await langfuse.getPrompt(
              langfusePromptName(name, locale),
              undefined,
              { label: PRODUCTION_LABEL, type: 'text', cacheTtlSeconds: 0 },
            );
            // .prompt holds the raw text body for text prompts. We store the
            // un-compiled template — call sites do their own {{var}} fill via
            // string replace, same as they did with the bundled .md.
            const body = prompt.prompt;
            if (typeof body === 'string' && body.length > 0) {
              next.set(`${locale}/${name}`, body);
            }
          } catch (err) {
            console.warn('[prompt-loader] langfuse fetch failed, using bundled', name, locale, err);
          }
        }),
      );
      overrideCache.clear();
      for (const [k, v] of next) overrideCache.set(k, v);
      cacheLoadedAt = Date.now();
      await langfuse.shutdownAsync().catch(() => {});
    } catch (err) {
      console.warn('[prompt-loader] langfuse override load failed, using bundled', err);
    } finally {
      inflightLoad = null;
    }
  })();
  return inflightLoad;
}

// Manual flush — call this if a prompt was just changed in Langfuse and you
// want the next read in this isolate to re-fetch without waiting for the TTL.
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

// Expose bundled defaults so tooling can preview them when a (name, locale)
// prompt hasn't been overridden in Langfuse yet.
export function getBundledPrompt(name: PromptName, locale: Locale = DEFAULT_LOCALE): string {
  return PROMPTS_BY_LOCALE[locale]?.[name] ?? PROMPTS_ZH[name];
}
