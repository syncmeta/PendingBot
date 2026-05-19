import { describe, expect, it } from 'vitest';
import {
  bytesToSamples,
  samplesToBytes,
  stereoToMono,
  monoToStereo,
  resample,
  mixPcm,
} from './pcm';

describe('bytesToSamples / samplesToBytes', () => {
  it('round-trips little-endian 16-bit PCM', () => {
    const samples = Int16Array.from([0, 1, -1, 32767, -32768, 1234]);
    const bytes = samplesToBytes(samples);
    expect(bytes.byteLength).toBe(samples.length * 2);
    expect(Array.from(bytesToSamples(bytes))).toEqual(Array.from(samples));
  });

  it('drops a trailing odd byte instead of throwing', () => {
    expect(bytesToSamples(new Uint8Array([1, 0, 2])).length).toBe(1);
  });

  it('decodes a known little-endian byte pair', () => {
    // 0x00 0x01 LE = 256
    expect(bytesToSamples(new Uint8Array([0x00, 0x01]))[0]).toBe(256);
  });
});

describe('stereoToMono / monoToStereo', () => {
  it('averages interleaved L/R into mono', () => {
    const stereo = Int16Array.from([100, 200, -100, -200]);
    expect(Array.from(stereoToMono(stereo))).toEqual([150, -150]);
  });

  it('duplicates mono samples into both channels', () => {
    expect(Array.from(monoToStereo(Int16Array.from([7, -7])))).toEqual([
      7, 7, -7, -7,
    ]);
  });
});

describe('resample', () => {
  it('returns the input unchanged when rates match', () => {
    const input = Int16Array.from([1, 2, 3]);
    expect(resample(input, 48000, 48000)).toBe(input);
  });

  it('halves the sample count downsampling 48k -> 24k', () => {
    const input = new Int16Array(480);
    expect(resample(input, 48000, 24000).length).toBe(240);
  });

  it('doubles the sample count upsampling 24k -> 48k', () => {
    const input = new Int16Array(240);
    expect(resample(input, 24000, 48000).length).toBe(480);
  });
});

describe('mixPcm', () => {
  it('returns silence for no streams', () => {
    expect(mixPcm([]).length).toBe(0);
  });

  it('passes a single stream through untouched', () => {
    const only = Int16Array.from([5, 6]);
    expect(mixPcm([only])).toBe(only);
  });

  it('sums samples across streams', () => {
    const mixed = mixPcm([
      Int16Array.from([100, 200]),
      Int16Array.from([10, 20]),
    ]);
    expect(Array.from(mixed)).toEqual([110, 220]);
  });

  it('clamps to the int16 range', () => {
    const mixed = mixPcm([
      Int16Array.from([30000, -30000]),
      Int16Array.from([30000, -30000]),
    ]);
    expect(Array.from(mixed)).toEqual([32767, -32768]);
  });

  it('treats shorter streams as silence past their end', () => {
    const mixed = mixPcm([
      Int16Array.from([1, 2, 3]),
      Int16Array.from([10]),
    ]);
    expect(Array.from(mixed)).toEqual([11, 2, 3]);
  });
});
