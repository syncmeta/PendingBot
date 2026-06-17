import type { Env } from '../types';
import type { ChatCompletionCreateParamsNonStreaming } from 'openai/resources/chat/completions';
import { serviceClient } from './supabase';
import {
  enqueueAudit,
  FallbackError,
  usageFromCompletion,
  withFallback,
} from '../llm/router';
import { ensurePromptOverridesLoaded, getPrompt } from '../llm/prompt-loader';
import { uuidv7 } from './ids';
import { getModelRole } from './model-roles';

// Title runner — auto-generates a short conversation name by summarizing
// the first few turns. Fire-and-forget via waitUntil; failure leaves the
// existing title (random place-name on round 1, or the prior summary on
// later refreshes) in place.
//
// Triggered on round 1 (initial naming) and every 3 rounds afterwards
// (rc % 3 === 0) so convs whose topic drifted get a fresher title. Self
// convs keep their `caller_name | 我自己` title — overwriting that with
// a topic summary feels wrong.

const MAX_TITLE_CHARS = 32;

// Titling is a throwaway summarization — always run it on a cheap small
// model rather than the (possibly expensive) model the bot chats with.
// Slug is board-configurable via the 'title' system model-role
// (lib/model-roles.ts); code default = google/gemma-4-31b-it.

export interface RunTitleInput {
  env: Env;
  conversationId: string;
}

export async function runTitle(input: RunTitleInput): Promise<void> {
  const { env, conversationId } = input;
  const supa = serviceClient(env);
  await ensurePromptOverridesLoaded(env);
  const startedAt = Date.now();
  const turnId = uuidv7();

  // Pull the most recent turns (descending) and flip back to chronological
  // order. Round 1 only has 1-2 messages anyway; on later refreshes (round
  // 3, 6, 9...) sampling the tail makes the title reflect the current
  // topic instead of being anchored to the opening exchange.
  const { data: recent } = await supa
    .from('messages')
    .select('role, content, created_at')
    .eq('conversation_id', conversationId)
    .in('role', ['user', 'bot'])
    .order('created_at', { ascending: false })
    .limit(12);
  const transcript = (recent ?? [])
    .filter((m) => (m.content as string | null)?.trim())
    .reverse()
    .map((m) => `${m.role === 'bot' ? 'bot' : 'user'}：${m.content}`)
    .join('\n');
  if (!transcript) return;

  const titleModel = await getModelRole(env, 'title');
  try {
    const { result: completion, route, routeTrace } = await withFallback(
      supa,
      env,
      { modelSlug: titleModel, taskType: 'title', metadata: { turnId } },
      (r) => {
        const request = {
          model: r.modelToCall,
          messages: [
            { role: 'system', content: getPrompt('title') },
            { role: 'user', content: transcript },
          ],
        } as ChatCompletionCreateParamsNonStreaming;
        return r.client.chat.completions.create(request);
      },
    );

    const raw = (completion.choices[0]?.message?.content ?? '').trim();
    const title = raw.replace(/^["'「『]+|["'」』。.！!？?]+$/g, '').slice(0, MAX_TITLE_CHARS);
    if (title) {
      await supa
        .from('conversations')
        .update({ title, updated_at: new Date().toISOString() })
        .eq('id', conversationId);
    }

    await enqueueAudit(env, route, {
      auditId: turnId,
      conversationId,
      taskType: 'title',
      startedAt,
      generationId: completion.id,
      status: 'success',
      routeTrace,
      ...usageFromCompletion(completion.usage, completion),
    });
  } catch (err) {
    console.warn('[title]', err);
    if (err instanceof FallbackError) {
      // Every attempt failed — record the trace so /audit knows what
      // we tried. lastRoute may be null if even the first resolveRoute
      // couldn't pick a provider.
      await enqueueAudit(env, err.lastRoute, {
        auditId: turnId,
        conversationId,
        taskType: 'title',
        startedAt,
        status: 'error',
        errorClass:
          err.routeTrace[err.routeTrace.length - 1]?.error_class ?? 'unknown',
        routeTrace: err.routeTrace,
      });
    }
  }
}
