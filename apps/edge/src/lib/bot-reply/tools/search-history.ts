import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import type { ToolCtx } from '../tool-runner';

// Strictly conversation-scoped search across pendingbot.messages. The
// model uses this together with the chat-memo block — the memo gives it
// pointers (time ranges, key quotes), the tool lets it pull the original
// text. Permissions piggy-back on `ctx.conversationId`: the row already
// authorized this turn is the only conv we scan, so a public bot in a
// group can only ever read that group's transcript.
//
// content_tsv on messages is a STORED generated tsvector (simple
// regconfig) — works for cjk + ascii alike via word-bounded matching.
const SEARCH_HISTORY_LIMIT_DEFAULT = 10;
const SEARCH_HISTORY_LIMIT_MAX = 30;
const SEARCH_HISTORY_SNIPPET_MAX = 400;

export async function searchChatHistoryTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const query = typeof args.query === 'string' ? args.query.trim() : '';
  const since = typeof args.since === 'string' ? args.since.trim() : '';
  const until = typeof args.until === 'string' ? args.until.trim() : '';
  const rawLimit = typeof args.limit === 'number'
    ? args.limit
    : Number(args.limit ?? NaN);
  const limit = Number.isFinite(rawLimit)
    ? Math.max(1, Math.min(SEARCH_HISTORY_LIMIT_MAX, Math.round(rawLimit)))
    : SEARCH_HISTORY_LIMIT_DEFAULT;

  if (!query && !since && !until) {
    return JSON.stringify({
      error: 'at least one of query / since / until is required',
    });
  }
  // Validate ISO dates loosely — Postgres will surface a clearer error too,
  // but a quick guard avoids a wasted round-trip.
  if (since && Number.isNaN(Date.parse(since))) {
    return JSON.stringify({ error: 'since is not a valid ISO date' });
  }
  if (until && Number.isNaN(Date.parse(until))) {
    return JSON.stringify({ error: 'until is not a valid ISO date' });
  }

  ctx.emit('tool_call', {
    name: 'search_chat_history',
    query: query || null,
    since: since || null,
    until: until || null,
    limit,
  });

  const supa = serviceClient(env);
  let q = supa
    .from('messages')
    .select('id, role, content, sender_bot_id, user_id, created_at')
    .eq('conversation_id', ctx.conversationId)
    .neq('role', 'log')
    // Drop recalled messages from LLM context — the user's intent on
    // recall is "make the model forget this ever happened", and we'd
    // otherwise feed the model rows where content was nulled (or
    // worse, stale content from before status was flipped).
    .neq('status', 'deleted')
    .not('content', 'is', null)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (query) {
    // websearch_to_tsquery handles quoted phrases, OR, NOT — most natural
    // for a model that's been told "use websearch syntax". The column
    // content_tsv is GENERATED with the simple regconfig so we match the
    // same regconfig on the query side.
    q = q.textSearch('content_tsv' as never, query, {
      type: 'websearch',
      config: 'simple',
    });
  }
  if (since) q = q.gte('created_at', since);
  if (until) q = q.lt('created_at', until);

  const { data, error } = await q;
  if (error) {
    ctx.emit('tool_result', {
      name: 'search_chat_history',
      error: error.message,
    });
    return JSON.stringify({ error: `search failed: ${error.message}` });
  }

  const rows = (data ?? []) as Array<{
    id: string;
    role: string;
    content: string | null;
    sender_bot_id: string | null;
    user_id: string | null;
    created_at: string;
  }>;

  // Sort ascending for the model's reading — newer last reads more naturally.
  const results = rows
    .slice()
    .reverse()
    .map((m) => {
      const speaker =
        m.role === 'bot' && m.sender_bot_id === ctx.botId
          ? 'me'
          : m.role === 'bot'
            ? 'bot'
            : 'them';
      const content = (m.content ?? '').slice(0, SEARCH_HISTORY_SNIPPET_MAX);
      return {
        when: m.created_at,
        speaker,
        content,
      };
    });

  ctx.emit('tool_result', {
    name: 'search_chat_history',
    count: results.length,
  });
  return JSON.stringify({
    results,
    hint: results.length === 0
      ? '没有命中。换个关键词、放宽时间范围，或者先看 chat-memo 里有没有线索。'
      : `命中 ${results.length} 条。speaker=me 是你自己说的，them 是对面用户，bot 是这个对话里别的 bot（群里才会有）。`,
  });
}
