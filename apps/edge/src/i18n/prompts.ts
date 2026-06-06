// Stable public API for fetching prompt bodies.
//
// Resolution lives in ../llm/prompt-loader: in-memory L1 → PROMPTS_KV →
// pull-on-miss from Langfuse, then THROWS if unavailable (no bundled
// fallback). Langfuse is the source of truth.
//
// Use `loadPrompt(env, name, locale)` for a single prompt. For hot paths that
// call getPrompt many times per request, `await ensurePromptsLoaded(env)`
// once, then call the sync `getPromptSync(name, locale)` repeatedly.

import type { Env } from '../types';
import { ensurePromptOverridesLoaded, getPrompt } from '../llm/prompt-loader';
import { DEFAULT_LOCALE, type Locale } from './types';
import type { PromptName } from '../llm/prompt-names';

export async function loadPrompt(
  env: Env,
  name: PromptName,
  locale: Locale = DEFAULT_LOCALE,
): Promise<string> {
  await ensurePromptOverridesLoaded(env);
  return getPrompt(name, locale);
}

export {
  ensurePromptOverridesLoaded as ensurePromptsLoaded,
  getPrompt as getPromptSync,
  getPromptMeta,
  invalidatePromptCache,
} from '../llm/prompt-loader';
export { PROMPT_NAMES, PROMPT_DESCRIPTIONS, type PromptName } from '../llm/prompt-names';
