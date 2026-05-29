import { describe, expect, it } from 'vitest';
import { modelEventCategory } from './billing-v2-dualwrite';

describe('modelEventCategory', () => {
  it('maps voice_call → voice_tokens (audio tokens priced separately)', () => {
    expect(modelEventCategory('voice_call')).toBe('voice_tokens');
  });

  it('maps every other task type → llm_tokens', () => {
    expect(modelEventCategory('message_reply')).toBe('llm_tokens');
    expect(modelEventCategory('group_router')).toBe('llm_tokens');
    expect(modelEventCategory('envelope')).toBe('llm_tokens');
    expect(modelEventCategory('title')).toBe('llm_tokens');
    expect(modelEventCategory('')).toBe('llm_tokens');
  });
});
