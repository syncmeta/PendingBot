import { describe, expect, it } from 'vitest';
import { computeVoiceCost } from './router';
import {
  providerApiStyle,
  resolveProviderSlug,
} from './providers';

describe('resolveProviderSlug', () => {
  it('selects each native route for its known hint', () => {
    expect(resolveProviderSlug('openai')).toBe('openai');
    expect(resolveProviderSlug('anthropic')).toBe('anthropic');
    expect(resolveProviderSlug('google-ai-studio')).toBe('google-ai-studio');
  });

  it('falls back to OpenRouter for null / openrouter / unknown hints', () => {
    expect(resolveProviderSlug(null)).toBe('openrouter');
    expect(resolveProviderSlug(undefined)).toBe('openrouter');
    expect(resolveProviderSlug('openrouter')).toBe('openrouter');
    expect(resolveProviderSlug('something-else')).toBe('openrouter');
  });
});

describe('providerApiStyle', () => {
  it('maps each provider to its dialect', () => {
    expect(providerApiStyle('openai')).toBe('responses');
    expect(providerApiStyle('openrouter')).toBe('chat');
    expect(providerApiStyle('anthropic')).toBe('anthropic');
    expect(providerApiStyle('google-ai-studio')).toBe('gemini');
  });
});

describe('computeVoiceCost', () => {
  it('returns null for an unknown model slug', () => {
    expect(computeVoiceCost('not-a-realtime-model', { audioInputTokens: 1000 })).toBeNull();
    expect(computeVoiceCost(undefined, { audioInputTokens: 1000 })).toBeNull();
  });

  it('prices each token bucket at its REALTIME_PRICING rate', () => {
    // gpt-realtime-2: input 4, cachedInput 0.4, output 24,
    //                 audioInput 32, audioOutput 64 (USD per 1M).
    const cost = computeVoiceCost('gpt-realtime-2', {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 1_000_000,
      audioInputTokens: 1_000_000,
      audioOutputTokens: 1_000_000,
    });
    expect(cost).toBeCloseTo(4 + 24 + 0.4 + 32 + 64);
  });

  it('treats absent token buckets as zero', () => {
    const cost = computeVoiceCost('gpt-realtime-2', { audioOutputTokens: 500_000 });
    expect(cost).toBeCloseTo(32);
  });
});
