import { describe, expect, it } from 'vitest';
import {
  safeRealtimeErrorSummary,
  safeRealtimeEventSummary,
  splitRealtimeUsage,
} from './voice-metering';

describe('voice metering helpers', () => {
  it('splits cached realtime usage out of full-rate text and audio buckets', () => {
    expect(
      splitRealtimeUsage({
        input_token_details: {
          text_tokens: 120,
          audio_tokens: 80,
          cached_tokens: 50,
          cached_tokens_details: {
            text_tokens: 30,
            audio_tokens: 20,
          },
        },
        output_token_details: {
          text_tokens: 13,
          audio_tokens: 17,
        },
      }),
    ).toEqual({
      inputTokens: 90,
      outputTokens: 13,
      audioInputTokens: 60,
      audioOutputTokens: 17,
      cacheReadTokens: 50,
    });
  });

  it('never lets cached token detail make full-rate buckets negative', () => {
    expect(
      splitRealtimeUsage({
        input_token_details: {
          text_tokens: 10,
          audio_tokens: 5,
          cached_tokens: 50,
          cached_tokens_details: {
            text_tokens: 30,
            audio_tokens: 20,
          },
        },
      }),
    ).toMatchObject({
      inputTokens: 0,
      audioInputTokens: 0,
      cacheReadTokens: 50,
    });
  });

  it('summarizes realtime events without copying instructions or raw payloads', () => {
    const summary = safeRealtimeEventSummary({
      type: 'session.updated',
      session: {
        id: 'sess_123',
        model: 'gpt-realtime-2',
        instructions: 'private memory',
      },
      response: {
        id: 'resp_123',
        usage: { secret: 'not for logs' },
      },
    });

    expect(summary).toEqual({
      type: 'session.updated',
      session_id: 'sess_123',
      model: 'gpt-realtime-2',
    });
    expect(JSON.stringify(summary)).not.toContain('private memory');
    expect(JSON.stringify(summary)).not.toContain('not for logs');
  });

  it('summarizes realtime errors without copying raw error messages', () => {
    expect(
      safeRealtimeErrorSummary({
        type: 'error',
        error: {
          type: 'invalid_request_error',
          code: 'bad_request',
          message: 'raw payload with private prompt',
        },
      }),
    ).toEqual({
      type: 'invalid_request_error',
      code: 'bad_request',
    });
  });
});
