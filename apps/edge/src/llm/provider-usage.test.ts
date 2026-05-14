import { describe, expect, it } from 'vitest';
import { usageFromCompletion } from './provider-usage';

describe('usageFromCompletion', () => {
  it('reads cost from usage fields', () => {
    const usage = usageFromCompletion({
      prompt_tokens: 100,
      completion_tokens: 20,
      cost: 0.00123,
    });

    expect(usage.providerCostUsd).toBe(0.00123);
    expect(usage.inputTokens).toBe(100);
    expect(usage.outputTokens).toBe(20);
  });

  it('reads provider cost from top-level completion fields', () => {
    const usage = usageFromCompletion(
      {
        prompt_tokens: 100,
        completion_tokens: 20,
      },
      {
        id: 'gen-1',
        total_cost: 0.00456,
      },
    );

    expect(usage.providerCostUsd).toBe(0.00456);
  });

  it('reads LiteLLM-style response_cost when present', () => {
    const usage = usageFromCompletion(
      {
        prompt_tokens: 100,
        completion_tokens: 20,
      },
      {
        _hidden_params: { response_cost: 0.00789 },
      },
    );

    expect(usage.providerCostUsd).toBe(0.00789);
  });

  it('does not short-circuit top-level cost when usage is absent', () => {
    const usage = usageFromCompletion(null, {
      total_cost: 0.00012,
    });

    expect(usage.providerCostUsd).toBe(0.00012);
    expect(usage.inputTokens).toBe(0);
    expect(usage.outputTokens).toBe(0);
  });
});
