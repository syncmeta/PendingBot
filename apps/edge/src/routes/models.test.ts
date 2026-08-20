import { describe, expect, it } from 'vitest';
import { attachLMArenaScores, isNativeBackedOpenRouterSlug, type OpenRouterModelOut } from './models';

describe('isNativeBackedOpenRouterSlug', () => {
  it('removes OpenRouter rows for providers that already have native routes', () => {
    expect(isNativeBackedOpenRouterSlug('openai/gpt-5.1')).toBe(true);
    expect(isNativeBackedOpenRouterSlug('anthropic/claude-sonnet-4.6')).toBe(true);
    expect(isNativeBackedOpenRouterSlug('google/gemini-3-pro')).toBe(true);
  });

  it('also removes tilde latest aliases for native-backed providers', () => {
    expect(isNativeBackedOpenRouterSlug('~openai/gpt-latest')).toBe(true);
    expect(isNativeBackedOpenRouterSlug('~anthropic/claude-latest')).toBe(true);
    expect(isNativeBackedOpenRouterSlug('~google/gemini-flash-latest')).toBe(true);
  });

  it('keeps other OpenRouter providers in the catalog', () => {
    expect(isNativeBackedOpenRouterSlug('deepseek/deepseek-chat')).toBe(false);
    expect(isNativeBackedOpenRouterSlug('moonshotai/kimi-latest')).toBe(false);
    expect(isNativeBackedOpenRouterSlug('x-ai/grok-4')).toBe(false);
  });
});

describe('attachLMArenaScores', () => {
  it('adds LMArena ratings from Hugging Face leaderboard rows', () => {
    const catalog: OpenRouterModelOut[] = [
      {
        slug: 'moonshotai/kimi-k2',
        display_name: 'Kimi K2',
        provider: 'moonshotai',
        release_date: null,
        context_length: 128000,
        supports_vision: false,
        blended_usd_per_million: 1,
        lmarena_license: null,
        lmarena_organization: null,
        lmarena_scores: {},
        source: 'openrouter',
        model_provider: null,
      },
      {
        slug: 'gemini-3.1-pro-preview',
        display_name: 'Gemini 3.1 Pro Preview',
        provider: 'google-ai-studio',
        release_date: '2026-04-01',
        context_length: 1000000,
        supports_vision: true,
        blended_usd_per_million: 2,
        lmarena_license: null,
        lmarena_organization: null,
        lmarena_scores: {},
        source: 'google-ai-studio',
        model_provider: 'google-ai-studio',
      },
    ];

    const scored = attachLMArenaScores(catalog, {
      text: [
        {
          model_name: 'Kimi K2',
          organization: 'moonshot',
          license: 'Modified MIT',
          rating: 1453.6,
          rank: 10,
          vote_count: 3769,
          category: 'overall',
          leaderboard_publish_date: '2026-05-12',
        },
        {
          model_name: 'Gemini 3.1 Pro Preview',
          organization: 'google',
          license: 'Proprietary',
          rating: 1442.7,
          rank: 13,
          vote_count: 24873,
          category: 'overall',
          leaderboard_publish_date: '2026-05-12',
        },
      ],
      webdev: [
        {
          model_name: 'Gemini 3.1 Pro Preview',
          organization: 'google',
          license: 'Proprietary',
          rating: 1200,
          rank: 2,
          vote_count: 1000,
          category: 'overall',
          leaderboard_publish_date: '2026-05-01',
        },
      ],
    });

    expect(scored.map((m) => m.lmarena_scores.text?.rating)).toEqual([1453.6, 1442.7]);
    expect(scored[0]?.release_date).toBe('2026-05-12');
    expect(scored[1]?.release_date).toBe('2026-04-01');
    expect(scored[1]?.lmarena_scores.webdev?.rank).toBe(2);
  });
});
