// Stable public API for fetching prompt bodies.
//
// Resolution: DB override (pendingbot.i18n_prompts) → bundled .md → zh fallback.
// Cache layer lives in ../llm/prompt-loader and is shared across this file.
//
// Use `loadPrompt(supa, name, locale)` when you want a single prompt and don't
// care about preload mechanics. For hot paths that call getPrompt many times
// per request, do `await ensurePromptsLoaded(supa)` once, then call the sync
// `getPromptSync(name, locale)` repeatedly.

import type { SupabaseClient } from '../lib/supabase';
import {
  ensurePromptOverridesLoaded,
  getPrompt,
  getBundledPrompt,
} from '../llm/prompt-loader';
import { DEFAULT_LOCALE, type Locale } from './types';
import type { PromptName } from '../llm/prompt-names';

export async function loadPrompt(
  supa: SupabaseClient,
  name: PromptName,
  locale: Locale = DEFAULT_LOCALE,
): Promise<string> {
  await ensurePromptOverridesLoaded(supa);
  return getPrompt(name, locale);
}

export {
  ensurePromptOverridesLoaded as ensurePromptsLoaded,
  getPrompt as getPromptSync,
  getBundledPrompt,
  invalidatePromptCache,
} from '../llm/prompt-loader';
export { PROMPT_NAMES, PROMPT_DESCRIPTIONS, type PromptName } from '../llm/prompt-names';
