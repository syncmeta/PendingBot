// `request_permission` — spec v2 §10 agent-side tool.
//
// Two call paths converge on this file:
//
//   1) Dominant path: PendingCrew runner detects the agent (Claude Code /
//      Codex) emitting a tool call named `request_permission` →
//      PendingCrew translates it into an HTTP POST against
//      /v1/sessions/:sessionId/request-permission (see routes/crew-comms.ts).
//      The agent lives outside bot-reply, so it doesn't enter this file.
//
//   2) bot-reply variant: a captain (or any bot) mid bot-reply decides
//      it wants to drop a permission-request card before doing a high-risk
//      operation it's about to perform via another tool call. We look up
//      the captain's active crew session and call the same
//      create_permission_request RPC. If the bot isn't a captain (no active
//      crew session bound to it), we surface an error envelope so the
//      model knows this tool isn't available in the current context.
//
// Spec v2 §10 notes:
//   * The agent decides what counts as "high risk"; we don't gate it
//     here.
//   * Even in manual mode v1 doesn't actually pause the agent — that's
//     T4.5 peer_device territory. The tool just files the card; the
//     prompt-side note (request-permission-tool-result.md) tells the
//     agent not to execute the underlying action until it sees the
//     status flip.

import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { getPrompt } from '../../../llm/prompt-loader';
import type { ToolCtx } from '../tool-runner';

const ACTION_MAX = 400;
const RISK_LEVELS = ['low', 'medium', 'high'] as const;
type RiskLevel = (typeof RISK_LEVELS)[number];

function pickRisk(raw: unknown): RiskLevel {
  if (typeof raw !== 'string') return 'medium';
  return (RISK_LEVELS as readonly string[]).includes(raw) ? (raw as RiskLevel) : 'medium';
}

function pickDetails(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  return {};
}

type UntypedRpc = {
  rpc: (
    name: string,
    args?: Record<string, unknown>,
  ) => Promise<{ data: unknown; error: { message: string; code?: string } | null }>;
};

export async function requestPermissionTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const action = typeof args.action === 'string' ? args.action.trim() : '';
  if (!action) return JSON.stringify({ error: 'action required' });
  if (action.length > ACTION_MAX) {
    return JSON.stringify({ error: `action exceeds ${ACTION_MAX} chars` });
  }
  const details = pickDetails(args.details);
  const risk = pickRisk(args.risk_level);

  const supa = serviceClient(env);

  // Confirm we're in a crew context. The bot-reply tool path only makes
  // sense if there's a crew + an active session bound to this bot acting
  // as captain. (For non-captain bots in a crew there's no session to
  // bind to — those should use other channels.)
  const { data: meta, error: metaErr } = await supa
    .from('temporary_group_meta')
    .select('conversation_id, responsible_subject_id, status, temporary_kind, captain_bot_id')
    .eq('conversation_id', ctx.conversationId)
    .maybeSingle();
  if (metaErr) {
    return JSON.stringify({ error: 'lookup failed', detail: metaErr.message });
  }
  if (!meta || meta.temporary_kind !== 'crew' || meta.status !== 'active') {
    return JSON.stringify({
      error: 'request_permission may only be called inside an active crew conversation',
    });
  }

  // Find the bot's active session in this crew. We require the bot to be
  // the captain (captain_bot_id match) AND have an active session
  // claimed by the captain's member row.
  if (meta.captain_bot_id !== ctx.botId) {
    return JSON.stringify({
      error: 'request_permission is only available to the crew captain',
    });
  }

  const { data: memberRow, error: memberErr } = await supa
    .from('temporary_group_members')
    .select('id')
    .eq('conversation_id', ctx.conversationId)
    .eq('bot_id', ctx.botId)
    .eq('status', 'active')
    .maybeSingle();
  if (memberErr) {
    return JSON.stringify({ error: 'member lookup failed', detail: memberErr.message });
  }
  if (!memberRow) {
    return JSON.stringify({
      error: 'no active member row for captain — cannot bind permission request to a session',
    });
  }

  const { data: sessionRows, error: sessErr } = await supa
    .from('crew_sessions')
    .select('id, status, created_at')
    .eq('crew_conversation_id', ctx.conversationId)
    .eq('assigned_to_member_id', memberRow.id)
    .in('status', ['queued', 'running', 'waiting_permission', 'blocked'])
    .order('created_at', { ascending: false })
    .limit(1);
  if (sessErr) {
    return JSON.stringify({ error: 'session lookup failed', detail: sessErr.message });
  }
  const sessionRow = sessionRows?.[0];
  if (!sessionRow) {
    return JSON.stringify({
      error: 'captain has no active crew session — request_permission needs an active session to bind to',
    });
  }

  const rpcClient = supa as unknown as UntypedRpc;
  const { data, error } = await rpcClient.rpc('create_permission_request', {
    p_session_id: sessionRow.id,
    p_action: action,
    p_payload: details,
    p_risk_level: risk,
  });
  if (error) {
    return JSON.stringify({
      error: 'create_permission_request failed',
      detail: error.message,
    });
  }

  const permissionRequestId = typeof data === 'string' ? data : null;

  ctx.emit('tool_result', {
    name: 'request_permission',
    permission_request_id: permissionRequestId,
    action,
    risk_level: risk,
  });

  const noteTemplate = getPrompt('request-permission-tool-result');
  const note = noteTemplate.replace(/\{\{action\}\}/g, action);

  return JSON.stringify({
    status: 'pending',
    permission_request_id: permissionRequestId,
    action,
    risk_level: risk,
    note,
  });
}
