import {
  enqueueAudit,
  resolveRoute,
  usageFromCompletion,
} from '../llm/router';
import type { ChatCompletionCreateParamsNonStreaming } from 'openai/resources/chat/completions';
import { serviceClient } from './supabase';
import { uuidv7 } from './ids';
import { ensurePromptOverridesLoaded, getPrompt } from '../llm/prompt-loader';
import { getModelRole } from './model-roles';
import type { Env } from '../types';

// First-version "call me when..." description, generated immediately
// after group_invite_bot succeeds. The audit layer bills this against
// the group conversation target.
//
// Why generate at invite time rather than on first message: the spec
// requires the bot to introduce itself immediately so the small-model
// router has something to reason about on turn 1. Doing it lazily
// would mean the bot is invisible to routing until it's already been
// woken some other way (mention).
//
// Quality bar is intentionally low: a placeholder good-enough doc.
// The bot itself can rewrite it later via the set_bot_group_description
// tool (M9 polish wires the tool surface). The point of the initial
// row is "router knows the bot exists and roughly what it's about".

const MAX_DESC_TOKENS = 200;

export async function generateInitialBotDescription(input: {
  env: Env;
  conversationId: string;
  botId: string;
}): Promise<{ description: string; auditLogId: string | null }> {
  const { env, conversationId, botId } = input;
  const supa = serviceClient(env);
  // Warm the prompt cache so the sync getPrompt('group-bot-intro') below
  // hits memory. Invoked from the group_invite_bot path, which doesn't warm
  // prompts upstream.
  await ensurePromptOverridesLoaded(env);

  // Idempotent: bail if a description already exists. The DB has UNIQUE
  // (conversation_id, bot_id) so duplicate generation would error
  // anyway, but checking here saves an LLM call on retries.
  const { data: existing } = await supa
    .from('group_bot_descriptions')
    .select('description')
    .eq('conversation_id', conversationId)
    .eq('bot_id', botId)
    .maybeSingle();
  if (existing?.description) {
    return { description: existing.description as string, auditLogId: null };
  }

  // Read bot identity + group meta to give the small model context.
  const [{ data: bot }, { data: meta }] = await Promise.all([
    supa
      .from('bots')
      .select('id, display_name, model_id, config')
      .eq('id', botId)
      .single(),
    supa
      .from('conversation_group_meta')
      .select('title, router_model_slug')
      .eq('conversation_id', conversationId)
      .maybeSingle(),
  ]);

  if (!bot) {
    return {
      description: '(尚未提交描述)',
      auditLogId: null,
    };
  }

  // Pick the same router model the group uses for classification —
  // semantically this IS the same model class. Per-group override wins;
  // otherwise the groupBotIntro model-role default (board-configurable).
  const modelSlug = meta?.router_model_slug ?? (await getModelRole(env, 'groupBotIntro'));

  const groupTitle = (meta?.title as string | null) || '一个群聊';
  const botName = bot.display_name as string;
  const botPrimaryModel = (bot.model_id as string | null) || 'unknown';

  const systemPrompt = getPrompt('group-bot-intro');

  const userPrompt = `机器人名字: ${botName}
机器人后台模型: ${botPrimaryModel}
群名: ${groupTitle}

请代它写说明。`;

  const startedAt = Date.now();
  const turnId = uuidv7();
  let route;
  try {
    route = await resolveRoute(supa, env, {
      modelSlug,
      taskType: 'group_bot_intro',
      metadata: { turnId },
    });
  } catch (err) {
    console.error('[group-bot-intro] resolveRoute failed', err);
    return await fallbackInsert(supa, conversationId, botId, botName);
  }

  let description = '';
  let inputTokens = 0;
  let outputTokens = 0;
  let auditLogId: string | null = null;
  try {
    const request = {
      model: route.modelToCall,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0.4,
      max_tokens: MAX_DESC_TOKENS,
    } as ChatCompletionCreateParamsNonStreaming;
    const completion = await route.client.chat.completions.create(request);
    const usage = usageFromCompletion(completion.usage, completion);
    inputTokens = usage.inputTokens ?? 0;
    outputTokens = usage.outputTokens ?? 0;
    description = (completion.choices?.[0]?.message?.content ?? '').trim();
    auditLogId = await enqueueAudit(env, route, {
      auditId: turnId,
      conversationId,
      taskType: 'group_bot_intro',
      startedAt,
      generationId: completion.id,
      status: 'success',
      inputTokens,
      outputTokens,
      metadata: { bot_id: botId, valid_description: description.length >= 4 },
      ...usage,
    });
  } catch (err) {
    console.error('[group-bot-intro] LLM call failed', err);
    await enqueueAudit(env, route, {
      auditId: turnId,
      conversationId,
      taskType: 'group_bot_intro',
      startedAt,
      status: 'error',
      errorClass: err instanceof Error ? err.name : 'unknown',
      inputTokens,
      outputTokens,
      metadata: { bot_id: botId },
    });
    return await fallbackInsert(supa, conversationId, botId, botName);
  }

  if (!description || description.length < 4) {
    return await fallbackInsert(supa, conversationId, botId, botName);
  }
  // Cap the length defensively — DB CHECK is 4000 chars.
  if (description.length > 1000) description = description.slice(0, 1000);

  // Insert the description row. ON CONFLICT to be idempotent on retries.
  await supa
    .from('group_bot_descriptions')
    .upsert(
      {
        conversation_id: conversationId,
        bot_id: botId,
        description,
        revision_count: 0,
      },
      { onConflict: 'conversation_id,bot_id', ignoreDuplicates: true },
    );

  return {
    description,
    auditLogId,
  };
}

async function fallbackInsert(
  supa: ReturnType<typeof serviceClient>,
  conversationId: string,
  botId: string,
  botName: string,
): Promise<{ description: string; auditLogId: string | null }> {
  const fallback = `${botName}: 适合通用问答和讨论。被 @ 时一定回应。`;
  await supa
    .from('group_bot_descriptions')
    .upsert(
      {
        conversation_id: conversationId,
        bot_id: botId,
        description: fallback,
        revision_count: 0,
      },
      { onConflict: 'conversation_id,bot_id', ignoreDuplicates: true },
    );
  return { description: fallback, auditLogId: null };
}
