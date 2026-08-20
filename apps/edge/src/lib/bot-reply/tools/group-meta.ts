import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import type { ToolCtx } from '../tool-runner';

// Group-only — bot tells the system "call me <X> in this group". The
// underlying RPC enforces nickname uniqueness within the conv via a
// partial UNIQUE index, so the tool surfaces a clean error string the
// model can fall back from. Empty string clears the per-group
// nickname (revert to display_name).
export async function setMyGroupNicknameTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const nickname = String(args.nickname ?? '');
  ctx.emit('tool_call', { name: 'set_my_group_nickname', nickname });
  const supa = serviceClient(env);
  const { error } = await supa.rpc('group_set_bot_nickname', {
    p_conv_id: ctx.conversationId,
    p_bot_id: ctx.botId,
    p_nickname: nickname,
  });
  if (error) {
    ctx.emit('tool_result', { name: 'set_my_group_nickname', error: error.message });
    return JSON.stringify({ ok: false, error: error.message });
  }
  ctx.emit('tool_result', { name: 'set_my_group_nickname', ok: true });
  return JSON.stringify({ ok: true });
}

// Group-only — bot rewrites its own "when to call me" doc.
// `revision_count` increments on the upsert so the next call sees a
// higher number, which the system prompt warns the bot about.
export async function setBotGroupDescriptionTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const description = String(args.description ?? '').trim();
  if (!description) {
    return JSON.stringify({ ok: false, error: 'description must not be empty' });
  }
  ctx.emit('tool_call', { name: 'set_bot_group_description', chars: description.length });
  const supa = serviceClient(env);
  const { error } = await supa.rpc('group_set_bot_description', {
    p_conv_id: ctx.conversationId,
    p_bot_id: ctx.botId,
    p_description: description,
  });
  if (error) {
    ctx.emit('tool_result', { name: 'set_bot_group_description', error: error.message });
    return JSON.stringify({ ok: false, error: error.message });
  }
  ctx.emit('tool_result', { name: 'set_bot_group_description', ok: true });
  return JSON.stringify({ ok: true });
}
