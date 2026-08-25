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

/// 固定标记:生成这份介绍失败时,日志里必须留下这一行。
///
/// 为什么要有它:这份介绍是群调度器**唯一**的判据(见 `llm/group-router.ts`)。
/// 没有它,调度器每一轮都会合规地返回空名单 —— 群于是永远安静,而且不报错、
/// 不留日志、界面上什么都没有。2026-08-25 线上就是这个状态:`group_bot_descriptions`
/// 全表 0 行,而调度器跑得好好的。**一个会让功能静默死掉的失败,必须有声音。**
export const GROUP_BOT_INTRO_FAILURE_MARKER = '[group-bot-intro][generate-failed]';

/// 一次性补齐某个群里**所有还没有介绍**的机器人。
///
/// 两个调用点,覆盖两种缺口:
///   - `POST /v1/groups`(建群时一次性带进机器人)—— 这条路以前完全不生成介绍,
///     是 2026-08-25「群里机器人永远不说话」的病根。
///   - `GroupRouterDO.alarm()`(每一轮路由之前)—— **存量自愈**。线上已经存在的
///     群一份介绍都没有,与其手改数据库,不如让它们在下一次有人说话时自己补上。
///     `generateInitialBotDescription` 本身幂等(有行就直接返回),所以补齐过的群
///     后续只多一次廉价的查询。
///
/// 失败**不抛**:调用方(建群 / 路由)都不该因为介绍没写成而失败。但每一个失败
/// 都会带着 `GROUP_BOT_INTRO_FAILURE_MARKER` 落进日志,不再是无声的。
/// 纯函数:这个群里哪些机器人还没有介绍。
///
/// 抽出来是为了能单独考 —— 整个 Todo #20 的病根就是"有机器人没有介绍,而且
/// 没有任何一处发现得了"。去重、顺序稳定(按参与者顺序),空输入返回空。
export function botsMissingDescriptions(
  participantBotIds: readonly string[],
  describedBotIds: readonly string[],
): string[] {
  const have = new Set(describedBotIds);
  const seen = new Set<string>();
  const out: string[] = [];
  for (const id of participantBotIds) {
    if (!id || have.has(id) || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

export async function ensureGroupBotDescriptions(
  env: Env,
  conversationId: string,
): Promise<{ missing: number; failed: number }> {
  const supa = serviceClient(env);

  const [{ data: parts }, { data: descs }] = await Promise.all([
    supa
      .from('conversation_participants')
      .select('participant_id')
      .eq('conversation_id', conversationId)
      .eq('participant_type', 'bot'),
    supa
      .from('group_bot_descriptions')
      .select('bot_id')
      .eq('conversation_id', conversationId),
  ]);

  const missing = botsMissingDescriptions(
    (parts ?? []).map((p) => p.participant_id as string),
    (descs ?? []).map((d) => d.bot_id as string),
  );
  if (missing.length === 0) return { missing: 0, failed: 0 };

  const results = await Promise.allSettled(
    missing.map((botId) =>
      generateInitialBotDescription({ env, conversationId, botId }),
    ),
  );
  let failed = 0;
  results.forEach((r, i) => {
    if (r.status === 'rejected') {
      failed += 1;
      console.error(GROUP_BOT_INTRO_FAILURE_MARKER, JSON.stringify({
        conversationId,
        botId: missing[i],
        error: r.reason instanceof Error ? r.reason.message : String(r.reason),
      }));
    }
  });
  return { missing: missing.length, failed };
}

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
