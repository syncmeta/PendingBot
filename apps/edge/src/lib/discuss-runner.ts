import { randomUUID } from 'node:crypto';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { getPrompt } from '../llm/prompt-loader';

// Discuss runner — solo-audience theater of bots talking about (or around)
// the user. Per user direction:
//   - User isn't a "real" group participant; they're an anonymous lurker.
//     Their interjections land as role='log', log_kind='discuss:anon'
//     and are surfaced to bots as "[匿名插话]" — not as "user said".
//   - Each round = every still-unspoken bot speaks at most once.
//   - Within a round, all unspoken bots are fired in parallel with the
//     current shared transcript; results commit as they arrive. (Bots
//     within the same round don't see each other; they see prior rounds
//     in full.)
//   - [SILENT] = pass for this round.
//   - Total run capped by wall time (just under the Worker's 5-minute
//     hard limit) — when time's up the runner stops cleanly.
//   - User can stop anytime via POST /v1/discuss/:id/cancel which flips
//     `conversations.last_turn_status = 'cancelled'`. The runner checks
//     between every round + every bot insert.

const PERSONAL_HISTORY_LIMIT = 12;
const PASS_TOKEN = '[SILENT]';

// Worker Paid wall time hard cap is ~5 min. Leave a margin for the final
// audit + status update that runs after the loop exits.
const MAX_WALL_MS = 4 * 60 * 1000;

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

interface GroupTurn {
  role: 'bot' | 'log' | 'user' | 'human';
  content: string;
  sender_bot_id: string | null;
  log_kind: string | null;
}

async function fetchGroupHistory(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
): Promise<GroupTurn[]> {
  const { data } = await supa
    .from('messages')
    .select('role, content, sender_bot_id, log_kind, created_at')
    .eq('conversation_id', conversationId)
    .order('created_at', { ascending: true })
    .limit(200);
  return (data ?? []) as GroupTurn[];
}

async function fetchPersonalHistory(
  supa: ReturnType<typeof serviceClient>,
  userId: string,
  botId: string,
): Promise<Array<{ role: 'user' | 'bot' | 'human'; content: string }>> {
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
    .filter((m) => m.content && m.content.trim())
    .map((m) => ({ role: m.role, content: m.content as string }));
}

async function isCancelled(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
): Promise<boolean> {
  const { data } = await supa
    .from('conversations')
    .select('last_turn_status')
    .eq('id', conversationId)
    .single();
  return data?.last_turn_status === 'cancelled';
}

function formatGroupHistory(
  history: GroupTurn[],
  byId: Map<string, BotRow>,
  selfBotId: string,
): string {
  if (history.length === 0) return '（你是第一个发言的）';
  return history
    .map((m) => {
      if (m.role === 'log' && m.log_kind === 'discuss:anon') {
        return `[匿名插话] ${m.content}`;
      }
      if (m.role === 'log') return ''; // skip other log entries
      if (m.role === 'bot') {
        const speaker = byId.get(m.sender_bot_id ?? '')?.display_name ?? 'bot';
        const ownTag = m.sender_bot_id === selfBotId ? '（你自己）' : '';
        return `[${speaker}${ownTag}] ${m.content}`;
      }
      return ''; // any other roles ignored — discuss is bot+anon only
    })
    .filter(Boolean)
    .join('\n');
}

export async function runDiscuss(input: RunDiscussInput): Promise<void> {
  const { env, conversationId, userId, topic, botIds } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  // Bot lookup once. The set of participating bots is fixed for this run.
  const { data: botsData } = await supa
    .from('bots')
    .select('id, display_name, model_id')
    .in('id', botIds);
  if (!botsData?.length) return;
  const byId = new Map<string, BotRow>(botsData.map((b) => [b.id as string, b as BotRow]));
  const orderedBots = botIds.map((id) => byId.get(id)).filter((b): b is BotRow => !!b);

  // Personal histories per bot — fetched once. Mid-run additions to the
  // user_bot conv during this discuss don't change the bot's personal
  // context here; that's fine, this is just background.
  const personalById = new Map<string, Array<{ role: 'user' | 'bot' | 'human'; content: string }>>();
  await Promise.all(orderedBots.map(async (b) => {
    personalById.set(b.id, await fetchPersonalHistory(supa, userId, b.id));
  }));

  // The runner controls each in-flight openai call's AbortController so
  // we can cancel them all when wall time expires or the user cancels.
  const aborts = new Set<AbortController>();
  const cancelAll = () => {
    for (const ac of aborts) ac.abort();
    aborts.clear();
  };

  outer: while (Date.now() - startedAt < MAX_WALL_MS) {
    if (await isCancelled(supa, conversationId)) break;

    const group = await fetchGroupHistory(supa, conversationId);
    const unspoken = new Map<string, BotRow>(orderedBots.map((b) => [b.id, b]));
    let anyoneSpokeThisRound = false;

    // Fire all unspoken bots in parallel with the same snapshot of group
    // history. Each commits its own reply (or is a [SILENT] no-op) when
    // its request finishes.
    const calls = [...unspoken.values()].map((bot) => {
      const ac = new AbortController();
      aborts.add(ac);

      const personal = personalById.get(bot.id) ?? [];
      const personalBlock = personal.length > 0
        ? `## 你和对方最近的对话\n${personal.map((m) => `${m.role === 'bot' ? '我' : '对方'}：${m.content}`).join('\n')}`
        : '## 你和对方最近的对话\n（暂无历史）';
      const groupBlock = `## 群聊到目前为止\n${formatGroupHistory(group, byId, bot.id)}`;
      const sysTemplate = getPrompt('discuss');
      const systemPrompt = sysTemplate.replace(/\{\{bot_display_name\}\}/g, bot.display_name);
      const userMsg = [`## 议题\n${topic}`, personalBlock, groupBlock].join('\n\n');

      const openai = openrouterClient(env);
      const turnStart = Date.now();
      return openai.chat.completions
        .create(
          {
            model: bot.model_id,
            messages: [
              { role: 'system', content: systemPrompt },
              { role: 'user', content: userMsg },
            ],
          },
          { signal: ac.signal },
        )
        .then(async (completion) => {
          aborts.delete(ac);
          const text = (completion.choices[0]?.message?.content ?? '').trim();
          const action = !text || text === PASS_TOKEN ? 'pass' : 'reply';
          const usage = completion.usage;

          if (action === 'reply') {
            anyoneSpokeThisRound = true;
            await supa.from('messages').insert({
              client_message_id: randomUUID(),
              conversation_id: conversationId,
              sender_bot_id: bot.id,
              role: 'bot',
              status: 'done',
              content: text,
            });
          }

          await supa.from('audit_log').insert({
            user_id: userId,
            conversation_id: conversationId,
            task_type: 'discuss',
            model_id: bot.model_id,
            input_tokens: usage?.prompt_tokens ?? 0,
            output_tokens: usage?.completion_tokens ?? 0,
            total_tokens: usage?.total_tokens ?? 0,
            generation_id: completion.id,
            latency_ms: Date.now() - turnStart,
            metadata: { bot_id: bot.id, action },
          });
        })
        .catch((err) => {
          aborts.delete(ac);
          // AbortError when wall time / user cancel kicked in. Anything
          // else: log + continue (one bot's failure doesn't kill the run).
          if (!ac.signal.aborted) {
            console.warn('[discuss] bot failed', bot.id, err);
          }
        });
    });

    // Walltime watchdog: race round against remaining wall budget.
    const remaining = MAX_WALL_MS - (Date.now() - startedAt);
    if (remaining <= 0) {
      cancelAll();
      break outer;
    }
    let timeout: ReturnType<typeof setTimeout> | null = null;
    const watchdog = new Promise<'timeout'>((resolve) => {
      timeout = setTimeout(() => resolve('timeout'), remaining);
    });
    const winner = await Promise.race([
      Promise.allSettled(calls).then(() => 'done' as const),
      watchdog,
    ]);
    if (timeout) clearTimeout(timeout);
    if (winner === 'timeout') {
      cancelAll();
      break outer;
    }

    // After-round cancel + termination checks.
    if (await isCancelled(supa, conversationId)) break;

    // Natural terminate: a full round of [SILENT]s — nobody had anything
    // fresh to add (they all saw the same context, including each other's
    // prior-round contributions, and chose to pass).
    if (!anyoneSpokeThisRound) break;
  }

  // Final status. Don't overwrite an existing 'cancelled'.
  await supa
    .from('conversations')
    .update({ last_turn_status: 'done' })
    .eq('id', conversationId)
    .neq('last_turn_status', 'cancelled');
}
