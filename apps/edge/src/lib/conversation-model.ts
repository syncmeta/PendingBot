import {
  parseRandomModelConfig,
  type RandomModelConfig,
} from '../llm/random-model';

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

export async function chooseCandidateModel(input: {
  bot: BotModelSelectionInput;
  pickFromPool: PoolPick;
}): Promise<ChosenTurnModel> {
  const cfg = modelPoolConfigFromBotConfig(input.bot.config);
  if (cfg) {
    const picked = await input.pickFromPool(cfg, { excludeSlugs: [] });
    if (picked) {
      return {
        modelId: picked.slug,
        providerOverride: picked.modelProvider ?? 'openrouter',
        shouldPersist: false,
      };
    }
  }

  return {
    modelId: input.bot.model_id,
    providerOverride: input.bot.model_provider ?? null,
    shouldPersist: false,
  };
}
