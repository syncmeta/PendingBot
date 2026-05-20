// PCM audio helpers for the group-voice bridge (RoomVoiceDO).
//
// All PCM here is 16-bit signed little-endian. The CF Realtime SFU
// WebSocket adapter delivers and accepts 48 kHz interleaved stereo;
// OpenAI Realtime speaks 24 kHz mono. These helpers convert between the
// two and mix several human streams into one.
//
// The arithmetic is deliberately cheap — it runs per audio frame inside
// a Durable Object and the quality bar for group voice is low (the
// perceptual ceiling is already set by Opus on the phone leg and
// OpenAI's own 24 kHz, not by this internal SFU<->DO hop).

const INT16_MIN = -32768;
const INT16_MAX = 32767;

/** Reinterpret little-endian 16-bit PCM bytes as samples. */
export function bytesToSamples(bytes: Uint8Array): Int16Array {
  const usableBytes = bytes.byteLength - (bytes.byteLength % 2);
  const out = new Int16Array(usableBytes / 2);
  const dv = new DataView(bytes.buffer, bytes.byteOffset, usableBytes);
  for (let i = 0; i < out.length; i++) out[i] = dv.getInt16(i * 2, true);
  return out;
}

/** Serialize samples back to little-endian 16-bit PCM bytes. */
export function samplesToBytes(samples: Int16Array): Uint8Array {
  const out = new Uint8Array(samples.length * 2);
  const dv = new DataView(out.buffer);
  for (let i = 0; i < samples.length; i++) dv.setInt16(i * 2, samples[i], true);
  return out;
}

/** Interleaved stereo -> mono by averaging the two channels. */
export function stereoToMono(stereo: Int16Array): Int16Array {
  const out = new Int16Array(stereo.length >> 1);
  for (let i = 0; i < out.length; i++) {
    out[i] = (stereo[2 * i] + stereo[2 * i + 1]) >> 1;
  }
  return out;
}

/** Mono -> interleaved stereo by duplicating each sample into L and R. */
export function monoToStereo(mono: Int16Array): Int16Array {
  const out = new Int16Array(mono.length * 2);
  for (let i = 0; i < mono.length; i++) {
    out[2 * i] = mono[i];
    out[2 * i + 1] = mono[i];
  }
  return out;
}

/**
 * Linear-interpolation resampler. Covers both the 48 kHz -> 24 kHz
 * downsample (OpenAI input) and the 24 kHz -> 48 kHz upsample (adapter
 * ingest). Cheap on purpose — no anti-alias filtering.
 */
export function resample(
  input: Int16Array,
  fromRate: number,
  toRate: number,
): Int16Array {
  if (fromRate === toRate || input.length === 0) return input;
  const ratio = fromRate / toRate;
  const outLen = Math.max(1, Math.round(input.length / ratio));
  const out = new Int16Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const pos = i * ratio;
    const lo = Math.floor(pos);
    const hi = Math.min(lo + 1, input.length - 1);
    const frac = pos - lo;
    out[i] = (input[lo] * (1 - frac) + input[hi] * frac) | 0;
  }
  return out;
}

/**
 * Sum N mono streams into one, scaled by 1/sqrt(N) so simultaneous
 * peaks don't clip and so perceived loudness stays roughly constant as
 * more talkers join. Final clamp catches the rare in-phase peak case.
 * The output is as long as the longest input; shorter streams are
 * treated as silence past their end.
 *
 * Why sqrt(N) and not 1/N: voice signals are largely uncorrelated, so
 * their summed RMS grows as sqrt(N). Dividing by sqrt(N) preserves
 * perceived energy across N=1..4 — the bot doesn't suddenly hear a
 * quieter room when a second human joins.
 */
export function mixPcm(streams: Int16Array[]): Int16Array {
  if (streams.length === 0) return new Int16Array(0);
  if (streams.length === 1) return streams[0];
  const scale = 1 / Math.sqrt(streams.length);
  let len = 0;
  for (const s of streams) len = Math.max(len, s.length);
  const out = new Int16Array(len);
  for (let i = 0; i < len; i++) {
    let sum = 0;
    for (const s of streams) sum += i < s.length ? s[i] : 0;
    const scaled = Math.round(sum * scale);
    out[i] =
      scaled < INT16_MIN ? INT16_MIN : scaled > INT16_MAX ? INT16_MAX : scaled;
  }
  return out;
}

// 2nd-order Butterworth lowpass coefficients precomputed for
// fs=48000, fc=9000. Below the 12 kHz Nyquist of the 24 kHz output by a
// 3 kHz transition band — kills the aliasing band hard (~-16 dB at the
// fold-back edge once cascaded) while preserving most of voice content
// (most speech energy lives under 4 kHz; sibilance tops out around 8 kHz).
//
// Direct Form II Transposed: y = b0*x + s1; s1' = b1*x - a1*y + s2;
// s2' = b2*x - a2*y. RBJ Audio Cookbook, Q = 1/sqrt(2).
const LPF_B0 = 0.1867;
const LPF_B1 = 0.3734;
const LPF_B2 = 0.1867;
const LPF_A1 = -0.4630;
const LPF_A2 = 0.2097;

/**
 * Filter state for the anti-alias downsampler. One instance per stream;
 * must persist across calls or every chunk starts with the filter's
 * transient and clicks at the boundary.
 */
export interface DownsampleState {
  s1: number;
  s2: number;
}

export function newDownsampleState(): DownsampleState {
  return { s1: 0, s2: 0 };
}

/**
 * Anti-aliased 48 kHz → 24 kHz mono PCM downsample. Applies a 2nd-order
 * Butterworth lowpass before 2:1 decimation — without this, content
 * between 12 kHz and 24 kHz (sibilants, mic noise) folds back into the
 * audible band as inharmonic buzz and the bot hears "noisy" audio.
 *
 * Replaces the linear-interp `resample(_, 48000, 24000)` path for the
 * human→bot direction. The reverse (24→48 upsample for bot→SFU) still
 * uses `resample` — upsampling has imaging artifacts but no aliasing,
 * and the SFU's Opus encoder lowpasses on the way out anyway.
 */
export function downsample48to24(
  input: Int16Array,
  state: DownsampleState,
): Int16Array {
  if (input.length === 0) return input;
  const outLen = (input.length + 1) >> 1;
  const out = new Int16Array(outLen);
  let s1 = state.s1;
  let s2 = state.s2;
  let outIdx = 0;
  for (let i = 0; i < input.length; i++) {
    const x = input[i];
    const y = LPF_B0 * x + s1;
    s1 = LPF_B1 * x - LPF_A1 * y + s2;
    s2 = LPF_B2 * x - LPF_A2 * y;
    if ((i & 1) === 0) {
      const o = Math.round(y);
      out[outIdx++] = o < INT16_MIN ? INT16_MIN : o > INT16_MAX ? INT16_MAX : o;
    }
  }
  state.s1 = s1;
  state.s2 = s2;
  return out;
}
