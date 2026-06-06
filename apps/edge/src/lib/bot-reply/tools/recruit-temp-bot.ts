// `recruit_temp_bot` — spec §6.4 captain duty "拉临时 bot 进 crew".
//
// The crew CAPTAIN pulls a TEMPORARY (ephemeral) bot into the crew as a
// non-responsibility-bearing participant. We verify this conversation is an
// active crew and this bot is its captain, then insert one
// temporary_group_members row with member_kind='ephemeral_bot'.
//
// Why a plain service-role INSERT and not an RPC:
//   * The temporary_group_members CHECK constraint for member_kind='ephemeral_bot'
//     requires user_id / bot_id / code_session_id all NULL — an ephemeral bot is
//     NOT a reference to a registered bots row; it's a free-standing participant
//     described by display_name + ephemeral_spec (the bot's persona / model).
//   * There are NO triggers on temporary_group_members (verified across every
//     migration), so no trigger logic is bypassed by inserting directly.
//   * service_role holds INSERT on the table and RLS does not apply to it.
//   * Unlike human / registered_bot / captain members, an ephemeral_bot has no
//     id to register in conversation_participants (participant_type only allows
//     'user' / 'bot'), so it is roster-only by design — there is no extra row a
//     dedicated RPC would have to write atomically. A bare insert is the whole
//     operation, so wrapping it in an RPC would add nothing.
//
// The captain (member_kind='captain') is recorded as inviter via
// invited_by_member_id so the roster shows who pulled the temp bot in.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import type { ToolCtx } from '../tool-runner';

const NAME_MAX = 80;
const PERSONA_MAX = 2_000;
const MODEL_MAX = 200;

export async function recruitTempBotTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const name = typeof args.name === 'string' ? args.name.trim() : '';
  if (!name) return JSON.stringify({ error: 'name required' });
  if (name.length > NAME_MAX) {
    return JSON.stringify({ error: `name exceeds ${NAME_MAX} chars` });
  }
  const persona = typeof args.persona === 'string' ? args.persona.trim() : '';
  if (persona.length > PERSONA_MAX) {
    return JSON.stringify({ error: `persona exceeds ${PERSONA_MAX} chars` });
  }
  const modelSlug = typeof args.model_slug === 'string' ? args.model_slug.trim() : '';
  if (modelSlug.length > MODEL_MAX) {
    return JSON.stringify({ error: `model_slug exceeds ${MODEL_MAX} chars` });
  }

  const supa = serviceClient(env);
  const { data: meta, error: metaErr } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, captain_bot_id, temporary_kind, status')
    .eq('conversation_id', ctx.conversationId)
    .maybeSingle();
  if (metaErr) return JSON.stringify({ error: 'database_error', detail: metaErr.message });
  if (!meta || meta.temporary_kind !== 'crew' || meta.status !== 'active') {
    return JSON.stringify({ error: 'recruit_temp_bot only works inside an active crew' });
  }
  if (meta.captain_bot_id !== ctx.botId) {
    return JSON.stringify({ error: 'only the crew captain can recruit temp bots' });
  }

  // Resolve the captain's own member row to attribute the invite. Also serves
  // as a sanity check that the captain is actually seated in this crew.
  const { data: captainMember, error: capErr } = await supa
    .from('temporary_group_members')
    .select('id')
    .eq('conversation_id', ctx.conversationId)
    .eq('member_kind', 'captain')
    .eq('bot_id', ctx.botId)
    .eq('status', 'active')
    .order('created_at', { ascending: true })
    .limit(1)
    .maybeSingle();
  if (capErr) return JSON.stringify({ error: 'database_error', detail: capErr.message });
  if (!captainMember) {
    return JSON.stringify({ error: 'captain member row not found' });
  }

  // No DB-level uniqueness covers ephemeral_bot rows, so dedupe by display
  // name in code: refuse a second active temp bot with the same name.
  const { data: dupe, error: dupeErr } = await supa
    .from('temporary_group_members')
    .select('id')
    .eq('conversation_id', ctx.conversationId)
    .eq('member_kind', 'ephemeral_bot')
    .eq('status', 'active')
    .eq('display_name', name)
    .limit(1)
    .maybeSingle();
  if (dupeErr) return JSON.stringify({ error: 'database_error', detail: dupeErr.message });
  if (dupe) {
    return JSON.stringify({ error: `已有同名临时 bot「${name}」在 crew 里` });
  }

  const ephemeralSpec: Record<string, string> = { recruited_by: 'captain' };
  if (persona) ephemeralSpec.persona = persona;
  if (modelSlug) ephemeralSpec.model_slug = modelSlug;

  const { data: inserted, error: insErr } = await supa
    .from('temporary_group_members')
    .insert({
      conversation_id: ctx.conversationId,
      member_kind: 'ephemeral_bot',
      display_name: name,
      role: 'member',
      status: 'active',
      ephemeral_spec: ephemeralSpec,
      invited_by_member_id: captainMember.id,
    })
    .select('id')
    .single();
  if (insErr) {
    return JSON.stringify({ error: 'failed to recruit temp bot', detail: insErr.message });
  }

  const memberId = inserted?.id ?? null;
  ctx.emit('tool_result', { name: 'recruit_temp_bot', memberId });
  return JSON.stringify({
    ok: true,
    member_id: memberId,
    note: `临时 bot「${name}」已拉进 crew（不承担责任份额，纯参与者）。`,
  });
}
