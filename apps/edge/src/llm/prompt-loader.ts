// Single entry point for the markdown prompt library. Wrangler bundles the
// .md files at build time (see [[rules]] in wrangler.jsonc) so reads are
// zero-IO at runtime.
//
// Adding a new prompt:
//   1. drop a .md file into apps/edge/prompts/...
//   2. import it here
//   3. add to the PROMPTS map
//
// Then any handler can `getPrompt('your-name')`.

import system from '../../prompts/system.md';
import identityQuest from '../../prompts/identity-quest.md';
import review from '../../prompts/review.md';
import scroll from '../../prompts/scroll.md';
import scrollInjected from '../../prompts/scroll-injected.md';
import scrollWrite from '../../prompts/scroll-write.md';
import title from '../../prompts/title.md';

const PROMPTS = {
  'system': system,
  'identity-quest': identityQuest,
  'review': review,
  'scroll': scroll,
  'scroll-injected': scrollInjected,
  'scroll-write': scrollWrite,
  'title': title,
} as const;

export type PromptName = keyof typeof PROMPTS;

export function getPrompt(name: PromptName): string {
  return PROMPTS[name];
}
