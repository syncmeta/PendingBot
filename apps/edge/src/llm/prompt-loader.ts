// Single entry point for the markdown prompt library. Wrangler bundles the
// .md files at build time (see [[rules]] in wrangler.jsonc) so reads are
// zero-IO at runtime.
//
// Adding a new prompt:
//   1. drop a .md file into apps/edge/prompts/<locale>/
//   2. import it here under the matching locale block
//   3. add to the PROMPTS_BY_LOCALE map
//
// Then any handler can `getPrompt('your-name')` (defaults to zh) or
// `getPrompt('your-name', locale)`. Missing translations fall back to zh.

import { DEFAULT_LOCALE, type Locale } from '../i18n/types';

import system_zh from '../../prompts/zh/system.md';
import identityQuest_zh from '../../prompts/zh/identity-quest.md';
import scroll_zh from '../../prompts/zh/scroll.md';
import scrollInjected_zh from '../../prompts/zh/scroll-injected.md';
import scrollWrite_zh from '../../prompts/zh/scroll-write.md';
import scrollCollaborator_zh from '../../prompts/zh/scroll-collaborator.md';
import title_zh from '../../prompts/zh/title.md';

const PROMPTS_ZH = {
  'system': system_zh,
  'identity-quest': identityQuest_zh,
  'scroll': scroll_zh,
  'scroll-injected': scrollInjected_zh,
  'scroll-write': scrollWrite_zh,
  'scroll-collaborator': scrollCollaborator_zh,
  'title': title_zh,
} as const;

export type PromptName = keyof typeof PROMPTS_ZH;

const PROMPTS_BY_LOCALE: Record<Locale, Partial<Record<PromptName, string>>> = {
  zh: PROMPTS_ZH,
  en: {},
};

export function getPrompt(name: PromptName, locale: Locale = DEFAULT_LOCALE): string {
  return PROMPTS_BY_LOCALE[locale]?.[name] ?? PROMPTS_ZH[name];
}
