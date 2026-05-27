import { describe, expect, it } from 'vitest';
import {
  chooseCandidateModel,
  chooseConversationMainModel,
  modelPoolConfigFromBotConfig,
} from './conversation-model';

describe('modelPoolConfigFromBotConfig', () => {
  it('reads the bot modelPool config and falls back to legacy arena config', () => {
    expect(modelPoolConfigFromBotConfig({
      modelPool: { price_min: 1, price_max: 3, models: ['a'], exclude: ['b'] },
      arena: { price_min: 0, price_max: 5, models: ['legacy'], exclude: null },
    })).toEqual({ price_min: 1, price_max: 3, models: ['a'], exclude: ['b'] });

    expect(modelPoolConfigFromBotConfig({
      arena: { price_min: 0, price_max: 5, models: ['legacy'], exclude: null },
    })).toEqual({ price_min: 0, price_max: 5, models: ['legacy'], exclude: null });
  });
});

describe('chooseConversationMainModel', () => {
  it('keeps the existing conversation main model and does not draw from the pool', async () => {
    let pickCalls = 0;
    const result = await chooseConversationMainModel({
      bot: {
        model_id: 'fallback-model',
        model_provider: null,
        config: { modelPool: { models: ['pool-model'], price_min: null, price_max: null, exclude: null } },
      },
      conversation: {
        current_model_slug: 'current-model',
        current_model_provider: 'openai',
      },
      pickFromPool: async () => {
        pickCalls += 1;
        return { slug: 'pool-model', modelProvider: null };
      },
    });

    expect(result).toEqual({
      modelId: 'current-model',
      providerOverride: 'openai',
      shouldPersist: false,
    });
    expect(pickCalls).toBe(0);
  });

  it('draws once from the model pool for a new conversation and asks caller to persist it', async () => {
    const result = await chooseConversationMainModel({
      bot: {
        model_id: 'fallback-model',
        model_provider: 'openrouter',
        config: { modelPool: { models: ['pool-model'], price_min: null, price_max: null, exclude: null } },
      },
      conversation: {
        current_model_slug: null,
        current_model_provider: null,
      },
      pickFromPool: async () => ({ slug: 'pool-model', modelProvider: 'anthropic' }),
    });

    expect(result).toEqual({
      modelId: 'pool-model',
      providerOverride: 'anthropic',
      shouldPersist: true,
    });
  });
});

describe('chooseCandidateModel', () => {
  it('draws a candidate from the model pool without requiring persistence', async () => {
    const result = await chooseCandidateModel({
      bot: {
        model_id: 'fallback-model',
        model_provider: 'openrouter',
        config: { modelPool: { models: ['pool-model'], price_min: null, price_max: null, exclude: null } },
      },
      pickFromPool: async (_cfg, opts) => {
        expect(opts?.excludeSlugs).toEqual([]);
        return { slug: 'pool-model', modelProvider: null };
      },
    });

    expect(result).toEqual({
      modelId: 'pool-model',
      providerOverride: 'openrouter',
      shouldPersist: false,
    });
  });
});
