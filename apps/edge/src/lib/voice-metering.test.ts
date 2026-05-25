import { beforeEach, describe, expect, it, vi } from 'vitest';
import { _resetMarkupCache } from './billing';
import {
  broadcastVoiceCostPreview,
  enqueueVoiceTurnAudit,
  safeRealtimeErrorSummary,
  safeRealtimeEventSummary,
  splitRealtimeUsage,
} from './voice-metering';

describe('voice metering helpers', () => {
  beforeEach(() => {
    _resetMarkupCache();
  });

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

  it('enqueues voice audit rows with shared realtime metadata shape', async () => {
    const send = vi.fn(async () => undefined);
    const env = { AUDIT_QUEUE: { send } };
    const route = {
      modelToCall: 'gpt-realtime-2',
      provider: { slug: 'openai', apiStyle: 'responses' },
      client: {},
    };

    const auditId = await enqueueVoiceTurnAudit({
      env: env as never,
      route: route as never,
      userId: 'user_123',
      conversationId: 'conv_123',
      usage: {
        inputTokens: 1,
        outputTokens: 2,
        audioInputTokens: 3,
        audioOutputTokens: 4,
        cacheReadTokens: 5,
      },
      source: 'group_voice_call',
      roomId: 'room_123',
      turnIndex: 7,
      botId: 'bot_123',
      presentUserIds: ['user_123', 'user_456'],
      startedAt: Date.now(),
    });

    expect(auditId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({
        route: {
          modelToCall: 'gpt-realtime-2',
          provider: { slug: 'openai', apiStyle: 'responses' },
        },
        opts: expect.objectContaining({
          userId: 'user_123',
          conversationId: 'conv_123',
          taskType: 'voice_call',
          status: 'success',
          inputTokens: 1,
          outputTokens: 2,
          audioInputTokens: 3,
          audioOutputTokens: 4,
          cacheReadTokens: 5,
          metadata: {
            source: 'group_voice_call',
            room_id: 'room_123',
            turn_index: 7,
            bot_id: 'bot_123',
            present_user_ids: ['user_123', 'user_456'],
          },
        }),
      }),
    );
  });

  it('broadcasts a live PND cost preview for known realtime models', async () => {
    const fetch = vi.fn(async () => ({
      ok: true,
      json: async () => ({ delivered: 1 }),
    }));
    const env = {
      REALTIME_HUB: {
        idFromName: vi.fn((name: string) => name),
        get: vi.fn(() => ({ fetch })),
      },
    };
    const supa = {
      from: vi.fn(() => ({
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        maybeSingle: vi.fn(async () => ({ data: { value: 2 }, error: null })),
      })),
    };

    const cumulative = await broadcastVoiceCostPreview({
      env: env as never,
      supa: supa as never,
      conversationId: 'conv_123',
      sessionId: 'sess_123',
      modelToCall: 'gpt-realtime-mini-2025-12-15',
      usage: {
        inputTokens: 1_000_000,
        outputTokens: 0,
        audioInputTokens: 0,
        audioOutputTokens: 0,
        cacheReadTokens: 0,
      },
      cumulativePnd: 10,
      logPrefix: '[test]',
      atMs: 12345,
    });

    expect(cumulative).toBe(3250);
    expect(fetch).toHaveBeenCalledWith('https://hub.internal/publish', {
      method: 'POST',
      body: JSON.stringify({
        type: 'voice_cost',
        conversation_id: 'conv_123',
        session_id: 'sess_123',
        delta_pnd: 3240,
        cumulative_pnd: 3250,
        at_ms: 12345,
      }),
    });
  });

  it('does not publish or advance cumulative cost for unknown realtime models', async () => {
    const fetch = vi.fn();
    const env = {
      REALTIME_HUB: {
        idFromName: vi.fn((name: string) => name),
        get: vi.fn(() => ({ fetch })),
      },
    };
    const supa = { from: vi.fn() };

    await expect(
      broadcastVoiceCostPreview({
        env: env as never,
        supa: supa as never,
        conversationId: 'conv_123',
        sessionId: 'sess_123',
        modelToCall: 'unknown-model',
        usage: {
          inputTokens: 1_000_000,
          outputTokens: 0,
          audioInputTokens: 0,
          audioOutputTokens: 0,
          cacheReadTokens: 0,
        },
        cumulativePnd: 10,
        logPrefix: '[test]',
      }),
    ).resolves.toBe(10);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('keeps the previous cumulative cost if the realtime hub is unavailable', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const env = {
      REALTIME_HUB: {
        idFromName: vi.fn((name: string) => name),
        get: vi.fn(() => {
          throw new Error('hub unavailable');
        }),
      },
    };
    const supa = {
      from: vi.fn(() => ({
        select: vi.fn().mockReturnThis(),
        eq: vi.fn().mockReturnThis(),
        maybeSingle: vi.fn(async () => ({ data: { value: 2 }, error: null })),
      })),
    };

    await expect(
      broadcastVoiceCostPreview({
        env: env as never,
        supa: supa as never,
        conversationId: 'conv_123',
        sessionId: 'sess_123',
        modelToCall: 'gpt-realtime-mini-2025-12-15',
        usage: {
          inputTokens: 1_000_000,
          outputTokens: 0,
          audioInputTokens: 0,
          audioOutputTokens: 0,
          cacheReadTokens: 0,
        },
        cumulativePnd: 10,
        logPrefix: '[test]',
      }),
    ).resolves.toBe(10);
    expect(warn).toHaveBeenCalledWith('[test] broadcast cost failed', expect.any(Error));
    warn.mockRestore();
  });
});
