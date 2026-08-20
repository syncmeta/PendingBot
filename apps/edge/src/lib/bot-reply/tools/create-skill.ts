import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import type { ToolCtx } from '../tool-runner';
import {
  SKILL_BODY_MAX,
  SKILL_DESC_MAX,
  SKILL_NAME_MAX,
  SKILL_NAME_RE,
} from '../tool-defs';

// Inserts a user-owned skill row + auto-subscribes it for the current
// conversation, so the skill takes effect on the very next turn. The skill
// shows up in 我→技能 and the user can promote to global there if they like.
// Bot-private knowledge has its own path (memory.ts/refreshBotNote); this
// tool is exclusively for surfacing a reusable skill into the user's library.
export async function createSkillTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const rawName = String(args.name ?? '').trim();
  const description = String(args.description ?? '').trim();
  const body = String(args.body ?? '');

  if (!rawName) return JSON.stringify({ error: 'name is required' });
  if (rawName.length > SKILL_NAME_MAX) {
    return JSON.stringify({ error: `name exceeds ${SKILL_NAME_MAX} chars` });
  }
  if (!SKILL_NAME_RE.test(rawName)) {
    return JSON.stringify({
      error: 'name must be lowercase kebab-case (a-z, 0-9, single hyphens)',
    });
  }
  if (description.length > SKILL_DESC_MAX) {
    return JSON.stringify({ error: `description exceeds ${SKILL_DESC_MAX} chars` });
  }
  if (!body.trim()) return JSON.stringify({ error: 'body is required' });
  if (body.length > SKILL_BODY_MAX) {
    return JSON.stringify({ error: `body exceeds ${SKILL_BODY_MAX} chars` });
  }

  ctx.emit('tool_call', { name: 'create_skill', skill_name: rawName });

  const supa = serviceClient(env);
  const frontmatter: Record<string, string> = { name: rawName, description };
  const { data, error } = await supa
    .from('skills')
    .insert({
      owner_id: ctx.userId,
      bot_id: null,
      user_id: null,
      visibility: 'private',
      frontmatter,
      body_md: body,
    })
    .select('id')
    .single();
  if (error || !data) {
    ctx.emit('tool_result', { name: 'create_skill', error: error?.message ?? 'insert failed' });
    return JSON.stringify({ error: error?.message ?? 'insert failed' });
  }

  // Auto-subscribe for the current conversation so the skill takes effect
  // on the very next turn here. The user can promote it to global from
  // 我→技能 if they like it. Ignore sub errors — the skill row is what
  // matters; the user can toggle on later if the auto-sub didn't land.
  await supa
    .from('skill_subscriptions')
    .insert({ user_id: ctx.userId, skill_id: data.id, conversation_id: ctx.conversationId });

  ctx.emit('tool_result', { name: 'create_skill', skill_id: data.id, skill_name: rawName });
  return JSON.stringify({ skill_id: data.id, name: rawName, subscribed: true });
}
