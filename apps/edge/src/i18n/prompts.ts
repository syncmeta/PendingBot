// Stable public API for fetching prompt bodies.
//
// Resolution: Langfuse Prompt Management override → bundled .md → zh fallback.
// Cache layer lives in ../llm/prompt-loader and is shared across this file.
//
// Use `loadPrompt(env, name, locale)` when you want a single prompt and don't
// care about preload mechanics. For hot paths that call getPrompt many times
// per request, do `await ensurePromptsLoaded(env)` once, then call the sync
// `getPromptSync(name, locale)` repeatedly.

import type { Env } from '../types';
import {
  ensurePromptOverridesLoaded,
  getPrompt,
  getBundledPrompt,
} from '../llm/prompt-loader';
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
  getBundledPrompt,
  invalidatePromptCache,
} from '../llm/prompt-loader';
export { PROMPT_NAMES, PROMPT_DESCRIPTIONS, type PromptName } from '../llm/prompt-names';
