// Wire codec for the CF Realtime SFU WebSocket adapter.
//
// Vendored from apps/edge/src/lib/ws-adapter-proto.ts. Media frames over
// the adapter WebSocket are Protocol Buffers:
//
//   message Packet {
//     uint32 sequenceNumber = 1;  // Stream mode (WebRTC -> WS) only
//     uint32 timestamp      = 2;  // Stream mode (WebRTC -> WS) only
//     bytes  payload        = 5;  // PCM audio data
//   }

export interface AdapterPacket {
  sequenceNumber: number;
  timestamp: number;
  payload: Uint8Array;
}

function readVarint(buf: Uint8Array, pos: number): [value: number, next: number] {
  let result = 0;
  let shift = 0;
  let p = pos;
  for (;;) {
    if (p >= buf.length) break;
    const b = buf[p++];
    result += (b & 0x7f) * 2 ** shift;
    if ((b & 0x80) === 0) break;
    shift += 7;
  }
  return [result, p];
}

function writeVarint(value: number, out: number[]): void {
  let v = Math.max(0, Math.floor(value));
  while (v > 0x7f) {
    out.push((v & 0x7f) | 0x80);
    v = Math.floor(v / 128);
  }
  out.push(v & 0x7f);
}

/** Decode a Stream-mode Packet (sequenceNumber, timestamp, payload). */
export function decodePacket(buf: Uint8Array): AdapterPacket {
  let sequenceNumber = 0;
  let timestamp = 0;
  let payload: Uint8Array = new Uint8Array(0);
  let pos = 0;
  while (pos < buf.length) {
    const tag = buf[pos++];
    const field = tag >> 3;
    const wireType = tag & 0x07;
    if (wireType === 0) {
      const [value, next] = readVarint(buf, pos);
      pos = next;
      if (field === 1) sequenceNumber = value;
      else if (field === 2) timestamp = value;
    } else if (wireType === 2) {
      const [len, next] = readVarint(buf, pos);
      pos = next;
      if (field === 5) payload = buf.subarray(pos, pos + len);
      pos += len;
    } else {
      break;
    }
  }
  return { sequenceNumber, timestamp, payload };
}

/** Encode an Ingest "buffer"-mode Packet — only the payload field is set. */
export function encodePayloadPacket(payload: Uint8Array): Uint8Array {
  const header: number[] = [];
  header.push((5 << 3) | 2); // field 5, wire type 2 (length-delimited)
  writeVarint(payload.length, header);
  const out = new Uint8Array(header.length + payload.length);
  out.set(header, 0);
  out.set(payload, header.length);
  return out;
}
