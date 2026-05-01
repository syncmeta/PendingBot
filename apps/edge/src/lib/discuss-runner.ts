import { randomUUID } from 'node:crypto';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { getPrompt } from '../llm/prompt-loader';

// Discuss runner — multi-bot group chat about a single user, user is in the
// room as observer (read-only). Per plan/02 and prompts/discuss.md:
//   - all bots see prior bot turns in the discuss conv
//   - each bot also gets its own per-user chat history (the user_bot conv
//     between this bot and this user) as private context
//   - "[PASS]" output means "I have nothing fresh to add" → skip insert
//
// Worker runs the conversation autonomously after a single client trigger:
// loops "rounds" (each round = every selected bot speaks at most once)
// until either:
//   - all selected bots PASSed the entire round (nothing fresh) — natural
//     terminate
//   - MAX_ROUNDS hit
//   - the conversation row's `last_turn_status` flipped to 'cancelled'
//     by the client (POST /v1/discuss/:id/cancel)
//
// Each bot's reply is INSERTed into pendingbot.messages, which is in the
// supabase_realtime publication — the client's conv channel auto-receives
// each bubble live. No SSE on this path; per plan/03 long async tasks
// belong to the Realtime path.

// How many messages of the bot's *personal* history with this user to
// include as private context. Keep tight — discuss is about reactions, not
// re-litigating every prior conversation.
const PERSONAL_HISTORY_LIMIT = 12;
const PASS_TOKEN = '[PASS]';
const MAX_ROUNDS = 6;

export interface RunDiscussInput {
  env: Env;
  conversationId: string;
  userId: string;
  topic: string;
  botIds: string[];
}

interface BotRow {
  id: string;
  display_name: string;
  model_id: string;
}

async function fetchPersonalHistory(
  supa: ReturnType<typeof serviceClient>,
  userId: string,
  botId: string,
): Promise<Array<{ role: 'user' | 'bot' | 'human'; content: string }>> {
  // The user-bot conv between (this user, this bot). Convention: a single
  // canonical user_bot conv per (user, bot). If multiple, we just pick the
  // most recent.
  const { data: convs } = await supa
    .from('conversations')
    .select('id')
    .eq('user_id', userId)
    .eq('bot_id', botId)
    .eq('conversation_type', 'user_bot')
    .order('updated_at', { ascending: false })
    .limit(1);
  const convId = convs?.[0]?.id as string | undefined;
  if (!convId) return [];

  const { data: msgs } = await supa
    .from('messages')
    .select('role, content')
    .eq('conversation_id', convId)
    .neq('role', 'log')
    .order('created_at', { ascending: false })
    .limit(PERSONAL_HISTORY_LIMIT);
  const out = (msgs ?? []).reverse() as Array<{
    role: 'user' | 'bot' | 'human';
    content: string | null;
  }>;
  return out
    .filter((m) => m.content && m.content.trim().length > 0)
    .map((m) => ({ role: m.role, content: m.content as string }));
}

export async function runDiscuss(input: RunDiscussInput): Promise<void> {
  const { env, conversationId, userId, topic, botIds } = input;
  const supa = serviceClient(env);

  // Lookup bot rows in one shot.
  const { data: botsData, error: botErr } = await supa
    .from('bots')
    .select('id, display_name, model_id')
    .in('id', botIds);
  if (botErr || !botsData?.length) {
    console.warn('[discuss-runner] no bots found', botErr);
    return;
  }
  // Preserve caller-specified bot order.
  const byId = new Map<string, BotRow>(botsData.map((b) => [b.id as string, b as BotRow]));
  const orderedBots = botIds.map((id) => byId.get(id)).filter((b): b is BotRow => !!b);

  // Pull existing discuss messages (this conv only). Both prior rounds and
  // any user "辟谣 / 注入观点" interjections.
  const { data: priorMsgs } = await supa
    .from('messages')
    .select('role, content, sender_bot_id')
    .eq('conversation_id', conversationId)
    .neq('role', 'log')
    .order('created_at', { ascending: true })
    .limit(200);
  const groupHistory = (priorMsgs ?? []) as Array<{
    role: 'user' | 'bot' | 'human';
    content: string | null;
    sender_bot_id: string | null;
  }>;

  const openai = openrouterClient(env);

  // Multi-round loop. Re-check cancel between bots and between rounds.
  let consecutivePassRound = 0;
  outer:
  for (let round = 0; round < MAX_ROUNDS; round++) {
    let anyoneSpoke = false;

    for (const bot of orderedBots) {
      // Cancel check — runs both between rounds and between bots within a
      // round. Latency between cancel signal and stop ≤ one bot's LLM call.
      const { data: convRow } = await supa
        .from('conversations')
        .select('last_turn_status')
        .eq('id', conversationId)
        .single();
      if (convRow?.last_turn_status === 'cancelled') break outer;

    const startedAt = Date.now();
    try {
      const personal = await fetchPersonalHistory(supa, userId, bot.id);

      // System prompt with bot display name substituted.
      const sysTemplate = getPrompt('discuss');
      const systemPrompt = sysTemplate.replace(/\{\{bot_display_name\}\}/g, bot.display_name);

      // Format the group chat as a single user message. Each bot turn is
      // tagged with its display_name (own turns get an extra marker so the
      // model knows which lines are itself).
      const groupLines = groupHistory.map((m) => {
        if (m.role === 'bot') {
          const speakerName = byId.get(m.sender_bot_id ?? '')?.display_name ?? 'bot';
          const ownTag = m.sender_bot_id === bot.id ? '（你自己）' : '';
          return `[${speakerName}${ownTag}] ${m.content ?? ''}`;
        }
        return `[用户辟谣 / 注入观点] ${m.content ?? ''}`;
      });

      const groupBlock = groupLines.length > 0
        ? `## 群聊到目前为止\n${groupLines.join('\n')}`
        : '## 群聊到目前为止\n（你是第一个发言的）';

      const personalBlock = personal.length > 0
        ? `## 你和对方最近的对话\n${personal.map((m) => `${m.role === 'bot' ? '我' : '对方'}：${m.content}`).join('\n')}`
        : '## 你和对方最近的对话\n（暂无历史）';

      const userMsg = [
        `## 议题\n${topic}`,
        personalBlock,
        groupBlock,
      ].join('\n\n');

      const completion = await openai.chat.completions.create({
        model: bot.model_id,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userMsg },
        ],
      });
      const text = (completion.choices[0]?.message?.content ?? '').trim();

      // PASS = bot opts out for this round; do not write a message.
      if (!text || text === PASS_TOKEN) {
        await supa.from('audit_log').insert({
          user_id: userId,
          conversation_id: conversationId,
          task_type: 'discuss',
          model_id: bot.model_id,
          input_tokens: completion.usage?.prompt_tokens ?? 0,
          output_tokens: completion.usage?.completion_tokens ?? 0,
          total_tokens: completion.usage?.total_tokens ?? 0,
          generation_id: completion.id,
          latency_ms: Date.now() - startedAt,
          metadata: { bot_id: bot.id, action: 'pass', round },
        });
        continue;
      }
      anyoneSpoke = true;

      // Insert bot message + append to running group history so subsequent
      // bots in this same round see it.
      const inserted = {
        client_message_id: randomUUID(),
        conversation_id: conversationId,
        sender_bot_id: bot.id,
        role: 'bot' as const,
        status: 'done' as const,
        content: text,
      };
      await supa.from('messages').insert(inserted);
      groupHistory.push({
        role: 'bot',
        content: text,
        sender_bot_id: bot.id,
      });

      await supa.from('audit_log').insert({
        user_id: userId,
        conversation_id: conversationId,
        task_type: 'discuss',
        model_id: bot.model_id,
        input_tokens: completion.usage?.prompt_tokens ?? 0,
        output_tokens: completion.usage?.completion_tokens ?? 0,
        total_tokens: completion.usage?.total_tokens ?? 0,
        generation_id: completion.id,
        latency_ms: Date.now() - startedAt,
        metadata: { bot_id: bot.id, action: 'reply', round },
      });
    } catch (err) {
      console.error('[discuss-runner] bot failed', bot.id, err);
      // Continue with the next bot — one bot's failure doesn't kill the round.
    }
    } // end inner for-bots

    // Natural terminate: full round of PASSes ⇒ everyone has nothing fresh.
    if (!anyoneSpoke) {
      consecutivePassRound++;
      if (consecutivePassRound >= 1) break;
    } else {
      consecutivePassRound = 0;
    }
  } // end outer for-rounds

  // Mark conv terminal (so cancel polling on the next call sees clean state).
  await supa
    .from('conversations')
    .update({ last_turn_status: 'done' })
    .eq('id', conversationId);
}
