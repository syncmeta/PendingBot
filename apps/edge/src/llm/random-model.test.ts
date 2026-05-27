import { describe, expect, it } from 'vitest';
import { filterPool, poolFromCatalog } from './random-model';
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
    release_date: '2026-05-01',
    context_length: 128000,
    supports_vision: false,
    blended_usd_per_million: 1,
    lmarena_license: null,
    lmarena_organization: null,
    lmarena_scores: {},
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

describe('filterPool', () => {
  it('applies vendor and release-window filters to the random pool', () => {
    const pool = poolFromCatalog([
      model('gpt-5.1', 'openai', 'openai'),
      { ...model('claude-sonnet-4-6', 'anthropic', 'anthropic'), release_date: '2020-01-01' },
      model('deepseek/deepseek-chat', 'openrouter', null),
    ]);

    const filtered = filterPool(pool, {
      price_min: null,
      price_max: null,
      models: null,
      exclude: null,
      vendors: ['openai', 'deepseek'],
      release_window_days: 183,
    });

    expect(filtered.map((m) => m.slug)).toEqual(['gpt-5.1', 'deepseek/deepseek-chat']);
  });

  it('treats an empty vendor list as selecting no models', () => {
    const pool = poolFromCatalog([model('gpt-5.1', 'openai', 'openai')]);
    expect(filterPool(pool, {
      price_min: null,
      price_max: null,
      models: null,
      exclude: null,
      vendors: [],
      release_window_days: null,
    })).toEqual([]);
  });
});
