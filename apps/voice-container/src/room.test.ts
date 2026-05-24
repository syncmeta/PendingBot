import { describe, expect, it } from 'bun:test';
import { realtimeKitPlayoutLimits, trimOldest } from './room';

describe('Room audio queue limits', () => {
  it('uses a low-latency playout window for RealtimeKit bot participants', () => {
    const rtk = realtimeKitPlayoutLimits();

    expect(rtk.prerollSamples).toBe(1_920);
    expect(rtk.capSamples).toBe(36_000);
  });

  it('reports how much stale audio was dropped when trimming a queue', () => {
    const chunks = [
      new Int16Array([1, 2, 3]),
      new Int16Array([4, 5, 6]),
      new Int16Array([7, 8, 9]),
    ];

    const dropped = trimOldest(chunks, 4);

    expect(dropped).toBe(5);
    expect(chunks.map((chunk) => Array.from(chunk))).toEqual([[6], [7, 8, 9]]);
  });
});
