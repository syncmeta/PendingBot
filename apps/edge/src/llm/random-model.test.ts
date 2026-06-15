import { describe, expect, it } from 'vitest';
import { expandPresets, filterPool, parseRandomModelConfig, poolFromCatalog } from './random-model';
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
      presets: null,
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
      presets: null,
    })).toEqual([]);
  });
});

describe('parseRandomModelConfig presets', () => {
  it('parses presets array', () => {
    const cfg = parseRandomModelConfig({ presets: ['top-flagship', 'cn-flagship'] });
    expect(cfg?.presets).toEqual(['top-flagship', 'cn-flagship']);
  });
  it('null presets when absent', () => {
    const cfg = parseRandomModelConfig({ models: ['openai/gpt-5.1'] });
    expect(cfg?.presets).toBeNull();
  });
});

describe('expandPresets', () => {
  const base = {
    price_min: null,
    price_max: null,
    exclude: null,
    vendors: null,
    release_window_days: null,
  };

  it('unions resolved preset slugs into models and clears presets', async () => {
    const cfg = { ...base, models: ['x/explicit'], presets: ['top-flagship'] };
    const out = await expandPresets(cfg, async (slugs) =>
      slugs.includes('top-flagship') ? ['openai/gpt-5.1', 'anthropic/claude'] : [],
    );
    expect(out.models?.slice().sort()).toEqual(['anthropic/claude', 'openai/gpt-5.1', 'x/explicit']);
    expect(out.presets).toBeNull();
  });

  it('passes through unchanged when no presets', async () => {
    const cfg = { ...base, models: ['a'], presets: null };
    const out = await expandPresets(cfg, async () => {
      throw new Error('should not call resolver');
    });
    expect(out.models).toEqual(['a']);
  });
});
