import { randomUUID } from 'node:crypto';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { buildMessages, type BuildMessagesInput } from '../llm/builder';
import { getBotMemory, refreshBotMemory, refreshUserMemory } from './memory';
import {
  honchoClient,
  userPeerId,
  botPeerId,
  conversationSessionId,
} from './honcho';

// How many bot_reflections rows to read for the self section. The schema's
// idx_reflections_bot_user_time covers this exact (bot_id, user_id, created_at)
// access pattern. 12 follows plan/02 and keeps prompt size bounded.
const REFLECTIONS_LIMIT = 12;

// Flush throttle: every FLUSH_MS or FLUSH_CHARS, whichever comes first.
// Tuned for "feels live" vs "don't hammer Postgres".
const FLUSH_MS = 80;
const FLUSH_CHARS = 24;

// Stop-poll cadence: every STOP_POLL_MS in wall time, re-read stop_requested
// on the bot row. ~80ms cross-cloud → 200ms cadence ≈ 5 reads/sec, fine.
const STOP_POLL_MS = 200;

export interface GenerateBotReplyInput {
  env: Env;
  conversationId: string;
  parentMessageId: string;
  userId: string;
  bot: {
    id: string;
    model_id: string;
    output_mode: 'single' | 'bubble';
  };
  recentContext: BuildMessagesInput['recentContext'];
  newMessage: string;
}

// Run the LLM call and stream tokens into a bot row via throttled UPDATE.
// Designed for `ctx.waitUntil(...)`: rejections are caught and written to
// the row's status, never propagated.
export async function generateBotReply(input: GenerateBotReplyInput): Promise<void> {
  const { env, conversationId, parentMessageId, userId, bot, recentContext, newMessage } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  // Self-section + skills inputs are read in parallel with prompt-build.
  // All fall back gracefully (null memory + empty reflections + no skills →
  // identity quest, no skills section).
  const [botMemory, reflectionsRes, skillsRes] = await Promise.all([
    getBotMemory(env, bot.id),
    supa
      .from('bot_reflections')
      .select('kind, content')
      .eq('bot_id', bot.id)
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(REFLECTIONS_LIMIT),
    // Skills the user has installed for this conv (sub.conversation_id =
    // conv) OR globally (sub.conversation_id IS NULL). The OR filter is
    // expressed via PostgREST's `or=(...)` syntax.
    supa
      .from('skill_subscriptions')
      .select('skills(frontmatter, body_md)')
      .eq('user_id', userId)
      .or(`conversation_id.eq.${conversationId},conversation_id.is.null`),
  ]);
  const reflections = (reflectionsRes.data ?? []) as Array<{
    kind: 'limit' | 'grow' | 'keep';
    content: string;
  }>;
  // PostgREST returns the joined `skills` row as an array even for an FK
  // many-to-one — flatten it.
  type SkillRow = {
    frontmatter: { name?: string; description?: string };
    body_md: string;
  };
  const skills: Array<{ name: string; description: string; body: string }> = [];
  for (const row of skillsRes.data ?? []) {
    const joined = (row as { skills: SkillRow | SkillRow[] | null }).skills;
    const arr = Array.isArray(joined) ? joined : joined ? [joined] : [];
    for (const s of arr) {
      skills.push({
        name: s.frontmatter?.name ?? 'unnamed',
        description: s.frontmatter?.description ?? '',
        body: s.body_md,
      });
    }
  }

  // 1. Insert pending bot row. UUIDv7 in client_message_id keeps ordering
  // stable even if our INSERT lands microseconds before/after a sibling.
  const clientMessageId = randomUUID();
  const { data: botRow, error: insertErr } = await supa
    .from('messages')
    .insert({
      client_message_id: clientMessageId,
      conversation_id: conversationId,
      sender_bot_id: bot.id,
      role: 'bot',
      status: 'streaming',
      parent_message_id: parentMessageId,
      content_partial: '',
    })
    .select('id')
    .single();
  if (insertErr || !botRow) {
    console.error('[bot-reply] insert failed', insertErr);
    return;
  }
  const botMessageId = botRow.id as string;

  // 2. Build prompt + open stream.
  const openai = openrouterClient(env);
  let buf = '';
  let lastFlushAt = Date.now();
  let lastFlushLen = 0;
  let lastStopPollAt = Date.now();
  let stopRequested = false;
  let usage: { input?: number; output?: number; total?: number } = {};
  let generationId: string | undefined;

  const ac = new AbortController();

  try {
    const stream = await openai.chat.completions.create(
      {
        model: bot.model_id,
        messages: buildMessages({
          bot,
          botMemory,
          reflections,
          skills,
          recentContext,
          newMessage,
        }),
        stream: true,
        stream_options: { include_usage: true },
      },
      { signal: ac.signal },
    );

    for await (const chunk of stream) {
      // OpenRouter sometimes injects an `id` on the first chunk we can use as
      // the upstream generation id (for billing reconciliation).
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const cid = (chunk as any).id as string | undefined;
      if (cid && !generationId) generationId = cid;

      const delta = chunk.choices?.[0]?.delta?.content ?? '';
      if (delta) buf += delta;

      // Final usage chunk (when stream_options.include_usage is set) carries
      // an empty delta but a populated `usage` object.
      if (chunk.usage) {
        usage = {
          input: chunk.usage.prompt_tokens,
          output: chunk.usage.completion_tokens,
          total: chunk.usage.total_tokens,
        };
      }

      const now = Date.now();
      if (
        delta &&
        (buf.length - lastFlushLen >= FLUSH_CHARS || now - lastFlushAt >= FLUSH_MS)
      ) {
        await supa
          .from('messages')
          .update({ content_partial: buf })
          .eq('id', botMessageId);
        lastFlushAt = now;
        lastFlushLen = buf.length;
      }

      if (now - lastStopPollAt >= STOP_POLL_MS) {
        const { data: row } = await supa
          .from('messages')
          .select('stop_requested')
          .eq('id', botMessageId)
          .single();
        lastStopPollAt = now;
        if (row?.stop_requested) {
          stopRequested = true;
          ac.abort();
          break;
        }
      }
    }

    // 3. Finalize: copy buffer into content, clear partial, set terminal status.
    const finalStatus = stopRequested ? 'interrupted' : 'done';
    await supa
      .from('messages')
      .update({
        content: buf,
        content_partial: null,
        status: finalStatus,
        updated_at: new Date().toISOString(),
      })
      .eq('id', botMessageId);

    // 4. Audit. Best-effort — failure here doesn't affect message visibility.
    await supa.from('audit_log').insert({
      conversation_id: conversationId,
      task_type: 'message_reply',
      model_id: bot.model_id,
      input_tokens: usage.input ?? 0,
      output_tokens: usage.output ?? 0,
      total_tokens: usage.total ?? 0,
      generation_id: generationId,
      latency_ms: Date.now() - startedAt,
      metadata: { bot_id: bot.id, status: finalStatus },
    });

    // 5. Honcho ingest + cache refresh. Both peers observe_me=true so the
    // user→bot turn pair updates each side's representation. We feed Honcho
    // the literal turn (user message + bot reply) into the conv session,
    // then trigger an async refresh of both KV caches. All best-effort.
    if (finalStatus === 'done' && buf) {
      try {
        const honcho = honchoClient(env);
        const session = await honcho.session(conversationSessionId(conversationId));
        await session.addMessages([
          { peerId: userPeerId(userId), content: newMessage },
          { peerId: botPeerId(bot.id), content: buf },
        ]);
      } catch (err) {
        console.warn('[bot-reply] honcho ingest failed', err);
      }
      // Refresh both caches in parallel; failure leaves prior KV intact.
      await Promise.all([
        refreshUserMemory(env, userId),
        refreshBotMemory(env, bot.id),
      ]);
    }
  } catch (err) {
    // Network drop, model error, abort-without-stop, etc. Mark errored and
    // surface what we have so the client UI doesn't get stuck on 'streaming'.
    const isAbortFromStop = stopRequested && (err as { name?: string })?.name === 'AbortError';
    const status = isAbortFromStop ? 'interrupted' : 'error';
    console.error('[bot-reply]', status, err);
    await supa
      .from('messages')
      .update({
        content: buf || null,
        content_partial: null,
        status,
        updated_at: new Date().toISOString(),
      })
      .eq('id', botMessageId);
  }
}
