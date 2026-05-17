import { describe, expect, it } from 'vitest';
import {
  blendedUsdPerMillion,
  pickAlias,
  type AliasJoinRow,
} from './router';

function row(
  opts: {
    id: string;
    providerSlug: string;
    providerPriority?: number;
    providerEnabled?: boolean;
    weight?: number;
    input?: number | null;
    cachedInput?: number | null;
    output?: number | null;
  },
): AliasJoinRow {
  return {
    id: opts.id,
    provider_id: opts.providerSlug + '-id',
    provider_model_id: 'whatever',
    weight: opts.weight ?? 1,
    input_price: opts.input ?? null,
    cached_input_price: opts.cachedInput ?? null,
    output_price: opts.output ?? null,
    cache_write_price: null,
    audio_input_price: null,
    audio_output_price: null,
    llm_providers: {
      id: opts.providerSlug + '-id',
      slug: opts.providerSlug,
      base_url: 'https://example.test/v1',
      priority: opts.providerPriority ?? 100,
      enabled: opts.providerEnabled ?? true,
      config: null,
    },
  };
}

describe('blendedUsdPerMillion', () => {
  it('returns null when input or output price is missing', () => {
    expect(
      blendedUsdPerMillion({
        inputPrice: null,
        cachedInputPrice: 0.1,
        outputPrice: 5,
      }),
    ).toBeNull();
    expect(
      blendedUsdPerMillion({
        inputPrice: 1,
        cachedInputPrice: 0.1,
        outputPrice: null,
      }),
    ).toBeNull();
  });

  it('uses cached_input when provided', () => {
    // 0.7*0.1 + 0.2*1 + 0.1*5 = 0.07 + 0.2 + 0.5 = 0.77
    expect(
      blendedUsdPerMillion({ inputPrice: 1, cachedInputPrice: 0.1, outputPrice: 5 }),
    ).toBeCloseTo(0.77);
  });

  it('falls back to input price when cache is unset', () => {
    // 0.7*1 + 0.2*1 + 0.1*5 = 1.4
    expect(
      blendedUsdPerMillion({ inputPrice: 1, cachedInputPrice: null, outputPrice: 5 }),
    ).toBeCloseTo(1.4);
  });
});

describe('pickAlias', () => {
  it('returns null when there are no candidates', () => {
    expect(pickAlias([], {})).toBeNull();
  });

  it('picks the highest-weight alias', () => {
    const lo = row({ id: 'lo', providerSlug: 'openai', weight: 1 });
    const hi = row({ id: 'hi', providerSlug: 'openrouter', weight: 100 });
    expect(pickAlias([lo, hi], {})?.id).toBe('hi');
  });

  it('breaks weight ties by provider.priority ASC', () => {
    const a = row({ id: 'a', providerSlug: 'openai', providerPriority: 200, weight: 5 });
    const b = row({ id: 'b', providerSlug: 'openrouter', providerPriority: 100, weight: 5 });
    expect(pickAlias([a, b], {})?.id).toBe('b');
  });

  it('breaks weight + priority ties by alias id', () => {
    const a = row({ id: 'aaa', providerSlug: 'openai', providerPriority: 100, weight: 5 });
    const b = row({ id: 'bbb', providerSlug: 'openrouter', providerPriority: 100, weight: 5 });
    expect(pickAlias([b, a], {})?.id).toBe('aaa');
  });

  it('skips disabled providers entirely', () => {
    const disabled = row({
      id: 'a',
      providerSlug: 'openai',
      providerEnabled: false,
      weight: 100,
    });
    const enabled = row({ id: 'b', providerSlug: 'openrouter', weight: 1 });
    expect(pickAlias([disabled, enabled], {})?.id).toBe('b');
  });

  it('honours preferProvider hard-pin over weight', () => {
    const heavy = row({ id: 'heavy', providerSlug: 'openrouter', weight: 100 });
    const pinned = row({ id: 'pinned', providerSlug: 'openai', weight: 1 });
    expect(
      pickAlias([heavy, pinned], { preferProvider: 'openai' })?.id,
    ).toBe('pinned');
  });

  it('returns null when preferProvider matches no candidate', () => {
    const r = row({ id: 'r', providerSlug: 'openai', weight: 1 });
    expect(pickAlias([r], { preferProvider: 'openrouter' })).toBeNull();
  });

  it('routes around an excluded provider', () => {
    const excluded = row({ id: 'ex', providerSlug: 'openrouter', weight: 100 });
    const ok = row({ id: 'ok', providerSlug: 'openai', weight: 1 });
    expect(
      pickAlias([excluded, ok], { excludeProviders: ['openrouter'] })?.id,
    ).toBe('ok');
  });

  it('respects weight=0 standby — only picks it when no live alternative remains', () => {
    const standby = row({ id: 'standby', providerSlug: 'openai', weight: 0 });
    const live = row({ id: 'live', providerSlug: 'openrouter', weight: 100 });
    // weight=0 keeps standby out of the live pool — the live alias wins.
    expect(pickAlias([standby, live], {})?.id).toBe('live');
    // With the live alias excluded, standby is the only candidate left.
    expect(
      pickAlias([standby, live], { excludeProviders: ['openrouter'] })?.id,
    ).toBe('standby');
  });
});
