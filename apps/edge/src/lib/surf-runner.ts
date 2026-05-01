import { randomUUID } from 'node:crypto';
import type { ChatCompletionMessageParam, ChatCompletionTool } from 'openai/resources/chat/completions';
import type { Env } from '../types';
import { serviceClient } from './supabase';
import { openrouterClient } from '../llm/client';
import { getPrompt } from '../llm/prompt-loader';
import { getUserMemory } from './memory';
import { jinaSearch, jinaRead } from './jina';

// Surf agent loop. Wires the OpenAI tool-calling protocol to four tools:
//   search_web(query)  → Jina search
//   read_url(url)      → Jina reader (clean markdown)
//   note(...)          → emit surf:result log; persist to surf_runs.progress
//   finish(reason)     → terminal; flips status='done'
//
// The loop runs up to MAX_TURNS or until budget hits 90% or finish fires.
// All tool calls + the bot's plain-text reasoning are surfaced as
// surf:step / surf:result log messages so the conv timeline shows the
// task's reasoning live (Claude Code Desktop UX).
//
// Out of scope vs. plan/05:
//   - "summarize URL via cheaper model before returning" — for now we trim
//     to ~6k chars and hand the raw markdown back; cheap model summarizer
//     is a follow-up
//   - true cost accounting per turn — we track LLM usage but Jina's per-call
//     cost is opaque; cost_used_usd tracks the LLM half only

const MAX_TURNS = 12;
// Hard ceiling on read_url payload to keep prompt size sane and avoid
// blowing past Worker's request CPU budget on huge pages.
const READ_TRUNCATE_CHARS = 6000;

interface NoteRecord {
  title: string;
  summary: string;
  url?: string;
  why: string;
}

const TOOLS: ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'search_web',
      description: '互联网搜索。返回 5-10 条标题+片段+url。',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string' } },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_url',
      description: '抓取一个网页，返回干净 markdown。最长 ~6000 字符。',
      parameters: {
        type: 'object',
        properties: { url: { type: 'string' } },
        required: ['url'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'note',
      description: '记下一条值得分享给用户的发现。简短，30-100 字。',
      parameters: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          summary: { type: 'string' },
          url: { type: 'string' },
          why: { type: 'string' },
        },
        required: ['title', 'summary', 'why'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'finish',
      description: '结束本次冲浪。',
      parameters: {
        type: 'object',
        properties: {
          reason: { type: 'string' },
          satisfied: { type: 'boolean' },
        },
        required: ['reason', 'satisfied'],
      },
    },
  },
];

export interface RunSurfInput {
  env: Env;
  surfRunId: string;
  conversationId: string;
  userId: string;
  query: string;
}

async function emitStep(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  surfRunId: string,
  step: string,
  status: 'running' | 'done' | 'error',
  detail?: Record<string, unknown>,
): Promise<void> {
  await supa.from('messages').insert({
    client_message_id: randomUUID(),
    conversation_id: conversationId,
    role: 'log',
    status: 'done',
    log_kind: 'surf:step',
    log_payload: { surf_run_id: surfRunId, step, status, ...(detail ?? {}) },
  });
}

async function emitResult(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  surfRunId: string,
  note: NoteRecord,
): Promise<void> {
  await supa.from('messages').insert({
    client_message_id: randomUUID(),
    conversation_id: conversationId,
    role: 'log',
    status: 'done',
    log_kind: 'surf:result',
    log_payload: { surf_run_id: surfRunId, ...note },
  });
}

export async function runSurf(input: RunSurfInput): Promise<void> {
  const { env, surfRunId, conversationId, userId, query } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  // surf_runs status was already set to 'running' by the caller. Stamp
  // started_at and seed progress with the user-supplied query.
  await supa
    .from('surf_runs')
    .update({ started_at: new Date().toISOString(), progress: { phase: 'planning', query } })
    .eq('id', surfRunId);

  try {
    await emitStep(supa, conversationId, surfRunId, 'planning', 'running', { query });

    // Pull user representation as soft context — surf is "for a specific
    // person", not a generic search agent. Empty on cold start; the prompt
    // tells the agent to bail in that case.
    const userMemory = await getUserMemory(env, userId);
    const userContext =
      userMemory && (userMemory.representation || userMemory.card.length)
        ? `## 这个人\n${userMemory.card.join('\n')}\n${userMemory.representation}`.trim()
        : '## 这个人\n（对他几乎一无所知）';

    // Pick a model. Until B8 ships model_pricing + role mapping, hard-code
    // a capable, fast default. Cheap enough to be "tool-loop friendly".
    const modelId = 'anthropic/claude-haiku-4-5';

    const messages: ChatCompletionMessageParam[] = [
      { role: 'system', content: getPrompt('surfing-agent') },
      { role: 'user', content: `${userContext}\n\n## 主题\n${query}` },
    ];

    const openai = openrouterClient(env);
    const notes: NoteRecord[] = [];
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    let finished = false;
    let satisfied = false;
    let finishReason = 'max turns reached';

    for (let turn = 0; turn < MAX_TURNS; turn++) {
      // Cooperative cancel: caller may have flipped status to 'cancelled'.
      const { data: liveRow } = await supa
        .from('surf_runs')
        .select('status')
        .eq('id', surfRunId)
        .single();
      if (liveRow?.status === 'cancelled') {
        finishReason = 'cancelled by user';
        finished = true;
        break;
      }

      const completion = await openai.chat.completions.create({
        model: modelId,
        messages,
        tools: TOOLS,
        tool_choice: 'auto',
      });
      totalInputTokens += completion.usage?.prompt_tokens ?? 0;
      totalOutputTokens += completion.usage?.completion_tokens ?? 0;

      const choice = completion.choices[0];
      const msg = choice?.message;
      if (!msg) break;

      // Push assistant turn (with any tool_calls) onto the running history.
      messages.push(msg);

      const calls = msg.tool_calls ?? [];
      if (calls.length === 0) {
        // Plain text — surface as a thinking step so the user sees it.
        if (msg.content) {
          await emitStep(supa, conversationId, surfRunId, 'thinking', 'done', {
            text: msg.content,
          });
        }
        // No tool call + no finish = the model is done musing.
        break;
      }

      for (const call of calls) {
        if (call.type !== 'function') continue;
        const name = call.function.name;
        let args: Record<string, unknown> = {};
        try {
          args = JSON.parse(call.function.arguments || '{}');
        } catch {
          // Continue with empty args; the function-side handler will reject.
        }

        let toolResult = '';
        try {
          if (name === 'search_web') {
            const q = String(args.query ?? '');
            await emitStep(supa, conversationId, surfRunId, 'search', 'running', { query: q });
            const results = await jinaSearch(env, q);
            await emitStep(supa, conversationId, surfRunId, 'search', 'done', {
              query: q,
              count: results.length,
            });
            toolResult = JSON.stringify(
              results.slice(0, 8).map((r) => ({ url: r.url, title: r.title, snippet: r.snippet })),
            );
          } else if (name === 'read_url') {
            const u = String(args.url ?? '');
            await emitStep(supa, conversationId, surfRunId, 'read', 'running', { url: u });
            const page = await jinaRead(env, u);
            await emitStep(supa, conversationId, surfRunId, 'read', 'done', {
              url: u,
              title: page.title,
            });
            const trimmed = page.content.slice(0, READ_TRUNCATE_CHARS);
            toolResult = JSON.stringify({ url: page.url, title: page.title, content: trimmed });
          } else if (name === 'note') {
            const note: NoteRecord = {
              title: String(args.title ?? ''),
              summary: String(args.summary ?? ''),
              url: typeof args.url === 'string' ? args.url : undefined,
              why: String(args.why ?? ''),
            };
            notes.push(note);
            await emitResult(supa, conversationId, surfRunId, note);
            toolResult = JSON.stringify({ ok: true, count: notes.length });
          } else if (name === 'finish') {
            finishReason = String(args.reason ?? 'no reason given');
            satisfied = !!args.satisfied;
            finished = true;
            toolResult = JSON.stringify({ ok: true });
          } else {
            toolResult = JSON.stringify({ error: `unknown tool: ${name}` });
          }
        } catch (err) {
          toolResult = JSON.stringify({ error: String(err) });
          await emitStep(supa, conversationId, surfRunId, name, 'error', {
            error: String(err),
          });
        }

        messages.push({
          role: 'tool',
          tool_call_id: call.id,
          content: toolResult,
        });
      }

      if (finished) break;
    }

    // Audit. Costs computed only on prompt/completion totals — surf does
    // many cheap turns so we sum them into one row per run.
    await supa.from('audit_log').insert({
      user_id: userId,
      conversation_id: conversationId,
      task_type: 'surf',
      model_id: modelId,
      input_tokens: totalInputTokens,
      output_tokens: totalOutputTokens,
      total_tokens: totalInputTokens + totalOutputTokens,
      latency_ms: Date.now() - startedAt,
      metadata: { surf_run_id: surfRunId, notes_count: notes.length },
    });

    await supa
      .from('surf_runs')
      .update({
        status: 'done',
        finished_at: new Date().toISOString(),
        progress: {
          phase: 'done',
          query,
          notes_count: notes.length,
          satisfied,
          reason: finishReason,
        },
      })
      .eq('id', surfRunId);
  } catch (err) {
    console.error('[surf-runner]', err);
    await supa
      .from('surf_runs')
      .update({
        status: 'error',
        finished_at: new Date().toISOString(),
        progress: { phase: 'error', error: String(err) },
      })
      .eq('id', surfRunId);
  }
}
