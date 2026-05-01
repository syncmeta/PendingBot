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
import systemNormal from '../../prompts/system-normal.md';
import identityQuest from '../../prompts/identity-quest.md';
import discuss from '../../prompts/discuss.md';
import review from '../../prompts/review.md';
import reviewEval from '../../prompts/review-eval.md';
import reviewFollowup from '../../prompts/review-followup.md';
import surfingAgent from '../../prompts/surfing-agent.md';
import surfingJournal from '../../prompts/surfing-journal.md';
import surfingSkim from '../../prompts/surfing-skim.md';
import surfingSummary from '../../prompts/surfing-summary.md';
import surfingUserlens from '../../prompts/surfing-userlens.md';
import title from '../../prompts/title.md';
import botsDefault from '../../prompts/bots/default.md';
import portraitAlarms from '../../prompts/portrait/alarms.md';
import portraitBills from '../../prompts/portrait/bills.md';
import portraitChat from '../../prompts/portrait/chat.md';
import portraitMemos from '../../prompts/portrait/memos.md';
import portraitMoments from '../../prompts/portrait/moments.md';
import portraitSchedule from '../../prompts/portrait/schedule.md';

const PROMPTS = {
  'system': system,
  'system-normal': systemNormal,
  'identity-quest': identityQuest,
  'discuss': discuss,
  'review': review,
  'review-eval': reviewEval,
  'review-followup': reviewFollowup,
  'surfing-agent': surfingAgent,
  'surfing-journal': surfingJournal,
  'surfing-skim': surfingSkim,
  'surfing-summary': surfingSummary,
  'surfing-userlens': surfingUserlens,
  'title': title,
  'bots/default': botsDefault,
  'portrait/alarms': portraitAlarms,
  'portrait/bills': portraitBills,
  'portrait/chat': portraitChat,
  'portrait/memos': portraitMemos,
  'portrait/moments': portraitMoments,
  'portrait/schedule': portraitSchedule,
} as const;

export type PromptName = keyof typeof PROMPTS;

export function getPrompt(name: PromptName): string {
  return PROMPTS[name];
}
