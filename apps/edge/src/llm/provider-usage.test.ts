import { describe, expect, it } from 'vitest';
import { usageFromCompletion } from './provider-usage';

describe('usageFromCompletion', () => {
  it('reads OpenRouter cost from usage.cost', () => {
    const usage = usageFromCompletion(
      {
        prompt_tokens: 1099,
        completion_tokens: 108,
        total_tokens: 1207,
        cost: 0.00010355,
        is_byok: false,
        prompt_tokens_details: {
          cached_tokens: 0,
          cache_write_tokens: 0,
          audio_tokens: 0,
          video_tokens: 0,
        },
        cost_details: {
          upstream_inference_cost: 0.00010355,
          upstream_inference_prompt_cost: 0.00005495,
          upstream_inference_completions_cost: 0.0000486,
        },
        completion_tokens_details: {
          reasoning_tokens: 51,
          image_tokens: 0,
          audio_tokens: 0,
        },
      },
      { provider: 'SiliconFlow' },
    );

    expect(usage.providerCostUsd).toBe(0.00010355);
    expect(usage.inputTokens).toBe(1099);
    expect(usage.outputTokens).toBe(108);
  });

  it('reads provider-reported cost from usage.cost', () => {
    const usage = usageFromCompletion(
      {
        completion_tokens: 77,
        prompt_tokens: 1145,
        total_tokens: 1222,
        completion_tokens_details: {
          reasoning_tokens: 0,
          text_tokens: 77,
        },
        prompt_tokens_details: {
          cached_tokens: 0,
          cache_creation_tokens: 0,
          cache_creation_token_details: {
            ephemeral_5m_input_tokens: 0,
            ephemeral_1h_input_tokens: 0,
          },
        },
        cost: 0.001071,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        cost_details: {
          upstream_inference_cost: 0.001071,
          upstream_inference_prompt_cost: 0.0008014999999999999,
          upstream_inference_completions_cost: 0.0002695,
        },
      },
      {
        id: 'chatcmpl-d71a098f-6582-4427-976c-053a81edb5d5',
        model: 'anthropic/claude-haiku-4-5',
      },
    );

    expect(usage.providerCostUsd).toBe(0.001071);
    expect(usage.inputTokens).toBe(1145);
    expect(usage.outputTokens).toBe(77);
    expect(usage.cacheReadTokens).toBe(0);
    expect(usage.cacheWriteTokens).toBe(0);
  });
});
