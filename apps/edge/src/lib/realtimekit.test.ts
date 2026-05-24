import { describe, expect, it, vi } from 'vitest';
import {
  addRealtimeKitParticipant,
  bootstrapRealtimeKitGroupVoice,
  createRealtimeKitMeeting,
  kickAllRealtimeKitParticipants,
  realtimeKitAppFromEnv,
} from './realtimekit';
import type { Env } from '../types';

function env(overrides: Partial<Env> = {}): Env {
  return {
    CF_ACCOUNT_ID: 'acct-gateway',
    REALTIMEKIT_APP_ID: 'rtk-app',
    REALTIMEKIT_API_TOKEN: 'rtk-token',
    ...overrides,
  } as Env;
}

function fetchCall(fetcher: ReturnType<typeof vi.fn>, index: number): [string, RequestInit] {
  const calls = fetcher.mock.calls as unknown as Array<[string, RequestInit]>;
  return calls[index];
}

describe('realtimeKitAppFromEnv', () => {
  it('uses the dedicated account id when set', () => {
    expect(
      realtimeKitAppFromEnv(
        env({ REALTIMEKIT_ACCOUNT_ID: 'acct-rtk', CF_ACCOUNT_ID: 'acct-gateway' }),
      ),
    ).toEqual({
      accountId: 'acct-rtk',
      appId: 'rtk-app',
      apiToken: 'rtk-token',
    });
  });

  it('falls back to CF_ACCOUNT_ID for the account id', () => {
    expect(realtimeKitAppFromEnv(env())!.accountId).toBe('acct-gateway');
  });

  it('returns null when required credentials are missing', () => {
    expect(realtimeKitAppFromEnv(env({ REALTIMEKIT_API_TOKEN: undefined }))).toBeNull();
  });
});

describe('createRealtimeKitMeeting', () => {
  it('creates an audio meeting through the Cloudflare RealtimeKit API', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        data: { id: 'meeting-1', title: 'group voice' },
      }, { status: 201 }),
    );

    const meeting = await createRealtimeKitMeeting(
      { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
      {
        title: 'group voice',
        sessionKeepAliveSeconds: 60,
      },
      fetcher,
    );

    expect(meeting).toEqual({ id: 'meeting-1', title: 'group voice' });
    expect(fetcher).toHaveBeenCalledTimes(1);
    const call = fetchCall(fetcher, 0);
    expect(call[0]).toBe(
      'https://api.cloudflare.com/client/v4/accounts/acct-1/realtime/kit/app-1/meetings',
    );
    const init = call[1];
    expect(init.method).toBe('POST');
    expect(init.headers).toMatchObject({
      Authorization: 'Bearer secret-1',
      'Content-Type': 'application/json',
    });
    expect(JSON.parse(init.body as string)).toEqual({
      title: 'group voice',
      persist_chat: false,
      record_on_start: false,
      live_stream_on_start: false,
      transcribe_on_end: false,
      summarize_on_end: false,
      session_keep_alive_time_in_secs: 60,
    });
  });
});

describe('addRealtimeKitParticipant', () => {
  it('adds a participant and returns the token needed by a WebRTC client', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        data: {
          id: 'participant-1',
          custom_participant_id: 'user:u1',
          name: 'Alice',
          preset_name: 'group_call_host',
          token: 'join-token',
        },
      }, { status: 201 }),
    );

    const participant = await addRealtimeKitParticipant(
      { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
      'meeting-1',
      {
        customParticipantId: 'user:u1',
        displayName: 'Alice',
        presetName: 'group_call_host',
      },
      fetcher,
    );

    expect(participant).toEqual({
      id: 'participant-1',
      customParticipantId: 'user:u1',
      displayName: 'Alice',
      presetName: 'group_call_host',
      token: 'join-token',
    });
    const call = fetchCall(fetcher, 0);
    expect(call[0]).toBe(
      'https://api.cloudflare.com/client/v4/accounts/acct-1/realtime/kit/app-1/meetings/meeting-1/participants',
    );
    const init = call[1];
    expect(JSON.parse(init.body as string)).toEqual({
      custom_participant_id: 'user:u1',
      name: 'Alice',
      preset_name: 'group_call_host',
    });
  });

  it('throws a useful error when Cloudflare rejects the participant', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: false,
        error: { code: 10020, message: 'unknown preset' },
      }, { status: 400 }),
    );

    await expect(
      addRealtimeKitParticipant(
        { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
        'meeting-1',
        {
          customParticipantId: 'user:u1',
          presetName: 'missing',
        },
        fetcher,
      ),
    ).rejects.toThrow('RealtimeKit POST /meetings/meeting-1/participants failed: 10020 unknown preset');
  });

  it('accepts the authToken shape returned by older RealtimeKit docs', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        data: {
          id: 'participant-1',
          custom_participant_id: 'user:u1',
          name: 'Alice',
          preset_name: 'group_call_host',
          authToken: 'join-token',
        },
      }, { status: 201 }),
    );

    await expect(
      addRealtimeKitParticipant(
        { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
        'meeting-1',
        {
          customParticipantId: 'user:u1',
          displayName: 'Alice',
          presetName: 'group_call_host',
        },
        fetcher,
      ),
    ).resolves.toMatchObject({ token: 'join-token' });
  });

  it('accepts a top-level token from the participant response envelope', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        token: 'join-token',
        data: {
          id: 'participant-1',
          custom_participant_id: 'user:u1',
          name: 'Alice',
          preset_name: 'group_call_host',
        },
      }, { status: 201 }),
    );

    await expect(
      addRealtimeKitParticipant(
        { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
        'meeting-1',
        {
          customParticipantId: 'user:u1',
          displayName: 'Alice',
          presetName: 'group_call_host',
        },
        fetcher,
      ),
    ).resolves.toMatchObject({ token: 'join-token' });
  });

  it('refreshes a participant token when add participant omits it', async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(
        Response.json({
          success: true,
          data: {
            id: 'participant-1',
            custom_participant_id: 'user:u1',
            name: 'Alice',
            preset_name: 'group_call_host',
          },
        }, { status: 201 }),
      )
      .mockResolvedValueOnce(
        Response.json({
          success: true,
          data: { token: 'refreshed-token' },
        }, { status: 200 }),
      );

    const participant = await addRealtimeKitParticipant(
      { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
      'meeting-1',
      {
        customParticipantId: 'user:u1',
        displayName: 'Alice',
        presetName: 'group_call_host',
      },
      fetcher,
    );

    expect(participant.token).toBe('refreshed-token');
    expect(fetchCall(fetcher, 1)[0]).toBe(
      'https://api.cloudflare.com/client/v4/accounts/acct-1/realtime/kit/app-1/meetings/meeting-1/participants/participant-1/token',
    );
  });

  it('uses the requested preset when the live API returns preset_id instead of preset_name', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        data: {
          id: 'participant-1',
          custom_participant_id: 'user:u1',
          name: 'Alice',
          preset_id: 'preset-uuid',
          token: 'join-token',
        },
      }, { status: 201 }),
    );

    await expect(
      addRealtimeKitParticipant(
        { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
        'meeting-1',
        {
          customParticipantId: 'user:u1',
          displayName: 'Alice',
          presetName: 'group_call_host',
        },
        fetcher,
      ),
    ).resolves.toMatchObject({
      presetName: 'group_call_host',
      token: 'join-token',
    });
  });
});

describe('bootstrapRealtimeKitGroupVoice', () => {
  it('creates one meeting and participant tokens for the human plus selected bot', async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(
        Response.json({
          success: true,
          data: { id: 'meeting-1', title: 'PendingBot group voice c1' },
        }, { status: 201 }),
      )
      .mockResolvedValueOnce(
        Response.json({
          success: true,
          data: {
            id: 'participant-human',
            custom_participant_id: 'pendingbot:user:u1:nonce',
            name: 'Alice',
            preset_name: 'group_call_host',
            token: 'human-token',
          },
        }, { status: 201 }),
      )
      .mockResolvedValueOnce(
        Response.json({
          success: true,
          data: {
            id: 'participant-bot',
            custom_participant_id: 'pendingbot:bot:b1:nonce',
            name: 'Marin',
            preset_name: 'group_call_participant',
            token: 'bot-token',
          },
        }, { status: 201 }),
      );

    const result = await bootstrapRealtimeKitGroupVoice(
      { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
      {
        conversationId: 'c1',
        humanUserId: 'u1',
        humanDisplayName: 'Alice',
        humanPresetName: 'group_call_host',
        bot: {
          botId: 'b1',
          displayName: 'Marin',
          presetName: 'group_call_participant',
        },
      },
      fetcher,
    );

    expect(result.meeting).toEqual({ id: 'meeting-1', title: 'PendingBot group voice c1' });
    expect(result.human).toMatchObject({
      id: 'participant-human',
      displayName: 'Alice',
      presetName: 'group_call_host',
      token: 'human-token',
    });
    expect(result.human.customParticipantId).toMatch(/^pendingbot:user:u1:/);
    expect(result.bot).toMatchObject({
      id: 'participant-bot',
      displayName: 'Marin',
      presetName: 'group_call_participant',
      token: 'bot-token',
    });
    expect(result.bot?.customParticipantId).toMatch(/^pendingbot:bot:b1:/);

    expect(JSON.parse(fetchCall(fetcher, 1)[1].body as string)).toMatchObject({
      custom_participant_id: expect.stringMatching(/^pendingbot:user:u1:/),
      preset_name: 'group_call_host',
    });
    expect(JSON.parse(fetchCall(fetcher, 2)[1].body as string)).toMatchObject({
      custom_participant_id: expect.stringMatching(/^pendingbot:bot:b1:/),
      preset_name: 'group_call_participant',
    });
  });

  it('reuses an existing meeting id when supplied', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        data: {
          id: 'participant-human',
          custom_participant_id: 'pendingbot:user:u1:nonce',
          name: 'Alice',
          preset_name: 'group_call_host',
          token: 'human-token',
        },
      }, { status: 201 }),
    );

    const result = await bootstrapRealtimeKitGroupVoice(
      { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
      {
        conversationId: 'c1',
        meeting: { id: 'meeting-existing', title: 'Existing' },
        humanUserId: 'u1',
        humanDisplayName: 'Alice',
        humanPresetName: 'group_call_host',
      },
      fetcher,
    );

    expect(result).toMatchObject({
      meeting: { id: 'meeting-existing', title: 'Existing' },
      human: {
        id: 'participant-human',
        displayName: 'Alice',
        presetName: 'group_call_host',
        token: 'human-token',
      },
    });
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(fetchCall(fetcher, 0)[0]).toContain('/meetings/meeting-existing/participants');
  });
});

describe('kickAllRealtimeKitParticipants', () => {
  it('kicks every participant from an active RealtimeKit meeting session', async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        success: true,
        data: { kicked_participants_count: 2 },
      }, { status: 200 }),
    );

    const kicked = await kickAllRealtimeKitParticipants(
      { accountId: 'acct-1', appId: 'app-1', apiToken: 'secret-1' },
      'meeting-1',
      fetcher,
    );

    expect(kicked).toBe(2);
    expect(fetcher).toHaveBeenCalledTimes(1);
    const call = fetchCall(fetcher, 0);
    expect(call[0]).toBe(
      'https://api.cloudflare.com/client/v4/accounts/acct-1/realtime/kit/app-1/meetings/meeting-1/active-session/kick-all',
    );
    expect(call[1].method).toBe('POST');
    expect(JSON.parse(call[1].body as string)).toEqual({});
  });
});
