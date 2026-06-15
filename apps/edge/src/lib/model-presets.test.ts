import { describe, it, expect } from 'vitest';
import { resolvePresetModelsFromCatalog, type PresetDef } from './model-presets';
import type { OpenRouterModelOut } from '../routes/models';

const M = (over: Partial<OpenRouterModelOut>): OpenRouterModelOut => ({
  slug: 'x', display_name: 'X', provider: 'openai', release_date: '2026-01-01',
  context_length: null, supports_vision: false, blended_usd_per_million: 1,
  lmarena_license: null, lmarena_organization: null, lmarena_scores: {},
  source: 'openrouter', model_provider: null, ...over,
});

const catalog: OpenRouterModelOut[] = [
  M({ slug: 'gpt-5.1', provider: 'openai', source: 'openai', model_provider: 'openai', blended_usd_per_million: 10, release_date: '2026-05-01' }),
  M({ slug: 'gpt-5.1-mini', provider: 'openai', source: 'openai', model_provider: 'openai', blended_usd_per_million: 1, release_date: '2026-06-01' }),
  M({ slug: 'claude-opus-4-8', provider: 'anthropic', source: 'anthropic', model_provider: 'anthropic', blended_usd_per_million: 20, release_date: '2026-04-01' }),
  M({ slug: 'deepseek/deepseek-v3', provider: 'deepseek', source: 'openrouter', blended_usd_per_million: 0.5, release_date: '2026-03-01' }),
  M({ slug: 'meta-llama/llama-4', provider: 'meta-llama', source: 'openrouter', blended_usd_per_million: 0.2, release_date: '2026-06-10', lmarena_scores: { text: { rating: 1400, rank: 1, vote_count: 99, category: 'overall', leaderboard_publish_date: null } } }),
];

it('top_flagship most_expensive picks priciest per author, native row', () => {
  const def: PresetDef = { slug: 'top-flagship', resolver_kind: 'top_flagship', params: { authors: ['openai', 'anthropic'], flagship: 'most_expensive' }, title: '', description: '' };
  expect(resolvePresetModelsFromCatalog(def, catalog).sort()).toEqual(['claude-opus-4-8', 'gpt-5.1']);
});

it('latest_per_vendor picks newest per provider', () => {
  const def: PresetDef = { slug: 'latest', resolver_kind: 'latest_per_vendor', params: { count: 8 }, title: '', description: '' };
  const out = resolvePresetModelsFromCatalog(def, catalog);
  expect(out).toContain('gpt-5.1-mini'); // 06-01 > 05-01 for openai
  expect(out).toContain('meta-llama/llama-4');
});

it('most_popular ranks by lmarena text rating', () => {
  const def: PresetDef = { slug: 'pop', resolver_kind: 'most_popular', params: { count: 1 }, title: '', description: '' };
  expect(resolvePresetModelsFromCatalog(def, catalog)).toEqual(['meta-llama/llama-4']);
});
