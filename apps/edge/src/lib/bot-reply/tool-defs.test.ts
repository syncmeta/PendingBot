import { describe, expect, it } from 'vitest';
import {
  buildOpenRouterServerTools,
  parseWebSearchConfig,
  type WebSearchConfig,
} from './tool-defs';

describe('parseWebSearchConfig', () => {
  it('returns null when config is absent or has no webSearch key', () => {
    expect(parseWebSearchConfig(null)).toBeNull();
    expect(parseWebSearchConfig(undefined)).toBeNull();
    expect(parseWebSearchConfig({})).toBeNull();
    expect(parseWebSearchConfig({ voice: {} })).toBeNull();
    expect(parseWebSearchConfig([])).toBeNull();
  });

  it('reads known camelCase fields and drops unknown / wrong-typed ones', () => {
    const cfg = parseWebSearchConfig({
      webSearch: {
        enabled: false,
        engine: 'exa',
        maxResults: 8,
        maxTotalResults: 20,
        searchContextSize: 'high',
        allowedDomains: ['arxiv.org', '', 42],
        excludedDomains: ['reddit.com'],
        bogus: 'ignored',
      },
    });
    expect(cfg).toEqual({
      enabled: false,
      engine: 'exa',
      maxResults: 8,
      maxTotalResults: 20,
      searchContextSize: 'high',
      allowedDomains: ['arxiv.org'],
      excludedDomains: ['reddit.com'],
    });
  });

  it('rejects out-of-enum engine / contextSize and non-finite numbers', () => {
    const cfg = parseWebSearchConfig({
      webSearch: {
        engine: 'bing',
        searchContextSize: 'huge',
        maxResults: Number.NaN,
      },
    });
    expect(cfg).toEqual({});
  });
});

describe('buildOpenRouterServerTools', () => {
  it('emits a bare web_search plus web_fetch + datetime when no config', () => {
    expect(buildOpenRouterServerTools()).toEqual([
      { type: 'openrouter:web_search' },
      { type: 'openrouter:web_fetch' },
      { type: 'openrouter:datetime' },
    ]);
  });

  it('maps camelCase config to OpenRouter snake_case parameters', () => {
    const ws: WebSearchConfig = {
      engine: 'exa',
      maxResults: 5,
      maxTotalResults: 15,
      searchContextSize: 'medium',
      allowedDomains: ['example.com'],
      excludedDomains: ['reddit.com'],
    };
    expect(buildOpenRouterServerTools(ws)[0]).toEqual({
      type: 'openrouter:web_search',
      parameters: {
        engine: 'exa',
        max_results: 5,
        max_total_results: 15,
        search_context_size: 'medium',
        allowed_domains: ['example.com'],
        excluded_domains: ['reddit.com'],
      },
    });
  });

  it('drops web_search entirely when enabled is false, keeps fetch + datetime', () => {
    expect(buildOpenRouterServerTools({ enabled: false })).toEqual([
      { type: 'openrouter:web_fetch' },
      { type: 'openrouter:datetime' },
    ]);
  });

  it('keeps web_search on (no parameters) when enabled is true with no other knobs', () => {
    expect(buildOpenRouterServerTools({ enabled: true })[0]).toEqual({
      type: 'openrouter:web_search',
    });
  });
});
