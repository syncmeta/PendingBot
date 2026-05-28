// `start_crew` — bot proposes a new crew (spec v2 §6.4).
//
// The bot decides "this needs a crew" and calls this tool. We do NOT
// invoke `create_crew_with_captain` directly — that would let a hallucinating
// model bypass human sign-off and burn the user's wallet. Instead we drop
// a special "crew proposal" message into the current conversation:
//
//   role='log', log_kind='crew_proposal', log_payload = {
//     proposed_by_bot_id, proposed_name, proposed_tag,
//     proposed_working_directory, proposed_parent_crew_id,
//     proposed_initial_brief, status: 'pending'
//   }
//
// iOS renders this as a confirmation card (PendingBot only — Mac
// PendingCrew doesn't subscribe to user_bot conversation timelines).
// The human taps 确认创建 / 拒绝 to drive POST /v1/messages/:id/crew-proposal/decide,
// which is the only path that actually calls create_crew_with_captain.
//
// The tool returns a short note (loaded from prompt-loader) telling the
// model to stop and wait — no auto-follow-up turn, no crew-mention until
// the user pings back.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { uuidv7 } from '../../ids';
import { getPrompt } from '../../../llm/prompt-loader';
import type { ToolCtx } from '../tool-runner';

const NAME_MAX = 80;
const TAG_MAX = 80;
const WORKING_DIR_MAX = 2048;
const BRIEF_MAX = 4_000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function trimOrUndefined(value: unknown, max: number): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > max) return undefined;
  return trimmed;
}

export async function startCrewTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const rawName = typeof args.name === 'string' ? args.name.trim() : '';
  if (!rawName) return JSON.stringify({ error: 'empty name' });
  if (rawName.length > NAME_MAX) {
    return JSON.stringify({ error: `name exceeds ${NAME_MAX} chars` });
  }

  const tag = trimOrUndefined(args.tag, TAG_MAX);
  const workingDirectory = trimOrUndefined(args.working_directory, WORKING_DIR_MAX);
  const initialBrief = trimOrUndefined(args.initial_brief, BRIEF_MAX);

  let parentCrewId: string | undefined;
  if (typeof args.parent_crew_id === 'string' && args.parent_crew_id.trim() !== '') {
    const p = args.parent_crew_id.trim();
    if (!UUID_RE.test(p)) {
      return JSON.stringify({ error: 'parent_crew_id must be a uuid' });
    }
    parentCrewId = p;
  }

  const supa = serviceClient(env);

  // Pre-flight: the conversation must exist and have at least one human
  // participant. start_crew in a bot-only / self conv would have nobody
  // to approve it; in that case we'd rather error here than file a
  // proposal that can never be decided. (One human is enough — the
  // approver picks themselves.)
  const { data: convRow, error: convErr } = await supa
    .from('conversations')
    .select('id, conversation_type')
    .eq('id', ctx.conversationId)
    .maybeSingle();
  if (convErr) {
    return JSON.stringify({ error: `conversation lookup failed: ${convErr.message}` });
  }
  if (!convRow) {
    return JSON.stringify({ error: 'conversation not found' });
  }
  const convType = (convRow.conversation_type as string | undefined) ?? '';
  if (convType !== 'user_bot' && convType !== 'group') {
    return JSON.stringify({
      error: `start_crew is only available in user↔bot or group conversations (got conversation_type=${convType})`,
    });
  }

  const payload = {
    proposed_by_bot_id: ctx.botId,
    proposed_name: rawName,
    proposed_tag: tag ?? null,
    proposed_working_directory: workingDirectory ?? null,
    proposed_parent_crew_id: parentCrewId ?? null,
    proposed_initial_brief: initialBrief ?? null,
    status: 'pending',
    proposed_at: new Date().toISOString(),
  };

  const messageId = uuidv7();
  const { error: insertErr } = await supa.from('messages').insert({
    id: messageId,
    client_message_id: messageId,
    conversation_id: ctx.conversationId,
    sender_bot_id: ctx.botId,
    role: 'log',
    log_kind: 'crew_proposal',
    log_payload: payload,
    // The log row's `content` is intentionally a short human-readable
    // fallback — clients that don't know about crew_proposal yet just
    // see "Bot 提议创建 crew '<name>'" plain text instead of a blank row.
    content: `提议创建 crew「${rawName}」`,
    status: 'done',
  });
  if (insertErr) {
    return JSON.stringify({ error: `proposal insert failed: ${insertErr.message}` });
  }

  ctx.emit('tool_call', {
    name: 'start_crew',
    proposed_name: rawName,
  });
  ctx.emit('tool_result', {
    name: 'start_crew',
    message_id: messageId,
    proposed_name: rawName,
    status: 'pending',
  });

  // Note to the LLM — read from prompt-loader. We do a {{name}} substitution
  // so the model sees the actual proposed name, not a literal placeholder.
  const noteTemplate = getPrompt('start-crew-tool-result');
  const note = noteTemplate.replace(/\{\{name\}\}/g, rawName);

  return JSON.stringify({
    status: 'pending',
    proposal_message_id: messageId,
    proposed_name: rawName,
    note,
  });
}
