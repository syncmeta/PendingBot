import { describe, expect, it } from 'vitest';
import {
  bytesToSamples,
  samplesToBytes,
  stereoToMono,
  monoToStereo,
  resample,
  mixPcm,
  downsample48to24,
  newDownsampleState,
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

  it('sums and scales N streams by 1/sqrt(N)', () => {
    // Two streams: scale = 1/sqrt(2) ≈ 0.7071
    // (100+10)*0.7071 ≈ 77.78 → 78
    // (200+20)*0.7071 ≈ 155.56 → 156
    const mixed = mixPcm([
      Int16Array.from([100, 200]),
      Int16Array.from([10, 20]),
    ]);
    expect(Array.from(mixed)).toEqual([78, 156]);
  });

  it('clamps to the int16 range when even scaled peaks overflow', () => {
    // Two streams at full scale, in phase: (30000+30000)*0.7071 ≈ 42426
    // → clipped to 32767. Negative side: -60000*0.7071 ≈ -42426 → -32768.
    const mixed = mixPcm([
      Int16Array.from([30000, -30000]),
      Int16Array.from([30000, -30000]),
    ]);
    expect(Array.from(mixed)).toEqual([32767, -32768]);
  });

  it('treats shorter streams as silence past their end', () => {
    // First sample: (1+10)*0.7071 ≈ 7.78 → 8
    // Second:       (2+0)*0.7071  ≈ 1.41 → 1
    // Third:        (3+0)*0.7071  ≈ 2.12 → 2
    const mixed = mixPcm([
      Int16Array.from([1, 2, 3]),
      Int16Array.from([10]),
    ]);
    expect(Array.from(mixed)).toEqual([8, 1, 2]);
  });

  it('preserves perceived loudness — 4 in-phase streams stay near full scale', () => {
    // 4 streams each at half scale, in phase: sum=16384*4=65536,
    // scale=0.5 → 32768 → clipped to 32767 (just barely). Without
    // scaling we'd clip hard at 32767 from a sum of 65536 (50% reduction).
    const stream = Int16Array.from([16384]);
    const mixed = mixPcm([stream, stream, stream, stream]);
    expect(mixed[0]).toBe(32767);
  });
});

describe('downsample48to24', () => {
  it('returns an empty array for empty input', () => {
    expect(downsample48to24(new Int16Array(0), newDownsampleState()).length).toBe(0);
  });

  it('halves the sample count (ceil)', () => {
    expect(downsample48to24(new Int16Array(480), newDownsampleState()).length).toBe(240);
    // Odd-length input rounds up — keep samples at indices 0, 2, 4, ...
    expect(downsample48to24(new Int16Array(5), newDownsampleState()).length).toBe(3);
  });

  it('attenuates a 16 kHz tone (above 12 kHz Nyquist) more than a 1 kHz tone', () => {
    // Build a 1 kHz tone and a 16 kHz tone at 48 kHz, both full-scale.
    // After the LPF + decimate the 16 kHz tone (in the aliasing band)
    // should be heavily attenuated, while the 1 kHz tone passes through.
    const n = 4800; // 100 ms
    const tone1k = new Int16Array(n);
    const tone16k = new Int16Array(n);
    for (let i = 0; i < n; i++) {
      tone1k[i] = Math.round(16000 * Math.sin((2 * Math.PI * 1000 * i) / 48000));
      tone16k[i] = Math.round(16000 * Math.sin((2 * Math.PI * 16000 * i) / 48000));
    }
    const out1k = downsample48to24(tone1k, newDownsampleState());
    const out16k = downsample48to24(tone16k, newDownsampleState());
    // Skip the first 50 samples — biquad transient response.
    let peak1k = 0;
    let peak16k = 0;
    for (let i = 50; i < out1k.length; i++) {
      if (Math.abs(out1k[i]) > peak1k) peak1k = Math.abs(out1k[i]);
      if (Math.abs(out16k[i]) > peak16k) peak16k = Math.abs(out16k[i]);
    }
    // 1 kHz tone should come out roughly intact (within 50% of input peak).
    expect(peak1k).toBeGreaterThan(7000);
    // 16 kHz tone should be at least 6 dB down — ideally much more, but
    // a single 2nd-order biquad isn't a brick-wall. We mostly want to
    // assert the filter is *doing something*.
    expect(peak16k).toBeLessThan(peak1k / 2);
  });

  it('preserves filter state across calls so chunk boundaries are seamless', () => {
    // Two ways to filter 200 samples: one call of 200, or two calls of 100
    // sharing state. Outputs must match — otherwise we'd hear clicks at
    // every flush boundary as the filter restarts its transient.
    const n = 200;
    const input = new Int16Array(n);
    for (let i = 0; i < n; i++) {
      input[i] = Math.round(8000 * Math.sin((2 * Math.PI * 440 * i) / 48000));
    }
    const oneShot = downsample48to24(input, newDownsampleState());
    const state = newDownsampleState();
    const firstHalf = downsample48to24(input.subarray(0, 100), state);
    const secondHalf = downsample48to24(input.subarray(100, 200), state);
    const stitched = new Int16Array(firstHalf.length + secondHalf.length);
    stitched.set(firstHalf, 0);
    stitched.set(secondHalf, firstHalf.length);
    expect(Array.from(stitched)).toEqual(Array.from(oneShot));
  });
});
