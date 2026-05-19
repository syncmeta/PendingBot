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
 * Sum several mono streams into one, clamping to the int16 range. The
 * output is as long as the longest input; shorter streams are treated as
 * silence past their end. Callers are responsible for time-aligning the
 * streams before mixing.
 */
export function mixPcm(streams: Int16Array[]): Int16Array {
  if (streams.length === 0) return new Int16Array(0);
  if (streams.length === 1) return streams[0];
  let len = 0;
  for (const s of streams) len = Math.max(len, s.length);
  const out = new Int16Array(len);
  for (let i = 0; i < len; i++) {
    let sum = 0;
    for (const s of streams) sum += i < s.length ? s[i] : 0;
    out[i] = sum < INT16_MIN ? INT16_MIN : sum > INT16_MAX ? INT16_MAX : sum;
  }
  return out;
}
