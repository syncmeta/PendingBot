import { resolveRoute } from '../llm/router';
import { serviceClient } from './supabase';
import type { Env } from '../types';

// First-version "call me when..." description, generated immediately
// after group_invite_bot succeeds. The cost is billed to the group
// (M6 will replace the conv-creator placeholder with splitAndDebit).
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

const MODEL_FALLBACK = 'google/gemma-3-27b-it';
const MAX_DESC_TOKENS = 200;

export async function generateInitialBotDescription(input: {
  env: Env;
  conversationId: string;
  botId: string;
}): Promise<{ description: string; auditLogId: string | null }> {
  const { env, conversationId, botId } = input;
  const supa = serviceClient(env);

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
  // semantically this IS the same model class. Falls through the same
  // priority chain as group-router.ts.
  let modelSlug: string | null = meta?.router_model_slug ?? null;
  if (!modelSlug) {
    const { data: rule } = await supa
      .from('task_routing_rules')
      .select(
        `override_model:llm_models!task_routing_rules_override_model_fkey ( slug )`,
      )
      .eq('task_type', 'group_router')
      .eq('enabled', true)
      .order('match_priority', { ascending: true })
      .limit(1)
      .maybeSingle();
    modelSlug = (rule?.override_model as { slug?: string } | null)?.slug ?? MODEL_FALLBACK;
  }

  const groupTitle = (meta?.title as string | null) || '一个群聊';
  const botName = bot.display_name as string;
  const botPrimaryModel = (bot.model_id as string | null) || 'unknown';

  const systemPrompt = `你正在帮一个机器人写"何时叫我"说明,挂在群聊调度器查得到的位置。要求:
- 中文,1-2 句话,不超过 80 字
- 写"我适合什么话题/什么场景被叫出来发言"
- 不要写客套话,不要写自我介绍,直接说话题
- 不要透露自己用什么模型`;

  const userPrompt = `机器人名字: ${botName}
机器人后台模型: ${botPrimaryModel}
群名: ${groupTitle}

请代它写说明。`;

  const startedAt = Date.now();
  let route;
  try {
    route = await resolveRoute(supa, env, {
      modelSlug,
      taskType: 'group_bot_intro',
    });
  } catch (err) {
    console.error('[group-bot-intro] resolveRoute failed', err);
    return await fallbackInsert(supa, conversationId, botId, botName);
  }

  let description = '';
  let inputTokens = 0;
  let outputTokens = 0;
  try {
    const completion = await route.client.chat.completions.create({
      model: route.modelToCall,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0.4,
      max_tokens: MAX_DESC_TOKENS,
    });
    inputTokens = completion.usage?.prompt_tokens ?? 0;
    outputTokens = completion.usage?.completion_tokens ?? 0;
    description = (completion.choices?.[0]?.message?.content ?? '').trim();
  } catch (err) {
    console.error('[group-bot-intro] LLM call failed', err);
    return await fallbackInsert(supa, conversationId, botId, botName);
  }

  if (!description || description.length < 4) {
    return await fallbackInsert(supa, conversationId, botId, botName);
  }
  // Cap the length defensively — DB CHECK is 4000 chars.
  if (description.length > 1000) description = description.slice(0, 1000);

  // Persist + audit. We write the audit row first so we have an id
  // to plug into M6's split hook later.
  const cost = route.alias
    ? computeCost(route.alias, inputTokens, outputTokens)
    : null;

  const { data: audit } = await supa
    .from('audit_log')
    .insert({
      conversation_id: conversationId,
      task_type: 'group_bot_intro',
      model_id: route.modelToCall,
      provider_id: route.provider.id,
      model_alias_id: route.alias?.aliasId ?? null,
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      total_tokens: inputTokens + outputTokens,
      cost_usd: cost,
      latency_ms: Date.now() - startedAt,
      status: 'success',
      billing_status: 'pending',
    })
    .select('id')
    .single();

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
    auditLogId: (audit?.id as string | undefined) ?? null,
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

function computeCost(
  alias: { inputPrice: number | null; outputPrice: number | null },
  inputTokens: number,
  outputTokens: number,
): number | null {
  if (alias.inputPrice == null && alias.outputPrice == null) return null;
  return (
    ((alias.inputPrice ?? 0) * inputTokens) / 1_000_000 +
    ((alias.outputPrice ?? 0) * outputTokens) / 1_000_000
  );
}
