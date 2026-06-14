import {
  parseRandomModelConfig,
  pickRandomModel,
  type RandomModelConfig,
} from '../llm/random-model';
import { serviceClient } from './supabase';
import { deleteCachedConv } from './conv-cache';
import type { AppBindings } from '../types';

type Env = AppBindings['Bindings'];

export interface BotModelSelectionInput {
  model_id: string;
  model_provider: string | null;
  config: unknown;
}

export interface ConversationModelState {
  current_model_slug: string | null;
  current_model_provider: string | null;
}

export interface ChosenTurnModel {
  modelId: string;
  providerOverride: string | null;
  shouldPersist: boolean;
}

export type PoolPick = (
  cfg: RandomModelConfig,
  opts?: { excludeSlugs?: string[] },
) => Promise<{ slug: string; modelProvider: string | null } | null>;

export function modelPoolConfigFromBotConfig(config: unknown): RandomModelConfig | null {
  if (!config || typeof config !== 'object' || Array.isArray(config)) return null;
  const record = config as Record<string, unknown>;
  return parseRandomModelConfig(record.modelPool) ?? parseRandomModelConfig(record.arena);
}

export async function chooseConversationMainModel(input: {
  bot: BotModelSelectionInput;
  conversation?: ConversationModelState | null;
  pickFromPool: PoolPick;
}): Promise<ChosenTurnModel> {
  const currentSlug = input.conversation?.current_model_slug;
  if (currentSlug) {
    return {
      modelId: currentSlug,
      providerOverride: input.conversation?.current_model_provider ?? null,
      shouldPersist: false,
    };
  }

  const cfg = modelPoolConfigFromBotConfig(input.bot.config);
  if (cfg) {
    const picked = await input.pickFromPool(cfg, { excludeSlugs: [] });
    if (picked) {
      return {
        modelId: picked.slug,
        providerOverride: picked.modelProvider ?? 'openrouter',
        shouldPersist: true,
      };
    }
  }

  return {
    modelId: input.bot.model_id,
    providerOverride: input.bot.model_provider ?? null,
    shouldPersist: true,
  };
}

export type RevealMode = 'surprise' | 'disclose';

export interface BlindBoxConfig {
  revealMode: RevealMode;
  regenReroll: boolean;
}

export function parseBlindBoxConfig(config: unknown): BlindBoxConfig {
  const fallback: BlindBoxConfig = { revealMode: 'surprise', regenReroll: true };
  if (!config || typeof config !== 'object' || Array.isArray(config)) return fallback;
  const bb = (config as Record<string, unknown>).blindBox;
  if (!bb || typeof bb !== 'object' || Array.isArray(bb)) return fallback;
  const record = bb as Record<string, unknown>;
  const revealMode: RevealMode = record.revealMode === 'disclose' ? 'disclose' : 'surprise';
  const regenReroll = typeof record.regenReroll === 'boolean' ? record.regenReroll : true;
  return { revealMode, regenReroll };
}

export interface ConvModelStateRow {
  current_model_slug: string | null;
  current_model_provider: string | null;
  model_revealed: boolean;
}

export async function readConvModelStateRow(
  env: Env,
  conversationId: string,
): Promise<ConvModelStateRow | null> {
  const { data } = await serviceClient(env)
    .from('conversations')
    .select('current_model_slug, current_model_provider, model_revealed')
    .eq('id', conversationId)
    .maybeSingle();
  if (!data) return null;
  return {
    current_model_slug: (data.current_model_slug ?? null) as string | null,
    current_model_provider: (data.current_model_provider ?? null) as string | null,
    model_revealed: Boolean(data.model_revealed),
  };
}

/** Set the conversation model + reveal flag, busting the conv cache. */
export async function writeConvModel(
  env: Env,
  conversationId: string,
  patch: { slug: string; provider: string | null; revealed: boolean },
): Promise<void> {
  const { error } = await serviceClient(env)
    .from('conversations')
    .update({
      current_model_slug: patch.slug,
      current_model_provider: patch.provider,
      model_revealed: patch.revealed,
    })
    .eq('id', conversationId);
  if (error) throw new Error(error.message);
  await deleteCachedConv(env, conversationId).catch(() => undefined);
}

/** Just flip the reveal flag (used by reveal-model). Busts cache. */
export async function markConvRevealed(env: Env, conversationId: string): Promise<void> {
  const { error } = await serviceClient(env)
    .from('conversations')
    .update({ model_revealed: true })
    .eq('id', conversationId);
  if (error) throw new Error(error.message);
  await deleteCachedConv(env, conversationId).catch(() => undefined);
}

/**
 * Re-draw the conversation main model from the bot pool, excluding the
 * current one, persist it, and reset reveal=false. Returns the chosen
 * {slug, provider}, or null if the bot has no pool (nothing to re-roll —
 * caller keeps the current model).
 */
export async function rerollConversationModel(
  env: Env,
  conversationId: string,
  bot: BotModelSelectionInput,
  currentSlug: string | null,
): Promise<{ slug: string; provider: string | null } | null> {
  const cfg = modelPoolConfigFromBotConfig(bot.config);
  if (!cfg) return null;
  const picked = await pickRandomModel(env, cfg, {
    excludeSlugs: currentSlug ? [currentSlug] : [],
  });
  if (!picked) return null;
  const provider = picked.modelProvider ?? 'openrouter';
  await writeConvModel(env, conversationId, { slug: picked.slug, provider, revealed: false });
  return { slug: picked.slug, provider };
}
