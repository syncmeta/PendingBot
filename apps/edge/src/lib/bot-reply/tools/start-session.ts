// `start_session` — spec §6.3.3 captain duty "启动 session".
//
// The crew CAPTAIN (mid bot-reply, in its crew's group chat) queues a coding
// session for the crew. We verify this conversation is an active crew and this
// bot is its captain, then call open_crew_session_by_captain which creates a
// status='queued' crew_session + the code_session member row (H1). The crew's
// local_host Mac auto-claims + runs it (PendingCrew CrewSessionWindowView).
//
// No human-confirm gate here (unlike start_crew, which spends to create a whole
// crew): the human is already chatting with the captain in the crew, and
// local_host compute is free — only the agent's LLM tokens bill the crew wallet.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import type { ToolCtx } from '../tool-runner';

const BRIEF_MAX = 4_000;

export async function startSessionTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const brief = typeof args.brief === 'string' ? args.brief.trim() : '';
  if (!brief) return JSON.stringify({ error: 'brief required' });
  if (brief.length > BRIEF_MAX) {
    return JSON.stringify({ error: `brief exceeds ${BRIEF_MAX} chars` });
  }
  const runner = args.runner === 'codex' ? 'local_codex' : 'local_claude_code';

  const supa = serviceClient(env);
  const { data: meta, error: metaErr } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, captain_bot_id, temporary_kind, status')
    .eq('conversation_id', ctx.conversationId)
    .maybeSingle();
  if (metaErr) return JSON.stringify({ error: 'database_error', detail: metaErr.message });
  if (!meta || meta.temporary_kind !== 'crew' || meta.status !== 'active') {
    return JSON.stringify({ error: 'start_session only works inside an active crew' });
  }
  if (meta.captain_bot_id !== ctx.botId) {
    return JSON.stringify({ error: 'only the crew captain can start sessions' });
  }

  const rpc = supa as unknown as {
    rpc: (name: string, a: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
  };
  const { data, error } = await rpc.rpc('open_crew_session_by_captain', {
    p_crew_conversation_id: ctx.conversationId,
    p_captain_bot_id: ctx.botId,
    p_task_brief: brief,
    p_runner_kind: runner,
  });
  if (error) {
    return JSON.stringify({ error: 'failed to start session', detail: error.message });
  }
  const sessionId = typeof data === 'string' ? data : null;
  ctx.emit('tool_result', { name: 'start_session', sessionId });
  return JSON.stringify({
    ok: true,
    session_id: sessionId,
    note: '已派出 session（排队中），它会在 crew 所在机器上启动并作为成员加入群聊。',
  });
}
