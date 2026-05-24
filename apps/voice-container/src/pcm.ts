// PCM audio helpers for the group-voice media container.
//
// The container is a separate Bun process and can't import worker source.
// RealtimeKit bridge audio is 48 kHz mono; OpenAI Realtime audio is
// 24 kHz mono.
//
// All PCM here is 16-bit signed little-endian.

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

/**
 * Sum N mono streams into one, scaled by 1/sqrt(N) so simultaneous peaks
 * don't clip and perceived loudness stays roughly constant as more
 * talkers join. Output is as long as the longest input.
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

// 2nd-order Butterworth lowpass, fs=48000 fc=9000 (RBJ, Q=1/sqrt(2)).
// Direct Form II Transposed. Anti-alias before 2:1 decimation.
const LPF_B0 = 0.1867;
const LPF_B1 = 0.3734;
const LPF_B2 = 0.1867;
const LPF_A1 = -0.4630;
const LPF_A2 = 0.2097;

/** Filter state for the anti-alias downsampler; one per stream, persists. */
export interface DownsampleState {
  s1: number;
  s2: number;
}

export function newDownsampleState(): DownsampleState {
  return { s1: 0, s2: 0 };
}

/** Anti-aliased 48 kHz -> 24 kHz mono downsample (human mic -> bot ears). */
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

/** Concatenate a list of PCM sample chunks into one buffer. */
export function concatSamples(chunks: Int16Array[]): Int16Array {
  if (chunks.length === 0) return new Int16Array(0);
  if (chunks.length === 1) return chunks[0];
  let len = 0;
  for (const c of chunks) len += c.length;
  const out = new Int16Array(len);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}
