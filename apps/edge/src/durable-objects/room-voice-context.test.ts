import { describe, expect, it } from 'vitest';
import { roomMediaToken, type RoomMediaTokenContext } from './room-voice-context';

describe('room voice context helpers', () => {
  it('uses a dedicated lightweight media token for RealtimeKit rooms', () => {
    const ctx: RoomMediaTokenContext = {
      mediaProvider: 'realtimekit',
      mediaToken: 'rtk-media-token',
    };

    expect(roomMediaToken(ctx)).toBe('rtk-media-token');
  });

  it('keeps SFU rooms on their adapter token', () => {
    const ctx: RoomMediaTokenContext = {
      mediaProvider: 'sfu',
      adapterToken: 'sfu-adapter-token',
    };

    expect(roomMediaToken(ctx)).toBe('sfu-adapter-token');
  });
});
