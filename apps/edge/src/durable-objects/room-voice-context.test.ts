import { describe, expect, it } from 'vitest';
import { roomMediaToken, type RoomMediaTokenContext } from './room-voice-context';

describe('room voice context helpers', () => {
  it('uses the RealtimeKit media token directly', () => {
    const ctx: RoomMediaTokenContext = {
      mediaToken: 'rtk-media-token',
    };

    expect(roomMediaToken(ctx)).toBe('rtk-media-token');
  });
});
