import { describe, expect, it } from 'vitest';
import { modelSwitchForOutcome } from './arena';

describe('modelSwitchForOutcome', () => {
  const modelA = {
    model_slug: 'model-a',
    model_provider: 'openai',
    parent_message_id: 'parent',
    conversation_id: 'conv',
  };
  const modelB = {
    model_slug: 'model-b',
    model_provider: null,
    parent_message_id: 'parent',
    conversation_id: 'conv',
  };

  it('maps a selected answer to the model that should become the conversation main model', () => {
    expect(modelSwitchForOutcome('a', modelA, modelB)).toEqual({
      model_slug: 'model-a',
      model_provider: 'openai',
    });
    expect(modelSwitchForOutcome('b', modelA, modelB)).toEqual({
      model_slug: 'model-b',
      model_provider: null,
    });
  });

  it('does not switch models for a tie', () => {
    expect(modelSwitchForOutcome('tie', modelA, modelB)).toBeNull();
  });
});
