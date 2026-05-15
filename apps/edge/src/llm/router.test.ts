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
      auth_type: 'bearer',
      secret_ref: 'X_KEY',
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
  it('picks the cheapest blended price across providers', () => {
    // openrouter:  blended = 0.7*0.1 + 0.2*1 + 0.1*5 = 0.77
    // worldrouter: blended = 0.7*0.07 + 0.2*0.7 + 0.1*3.5 = 0.539
    const or = row({
      id: 'or',
      providerSlug: 'openrouter',
      input: 1,
      cachedInput: 0.1,
      output: 5,
      weight: 0,
    });
    const wr = row({
      id: 'wr',
      providerSlug: 'worldrouter',
      input: 0.7,
      cachedInput: 0.07,
      output: 3.5,
      weight: 100,
    });
    expect(pickAlias([or, wr], {})?.id).toBe('wr');
  });

  it('routes around the cheaper provider when it is excluded', () => {
    const or = row({ id: 'or', providerSlug: 'openrouter', input: 1, output: 5 });
    const wr = row({
      id: 'wr',
      providerSlug: 'worldrouter',
      input: 0.7,
      output: 3.5,
    });
    expect(
      pickAlias([or, wr], { excludeProviders: ['worldrouter'] })?.id,
    ).toBe('or');
  });

  it('prefers priced aliases over unpriced ones even when unpriced has higher weight', () => {
    const priced = row({
      id: 'priced',
      providerSlug: 'openrouter',
      input: 1,
      output: 5,
      weight: 1,
    });
    const unpriced = row({
      id: 'unpriced',
      providerSlug: 'worldrouter',
      input: null,
      output: null,
      weight: 100,
    });
    expect(pickAlias([priced, unpriced], {})?.id).toBe('priced');
  });

  it('falls back to weight DESC then provider.priority ASC on equal blended price', () => {
    const cheaper = row({
      id: 'a',
      providerSlug: 'openrouter',
      providerPriority: 200,
      input: 1,
      output: 5,
      weight: 1,
    });
    const sameButPreferred = row({
      id: 'b',
      providerSlug: 'worldrouter',
      providerPriority: 100,
      input: 1,
      output: 5,
      weight: 1,
    });
    // Equal blended, equal weight → provider.priority breaks tie
    expect(pickAlias([cheaper, sameButPreferred], {})?.id).toBe('b');
  });

  it('skips disabled providers entirely', () => {
    const disabled = row({
      id: 'a',
      providerSlug: 'openrouter',
      providerEnabled: false,
      input: 0.5,
      output: 1,
    });
    const enabled = row({
      id: 'b',
      providerSlug: 'worldrouter',
      input: 1,
      output: 5,
    });
    expect(pickAlias([disabled, enabled], {})?.id).toBe('b');
  });

  it('honours preferProvider hard-pin', () => {
    const cheap = row({
      id: 'cheap',
      providerSlug: 'worldrouter',
      input: 0.5,
      output: 1,
    });
    const preferred = row({
      id: 'pref',
      providerSlug: 'openrouter',
      input: 1,
      output: 5,
    });
    expect(
      pickAlias([cheap, preferred], { preferProvider: 'openrouter' })?.id,
    ).toBe('pref');
  });

  it('respects weight=0 standby — only picks it when no live alternative remains', () => {
    const standby = row({
      id: 'standby',
      providerSlug: 'openrouter',
      input: 0.5,
      output: 1,
      weight: 0,
    });
    const live = row({
      id: 'live',
      providerSlug: 'worldrouter',
      input: 1,
      output: 5,
      weight: 100,
    });
    // Standby has lower blended price, but weight=0 takes it out of the
    // live pool — the higher-priced live alias still wins.
    expect(pickAlias([standby, live], {})?.id).toBe('live');
    // With the live alias excluded, the standby becomes the only
    // candidate and is picked.
    expect(
      pickAlias([standby, live], { excludeProviders: ['worldrouter'] })?.id,
    ).toBe('standby');
  });
});
