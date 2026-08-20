import { Hono } from 'hono';
import type { Context } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { userClient, serviceClient } from '../lib/supabase';
import { resolveConv } from '../lib/conv-cache';
import { resolveBot } from '../lib/bot-cache';
import { safeWaitUntil } from '../lib/safe-wait-until';
import { jsonError } from '../lib/http-error';
import {
  parseBlindBoxConfig,
  readConvModelStateRow,
  markConvRevealed,
  writeConvModel,
  rerollConversationModel,
  modelPoolConfigFromBotConfig,
} from '../lib/conversation-model';
import type { AppBindings } from '../types';

// Per-conversation blind-box model surface.
//   GET  /v1/conversations/:id/model          — current model + reveal + bot blindBox settings
//   POST /v1/conversations/:id/reveal-model    — guess / give up → reveal
//   POST /v1/conversations/:id/model           — switch (specific | random)

export const conversationModelRoutes = new Hono<AppBindings>();
conversationModelRoutes.use('*', requireSession());

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface ConvWithBot {
  conversation_id: string;
  bot: { model_id: string; model_provider: string | null; config: unknown } | null;
}

// Resolve conv membership + the bot behind it (for pool + blindBox config).
async function loadConvBot(
  c: Context<AppBindings>,
  conversationId: string,
): Promise<ConvWithBot | null> {
  const userId = c.var.userId!;
  const userJwt = c.var.userJwt!;
  const supaUser = userClient(c.env, userJwt);
  const conv = await resolveConv(c.env, supaUser, conversationId, userId, (p) =>
    safeWaitUntil(c, p),
  ).catch(() => null);
  if (!conv) return null;
  const botId = conv.bot_id;
  if (!botId) return { conversation_id: conversationId, bot: null };
  const bot = await resolveBot(c.env, serviceClient(c.env), botId, (p) => safeWaitUntil(c, p));
  return {
    conversation_id: conversationId,
    bot: bot
      ? { model_id: bot.model_id ?? '', model_provider: bot.model_provider, config: bot.config }
      : null,
  };
}

conversationModelRoutes.get('/:id/model', async (c) => {
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  const cb = await loadConvBot(c, id);
  if (!cb) return jsonError(c, 404, 'conversation_no_access');
  const state = await readConvModelStateRow(c.env, id);
  if (!state) return jsonError(c, 404, 'not_found');
  const bb = parseBlindBoxConfig(cb.bot?.config);
  const hasPool = cb.bot ? modelPoolConfigFromBotConfig(cb.bot.config) !== null : false;
  // model_revealed 发**会话的原始事实**,不再把 disclose 折叠进来。
  // 客户端本来就自己 OR 了 reveal_mode == 'disclose'(显示态不变),而全局
  // 「总是盲盒」那档需要分辨"这个会话真揭晓过"和"bot 本来就直接披露" ——
  // 前者不可逆、压不回盲盒,后者可以。折叠了就分辨不出来。
  return c.json({
    current_model_slug: state.current_model_slug,
    current_model_provider: state.current_model_provider,
    model_revealed: state.model_revealed,
    reveal_mode: bb.revealMode,
    regen_reroll: bb.regenReroll,
    has_pool: hasPool,
  });
});

const RevealBody = z.object({ guess: z.string().min(1).max(200).nullable().optional() });

conversationModelRoutes.post('/:id/reveal-model', async (c) => {
  const userId = c.var.userId!;
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  let parsed: z.infer<typeof RevealBody>;
  try {
    parsed = RevealBody.parse(await c.req.json().catch(() => ({})));
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const cb = await loadConvBot(c, id);
  if (!cb) return jsonError(c, 404, 'conversation_no_access');
  const state = await readConvModelStateRow(c.env, id);
  if (!state || !state.current_model_slug) {
    return jsonError(c, 404, 'not_found', { message: '该会话还没有抽定模型' });
  }
  const guess = parsed.guess ?? null;
  const correct = guess === null ? null : guess === state.current_model_slug;

  // Persist the guess record + flip reveal (idempotent: re-reveal just logs again).
  const supa = serviceClient(c.env);
  await supa.from('model_guesses').insert({
    conversation_id: id,
    user_id: userId,
    actual_slug: state.current_model_slug,
    actual_provider: state.current_model_provider,
    guessed_slug: guess,
    correct,
  });
  await markConvRevealed(c.env, id);

  return c.json({
    actual_slug: state.current_model_slug,
    actual_provider: state.current_model_provider,
    correct,
  });
});

const SwitchBody = z.discriminatedUnion('mode', [
  z.object({
    mode: z.literal('specific'),
    slug: z.string().min(1).max(200),
    provider: z.string().max(100).nullable().optional(),
  }),
  z.object({ mode: z.literal('random') }),
]);

conversationModelRoutes.post('/:id/model', async (c) => {
  const id = c.req.param('id');
  if (!UUID_RE.test(id)) return jsonError(c, 400, 'invalid_id');
  let parsed: z.infer<typeof SwitchBody>;
  try {
    parsed = SwitchBody.parse(await c.req.json());
  } catch (err) {
    return jsonError(c, 400, 'invalid_body', { detail: String(err) });
  }
  const cb = await loadConvBot(c, id);
  if (!cb) return jsonError(c, 404, 'conversation_no_access');
  const state = await readConvModelStateRow(c.env, id);
  if (!state) return jsonError(c, 404, 'not_found');

  if (parsed.mode === 'specific') {
    // Self-chosen model → revealed (you know what you picked).
    const provider = parsed.provider ?? 'openrouter';
    await writeConvModel(c.env, id, {
      slug: parsed.slug,
      provider,
      revealed: true,
    });
    return c.json({
      current_model_slug: parsed.slug,
      current_model_provider: provider,
      model_revealed: true,
    });
  }

  // random → re-roll from pool, reset reveal.
  if (!cb.bot) return jsonError(c, 400, 'conversation_has_no_bot');
  const rolled = await rerollConversationModel(c.env, id, cb.bot, state.current_model_slug);
  if (!rolled) {
    return jsonError(c, 400, 'no_model_pool', { message: '该机器人没有配置模型池,无法随机' });
  }
  return c.json({
    current_model_slug: rolled.slug,
    current_model_provider: rolled.provider,
    model_revealed: false,
  });
});
