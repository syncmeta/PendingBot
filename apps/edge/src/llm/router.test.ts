import { describe, expect, it } from 'vitest';
import { computeVoiceCost } from './router';
import {
  modelForUpstream,
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
  it('maps openai to Responses, everything else to Chat Completions', () => {
    expect(providerApiStyle('openai')).toBe('responses');
    expect(providerApiStyle('openrouter')).toBe('chat');
    expect(providerApiStyle('anthropic')).toBe('chat');
    expect(providerApiStyle('google-ai-studio')).toBe('chat');
  });
});

describe('modelForUpstream', () => {
  it('passes openai / openrouter slugs through unchanged', () => {
    expect(modelForUpstream('openai', 'gpt-5-mini')).toBe('gpt-5-mini');
    expect(modelForUpstream('openrouter', 'anthropic/claude-3-haiku')).toBe(
      'anthropic/claude-3-haiku',
    );
  });

  it('prefixes the provider slug onto anthropic / google-ai-studio models', () => {
    expect(modelForUpstream('anthropic', 'claude-sonnet-4-5')).toBe(
      'anthropic/claude-sonnet-4-5',
    );
    expect(modelForUpstream('google-ai-studio', 'gemini-2.5-flash')).toBe(
      'google-ai-studio/gemini-2.5-flash',
    );
  });

  it('does not double-prefix an already-prefixed model id', () => {
    expect(modelForUpstream('anthropic', 'anthropic/claude-sonnet-4-5')).toBe(
      'anthropic/claude-sonnet-4-5',
    );
    expect(
      modelForUpstream('google-ai-studio', 'google-ai-studio/gemini-2.5-flash'),
    ).toBe('google-ai-studio/gemini-2.5-flash');
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
