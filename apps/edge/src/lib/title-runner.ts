import type { Env } from '../types';
import { serviceClient } from './supabase';
import {
  FallbackError,
  recordAudit,
  usageFromCompletion,
  withFallback,
} from '../llm/router';
import { getPrompt } from '../llm/prompt-loader';

// Title runner — auto-generates a short conversation name from the first
// round, replacing the random place-name fallback set at conv creation.
// Fire-and-forget via waitUntil; failure leaves the random name in place.
//
// Triggered once per conv when round_count just hit 1. Self convs keep
// their `caller_name | 我自己` title — overwriting that with a topic
// summary feels wrong.

const MAX_TITLE_CHARS = 32;

export interface RunTitleInput {
  env: Env;
  conversationId: string;
  botModelId: string;
}

export async function runTitle(input: RunTitleInput): Promise<void> {
  const { env, conversationId, botModelId } = input;
  const supa = serviceClient(env);
  const startedAt = Date.now();

  const { data: msgs } = await supa
    .from('messages')
    .select('role, content')
    .eq('conversation_id', conversationId)
    .in('role', ['user', 'bot'])
    .order('created_at', { ascending: true })
    .limit(6);
  const transcript = (msgs ?? [])
    .filter((m) => (m.content as string | null)?.trim())
    .map((m) => `${m.role === 'bot' ? 'bot' : 'user'}：${m.content}`)
    .join('\n');
  if (!transcript) return;

  try {
    const { result: completion, route, routeTrace } = await withFallback(
      supa,
      env,
      { modelSlug: botModelId, taskType: 'title' },
      (r) =>
        r.client.chat.completions.create({
          model: r.modelToCall,
          messages: [
            { role: 'system', content: getPrompt('title') },
            { role: 'user', content: transcript },
          ],
        }),
    );

    const raw = (completion.choices[0]?.message?.content ?? '').trim();
    const title = raw.replace(/^["'「『]+|["'」』。.！!？?]+$/g, '').slice(0, MAX_TITLE_CHARS);
    if (title) {
      await supa
        .from('conversations')
        .update({ title, updated_at: new Date().toISOString() })
        .eq('id', conversationId);
    }

    await recordAudit(supa, route, {
      conversationId,
      taskType: 'title',
      startedAt,
      generationId: completion.id,
      status: 'success',
      routeTrace,
      ...usageFromCompletion(completion.usage),
    });
  } catch (err) {
    console.warn('[title]', err);
    if (err instanceof FallbackError) {
      // Every attempt failed — record the trace so /audit knows what
      // we tried. lastRoute may be null if even the first resolveRoute
      // couldn't pick a provider.
      await recordAudit(supa, err.lastRoute, {
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
