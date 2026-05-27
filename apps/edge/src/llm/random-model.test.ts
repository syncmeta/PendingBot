import { describe, expect, it } from 'vitest';
import { poolFromCatalog } from './random-model';
import type { OpenRouterModelOut } from '../routes/models';

function model(
  slug: string,
  source: OpenRouterModelOut['source'],
  modelProvider: string | null,
): OpenRouterModelOut {
  return {
    slug,
    display_name: slug,
    provider: source === 'openrouter' ? slug.split('/')[0] ?? 'unknown' : source,
    context_length: 128000,
    supports_vision: false,
    blended_usd_per_million: 1,
    artificial_analysis_intelligence_index: null,
    source,
    model_provider: modelProvider,
  };
}

describe('poolFromCatalog', () => {
  it('uses native rows for native-backed providers and keeps OpenRouter long tail', () => {
    const pool = poolFromCatalog([
      model('gpt-5.1', 'openai', 'openai'),
      model('claude-sonnet-4-6', 'anthropic', 'anthropic'),
      model('gemini-3-pro', 'google-ai-studio', 'google-ai-studio'),
      model('openai/gpt-5.1', 'openrouter', null),
      model('~google/gemini-flash-latest', 'openrouter', null),
      model('deepseek/deepseek-chat', 'openrouter', null),
    ]);

    expect(pool.map((m) => [m.slug, m.modelProvider])).toEqual([
      ['gpt-5.1', 'openai'],
      ['claude-sonnet-4-6', 'anthropic'],
      ['gemini-3-pro', 'google-ai-studio'],
      ['deepseek/deepseek-chat', null],
    ]);
  });
});
