import { describe, expect, it } from 'vitest';
import { attachArtificialAnalysisScores, isNativeBackedOpenRouterSlug, type OpenRouterModelOut } from './models';

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

describe('attachArtificialAnalysisScores', () => {
  it('adds intelligence index scores from Artificial Analysis API rows', () => {
    const catalog: OpenRouterModelOut[] = [
      {
        slug: 'moonshotai/kimi-k2',
        display_name: 'Kimi K2',
        provider: 'moonshotai',
        context_length: 128000,
        supports_vision: false,
        blended_usd_per_million: 1,
        artificial_analysis_intelligence_index: null,
        source: 'openrouter',
        model_provider: null,
      },
      {
        slug: 'gemini-3.1-pro-preview',
        display_name: 'Gemini 3.1 Pro Preview',
        provider: 'google-ai-studio',
        context_length: 1000000,
        supports_vision: true,
        blended_usd_per_million: 2,
        artificial_analysis_intelligence_index: null,
        source: 'google-ai-studio',
        model_provider: 'google-ai-studio',
      },
    ];

    const scored = attachArtificialAnalysisScores(catalog, [
      {
        name: 'Kimi K2',
        slug: 'kimi-k2',
        model_creator: { slug: 'kimi' },
        evaluations: { artificial_analysis_intelligence_index: 54.2 },
      },
      {
        name: 'Gemini 3.1 Pro Preview',
        slug: 'gemini-31-pro-preview',
        model_creator: { slug: 'google' },
        evaluations: { artificial_analysis_intelligence_index: 57.8 },
      },
    ]);

    expect(scored.map((m) => m.artificial_analysis_intelligence_index)).toEqual([54.2, 57.8]);
  });
});
