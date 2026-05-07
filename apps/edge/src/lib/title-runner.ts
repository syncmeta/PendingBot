import type { Env } from '../types';
import { serviceClient } from './supabase';
import { recordAudit, resolveRoute, usageFromCompletion } from '../llm/router';
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

  try {
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

    const route = await resolveRoute(supa, env, {
      modelSlug: botModelId,
      taskType: 'title',
    });
    const completion = await route.client.chat.completions.create({
      model: route.modelToCall,
      messages: [
        { role: 'system', content: getPrompt('title') },
        { role: 'user', content: transcript },
      ],
    });
    const raw = (completion.choices[0]?.message?.content ?? '').trim();
    const title = raw.replace(/^["'「『]+|["'」』。.！!？?]+$/g, '').slice(0, MAX_TITLE_CHARS);
    if (!title) return;

    await supa
      .from('conversations')
      .update({ title, updated_at: new Date().toISOString() })
      .eq('id', conversationId);

    await recordAudit(supa, route, {
      conversationId,
      taskType: 'title',
      startedAt,
      generationId: completion.id,
      status: 'success',
      ...usageFromCompletion(completion.usage),
    });
  } catch (err) {
    console.warn('[title]', err);
  }
}
