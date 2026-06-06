// `create_child_crew` — spec §6.4 captain duty "拆子 crew".
//
// The crew CAPTAIN (mid bot-reply, in its crew's group chat) spawns a CHILD
// crew that inherits a share of THIS crew's responsibility. We verify this
// conversation is an active crew and this bot is its captain, then call
// create_child_crew_inheriting_responsibility_for_actor with
// p_created_by_kind='captain' so the new crew is attributed to the captain
// while the responsibility owner is the human acting in this turn (ctx.userId).
//
// Responsibility split is STRUCTURAL, not numeric: the child links to the
// parent via crew_parent_links with responsibility_mode='inherit', and
// resolve_crew_responsibility_shares() walks the DAG to compute each subject's
// effective bps. There is deliberately no bps argument here — the RPC encodes
// inheritance in the link, not in a per-call percentage.
//
// The RPC's own user_can_control_crew_by_responsibility() gate rejects the call
// if ctx.userId has no responsibility stake in the parent crew, so a captain
// can't fork a crew on behalf of a user who doesn't own it.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import type { ToolCtx } from '../tool-runner';

const NAME_MAX = 80;
const BRIEF_MAX = 4_000;

export async function createChildCrewTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const name = typeof args.name === 'string' ? args.name.trim() : '';
  if (!name) return JSON.stringify({ error: 'name required' });
  if (name.length > NAME_MAX) {
    return JSON.stringify({ error: `name exceeds ${NAME_MAX} chars` });
  }
  const brief = typeof args.brief === 'string' ? args.brief.trim() : '';
  if (brief.length > BRIEF_MAX) {
    return JSON.stringify({ error: `brief exceeds ${BRIEF_MAX} chars` });
  }

  const supa = serviceClient(env);
  const { data: meta, error: metaErr } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, captain_bot_id, temporary_kind, status')
    .eq('conversation_id', ctx.conversationId)
    .maybeSingle();
  if (metaErr) return JSON.stringify({ error: 'database_error', detail: metaErr.message });
  if (!meta || meta.temporary_kind !== 'crew' || meta.status !== 'active') {
    return JSON.stringify({ error: 'create_child_crew only works inside an active crew' });
  }
  if (meta.captain_bot_id !== ctx.botId) {
    return JSON.stringify({ error: 'only the crew captain can create child crews' });
  }

  const rpc = supa as unknown as {
    rpc: (name: string, a: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
  };
  const { data, error } = await rpc.rpc('create_child_crew_inheriting_responsibility_for_actor', {
    p_parent_crew_conversation_id: ctx.conversationId,
    p_actor_user_id: ctx.userId,
    p_title: name,
    p_created_by_kind: 'captain',
    p_created_by_bot_id: ctx.botId,
  });
  if (error) {
    return JSON.stringify({ error: 'failed to create child crew', detail: error.message });
  }
  const childCrewId = typeof data === 'string' ? data : null;
  ctx.emit('tool_result', { name: 'create_child_crew', childCrewId });
  return JSON.stringify({
    ok: true,
    child_crew_id: childCrewId,
    note: brief
      ? '子 crew 已创建（继承本 crew 的责任份额）。它会作为独立 crew 出现，你可以在那边派 session 干这件事。'
      : '子 crew 已创建（继承本 crew 的责任份额）。',
  });
}
