import { describe, expect, it } from 'vitest';
import { voicePayerSecondWeights } from './group-billing';

describe('group billing metadata helpers', () => {
  it('extracts positive per-user voice seconds for weighted media splits', () => {
    expect(
      Object.fromEntries(
        voicePayerSecondWeights({
          present_user_seconds: {
            'user-a': 30,
            'user-b': '60',
            'user-c': 0,
            'user-d': -1,
            'user-e': 'bad',
          },
        }),
      ),
    ).toEqual({
      'user-a': 30,
      'user-b': 60,
    });
  });

  it('ignores malformed voice second metadata', () => {
    expect(voicePayerSecondWeights(null).size).toBe(0);
    expect(voicePayerSecondWeights({ present_user_seconds: [] }).size).toBe(0);
    expect(voicePayerSecondWeights({ present_user_seconds: 'bad' }).size).toBe(0);
  });
});
