// Lightweight i18n for edge-side user-facing strings (route errors, push copy,
// anything that gets surfaced to the iOS client).
//
// Usage:
//   import { t, normalizeLocale } from '@/i18n';
//   const locale = normalizeLocale(user?.locale);
//   return c.json({ error: t('errors.forbidden', locale) }, 403);
//
// AI prompts have their own loader (../llm/prompt-loader.ts) — they're whole
// markdown files, not short interpolated strings, so they don't live here.

import zh from './locales/zh';
import en from './locales/en';
import { DEFAULT_LOCALE, type Dictionary, type Locale } from './types';

const DICTS: Record<Locale, Dictionary> = { zh, en };

export function t(
  key: string,
  locale: Locale = DEFAULT_LOCALE,
  params?: Record<string, string | number>,
): string {
  const value =
    DICTS[locale]?.[key] ?? DICTS[DEFAULT_LOCALE][key] ?? key;
  if (!params) return value;
  return value.replace(/\{(\w+)\}/g, (_, k) =>
    k in params ? String(params[k]) : `{${k}}`,
  );
}

export {
  DEFAULT_LOCALE,
  SUPPORTED_LOCALES,
  isLocale,
  normalizeLocale,
  type Dictionary,
  type Locale,
} from './types';
export { resolveLocale } from './locale';
export { loadPrompt, ensurePromptsLoaded, getPromptSync, getPromptMeta, invalidatePromptCache } from './prompts';
export { PROMPT_NAMES, PROMPT_DESCRIPTIONS, type PromptName } from '../llm/prompt-names';
