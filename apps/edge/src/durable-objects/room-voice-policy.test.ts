import { describe, expect, it } from 'vitest';
import { isCallAdminTargetPresent } from './room-voice-policy';

describe('room voice call-admin policy', () => {
  it('allows designating a current human or bot participant', () => {
    expect(isCallAdminTargetPresent('user-a', ['user-a'], [])).toBe(true);
    expect(isCallAdminTargetPresent('bot-a', [], ['bot-a'])).toBe(true);
  });

  it('rejects blank, unknown, and not-yet-joined targets', () => {
    expect(isCallAdminTargetPresent('', ['user-a'], ['bot-a'])).toBe(false);
    expect(isCallAdminTargetPresent('user-b', ['user-a'], ['bot-a'])).toBe(false);
    expect(isCallAdminTargetPresent('bot-b', ['user-a'], ['bot-a'])).toBe(false);
  });
});
