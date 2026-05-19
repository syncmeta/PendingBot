import { describe, expect, it } from 'vitest';
import { decodePacket, encodePayloadPacket } from './ws-adapter-proto';

describe('encodePayloadPacket / decodePacket', () => {
  it('round-trips a payload-only (Ingest buffer-mode) packet', () => {
    const payload = new Uint8Array([1, 2, 3, 250, 0, 99]);
    const decoded = decodePacket(encodePayloadPacket(payload));
    expect(Array.from(decoded.payload)).toEqual(Array.from(payload));
    expect(decoded.sequenceNumber).toBe(0);
    expect(decoded.timestamp).toBe(0);
  });

  it('encodes field 5 with a length-delimited (wire type 2) tag', () => {
    const encoded = encodePayloadPacket(new Uint8Array([0xaa]));
    expect(encoded[0]).toBe((5 << 3) | 2); // 0x2a
    expect(encoded[1]).toBe(1); // length varint
    expect(encoded[2]).toBe(0xaa);
  });

  it('handles a payload longer than one varint byte', () => {
    const payload = new Uint8Array(500).fill(7);
    const decoded = decodePacket(encodePayloadPacket(payload));
    expect(decoded.payload.length).toBe(500);
    expect(decoded.payload[499]).toBe(7);
  });

  it('decodes a Stream-mode packet with all three fields', () => {
    // field 1 (seq) varint=300, field 2 (ts) varint=70000, field 5 payload=[9,9]
    const buf = new Uint8Array([
      0x08, 0xac, 0x02, // field 1: 300
      0x10, 0xf0, 0xa2, 0x04, // field 2: 70000
      0x2a, 0x02, 0x09, 0x09, // field 5: payload [9,9]
    ]);
    const decoded = decodePacket(buf);
    expect(decoded.sequenceNumber).toBe(300);
    expect(decoded.timestamp).toBe(70000);
    expect(Array.from(decoded.payload)).toEqual([9, 9]);
  });

  it('decodes an empty buffer to zeroed fields', () => {
    const decoded = decodePacket(new Uint8Array(0));
    expect(decoded.sequenceNumber).toBe(0);
    expect(decoded.payload.length).toBe(0);
  });
});
