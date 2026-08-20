// System model-role defaults: which model each PLATFORM function uses.
//
// Mirror of lib/feature-flags.ts — two sources composed as `override ?? code default`:
//   - code default (this file): the slug shipped in code; the ultimate floor,
//     synchronous, can't fail. These are exactly the slugs that used to be
//     hardcoded at each call site (title-runner / group-router / group-bot-intro /
//     vision / envelope explorer+collaborator / realtime voice). Keeping them here
//     means an empty KV override is byte-for-byte the OLD behavior — zero
//     regression on rollout.
//   - KV override (env.MEMORY's `cfg:model-roles`): the board writes at runtime so
//     ops can repoint a role to a new slug without a redeploy. If the KV read
//     fails we silently fall back to the code default (never throw).
//
// These roles are NOT user/bot model choices — those go through bots.model_id /
// config.modelPool / model_presets. These are SYSTEM tasks: the small classifier
// that names conversations, the group wake router, the group-intro writer, the
// vision summarizer, the envelope explorer/collaborator, and the realtime voice
// defaults.
//
// Verified present in the OpenRouter catalog 2026-06-17 (gemma-4-31b-it /
// kimi-latest / gemini-flash-latest), EXCEPT the `gpt-realtime-*` voice slugs,
// which route via the native OpenAI realtime endpoint, not OpenRouter.
import type { Env } from '../types';

/** KV key holding the override blob (shared with the board endpoint). */
export const MODEL_ROLES_KV_KEY = 'cfg:model-roles';
const ROLES_TTL_MS = 60_000;

/**
 * Each role's CODE DEFAULT = the slug previously hardcoded at the call site.
 * Adding a role here = adding it to the board page automatically (the route
 * iterates these keys).
 */
export const MODEL_ROLE_DEFAULTS = {
  /** Conversation title classifier — title-runner.ts */
  title: 'google/gemma-4-31b-it',
  /** Group message wake router (which bots to wake) — llm/group-router.ts */
  groupRouter: 'google/gemma-4-31b-it',
  /** Group bot self-intro writer — lib/group-bot-intro.ts */
  groupBotIntro: 'google/gemma-4-31b-it',
  /** Attachment / image vision summarizer — llm/vision.ts */
  vision: 'moonshotai/kimi-latest',
  /** Envelope explorer pass — lib/envelope-runner.ts */
  envelopeExplorer: '~google/gemini-flash-latest',
  /** Envelope collaborator pass — lib/envelope-runner.ts */
  envelopeCollaborator: '~google/gemini-flash-latest',
  /** Realtime voice fallback model (used when no per-bot/conv voice model is
   *  pinned) — resolved via getModelRole at the 6 call sites in
   *  durable-objects/realtime-meter + room-voice and routes/group-voice +
   *  realtime. The `gpt-realtime-*` slugs route via OpenAI's native realtime
   *  endpoint, not OpenRouter; `gpt-realtime-mini` is only a REALTIME_PRICING
   *  key, never a default, so it is intentionally NOT a role here. */
  voiceDefault: 'gpt-realtime-2',
} as const;

export type ModelRole = keyof typeof MODEL_ROLE_DEFAULTS;
export const MODEL_ROLE_KEYS = Object.keys(MODEL_ROLE_DEFAULTS) as ModelRole[];
export type RoleOverrides = Partial<Record<ModelRole, string>>;

// isolate-local cache: avoid reading KV on every hot-path resolve (title runs on
// every first turn, group-router on every group message). Same isolate-TTL
// pattern as feature-flags.ts. On KV failure we keep the previous cache (or
// empty → code defaults). Never throws.
let cache: { at: number; v: RoleOverrides } | null = null;

async function loadOverrides(env: Env, now: number): Promise<RoleOverrides> {
  if (cache && now - cache.at < ROLES_TTL_MS) return cache.v;
  try {
    const v = (await env.MEMORY.get<RoleOverrides>(MODEL_ROLES_KV_KEY, 'json')) ?? {};
    cache = { at: now, v };
    return v;
  } catch {
    return cache?.v ?? {};
  }
}

/** Test-only: reset the isolate cache. */
export function __resetModelRoleCacheForTest(): void {
  cache = null;
}

/**
 * Resolve a system model role to a slug: board KV override ?? code default.
 * Never throws (KV failure → code default). `now` is injectable for tests.
 */
export async function getModelRole(env: Env, role: ModelRole, now: number = Date.now()): Promise<string> {
  const ov = await loadOverrides(env, now);
  const v = ov[role];
  return typeof v === 'string' && v.length > 0 ? v : MODEL_ROLE_DEFAULTS[role];
}
