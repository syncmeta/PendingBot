import { describe, it, expect } from 'vitest';
import { resolveFastest, resolvePresetModelsFromCatalog, type PresetDef } from './model-presets';
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

it('latest_per_vendor excludes :free, openrouter meta, and unpriced/noise rows', () => {
  const noisy: OpenRouterModelOut[] = [
    M({ slug: 'openrouter/fusion', provider: 'openrouter', blended_usd_per_million: -1, release_date: '2026-06-20' }),
    M({ slug: 'nvidia/nemotron-content-safety:free', provider: 'nvidia', blended_usd_per_million: 0, release_date: '2026-06-19' }),
    M({ slug: 'nex-agi/nex-n2:free', provider: 'nex-agi', blended_usd_per_million: 0, release_date: '2026-06-18' }),
    // 非 native-backed 厂商、有真实定价 → 唯一应留下的行
    M({ slug: 'mistralai/mistral-large', provider: 'mistralai', source: 'openrouter', blended_usd_per_million: 4, release_date: '2026-05-01' }),
  ];
  const def: PresetDef = { slug: 'latest', resolver_kind: 'latest_per_vendor', params: { count: 8 }, title: '', description: '' };
  const out = resolvePresetModelsFromCatalog(def, noisy);
  expect(out).toEqual(['mistralai/mistral-large']); // meta/free/占位 三个噪声行都被过滤
});

it('fastest ranks candidates by injected throughput, respects min_rating', async () => {
  const cat = [
    M({ slug: 'a/fast-strong', provider: 'a', blended_usd_per_million: 1, lmarena_scores: { text: { rating: 1300, rank: 1, vote_count: 1, category: 'overall', leaderboard_publish_date: null } } }),
    M({ slug: 'a/slow-strong', provider: 'a', blended_usd_per_million: 1, lmarena_scores: { text: { rating: 1300, rank: 2, vote_count: 1, category: 'overall', leaderboard_publish_date: null } } }),
    M({ slug: 'a/fast-weak', provider: 'a', blended_usd_per_million: 1, lmarena_scores: { text: { rating: 900, rank: 9, vote_count: 1, category: 'overall', leaderboard_publish_date: null } } }),
  ];
  const tput: Record<string, number> = { 'a/fast-strong': 200, 'a/slow-strong': 10, 'a/fast-weak': 999 };
  const out = await resolveFastest(cat, { count: 2, min_rating: 1200 }, async (slug) => tput[slug] ?? null);
  expect(out).toEqual(['a/fast-strong', 'a/slow-strong']); // weak 被 min_rating 滤掉
});

it('latest_in_series picks newest non-variant per line; segment-precise exclusion (no mini→minimax false positive)', () => {
  const cat: OpenRouterModelOut[] = [
    // anthropic 系列：4.8 > 4.7；-fast 变体走 chatRows 已剔
    M({ slug: 'claude-opus-4-8', provider: 'anthropic', source: 'anthropic', model_provider: 'anthropic', release_date: '2026-05-27' }),
    M({ slug: 'claude-opus-4-7', provider: 'anthropic', source: 'anthropic', model_provider: 'anthropic', release_date: '2026-04-16' }),
    // openai：基础版与 -pro 同日 → tiebreak 取 slug 字典序小的基础版；-mini 段排除
    M({ slug: 'gpt-5.5', provider: 'openai', source: 'openai', model_provider: 'openai', release_date: '2026-04-24' }),
    M({ slug: 'gpt-5.5-pro', provider: 'openai', source: 'openai', model_provider: 'openai', release_date: '2026-04-24' }),
    M({ slug: 'gpt-5.5-mini', provider: 'openai', source: 'openai', model_provider: 'openai', release_date: '2026-05-09' }),
    // minimax：'minimax-m3' 分段 [minimax,m3] 不含 'mini' 段 → 不能被误杀
    M({ slug: 'minimax/minimax-m3', provider: 'minimax', source: 'openrouter', release_date: '2026-05-31' }),
    M({ slug: 'minimax/minimax-m2', provider: 'minimax', source: 'openrouter', release_date: '2026-02-12' }),
    // deepseek：同日 pro vs flash → flash 段排除，选 pro
    M({ slug: 'deepseek/deepseek-v4-pro', provider: 'deepseek', source: 'openrouter', release_date: '2026-04-24' }),
    M({ slug: 'deepseek/deepseek-v4-flash', provider: 'deepseek', source: 'openrouter', release_date: '2026-04-24' }),
    // 滚动别名：~ 前缀 / -latest 后缀都应排除
    M({ slug: '~openai/gpt-latest', provider: 'openai', source: 'openai', model_provider: 'openai', release_date: '2026-06-01' }),
  ];
  const def: PresetDef = {
    slug: 'top', resolver_kind: 'latest_in_series',
    params: { lines: [
      { author: 'anthropic', series: 'claude-opus' },
      { author: 'openai', series: 'gpt-5' },
      { author: 'minimax', series: 'minimax-m' },
      { author: 'deepseek', series: 'deepseek-v' },
    ] },
    title: '', description: '',
  };
  expect(resolvePresetModelsFromCatalog(def, cat)).toEqual([
    'claude-opus-4-8',
    'gpt-5.5',
    'minimax/minimax-m3',
    'deepseek/deepseek-v4-pro',
  ]);
});
