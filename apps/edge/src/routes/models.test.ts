import { describe, expect, it } from 'vitest';
import { isNativeBackedOpenRouterSlug } from './models';

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
