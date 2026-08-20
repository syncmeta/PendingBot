import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
} from './_helpers/fake-supabase';

const sendApns = vi.fn(async (_input: { deviceToken: string }) => ({ ok: true as const }));

vi.mock('../src/lib/apns', () => ({
  sendApns,
}));

installFakeSupabaseMock();

describe('notifyConversationUsers', () => {
  beforeEach(() => {
    sendApns.mockClear();
  });

  it('does not send message pushes to muted conversation participants', async () => {
    const db = makeFakeDb({
      conversation_participants: [
        {
          conversation_id: 'conv-1',
          participant_type: 'user',
          participant_id: 'sender',
          muted: false,
        },
        {
          conversation_id: 'conv-1',
          participant_type: 'user',
          participant_id: 'active-recipient',
          muted: false,
        },
        {
          conversation_id: 'conv-1',
          participant_type: 'user',
          participant_id: 'muted-recipient',
          muted: true,
        },
      ],
      users: [
        { id: 'active-recipient', custom_fields: {} },
        { id: 'muted-recipient', custom_fields: {} },
      ],
      device_tokens: [
        {
          id: 'tok-active',
          user_id: 'active-recipient',
          token: 'active-token',
          platform: 'ios',
          is_active: true,
          kind: 'apns',
          metadata: { apns_env: 'dev' },
        },
        {
          id: 'tok-muted',
          user_id: 'muted-recipient',
          token: 'muted-token',
          platform: 'ios',
          is_active: true,
          kind: 'apns',
          metadata: { apns_env: 'dev' },
        },
      ],
    });
    const env = makeFakeEnv(db);
    Object.assign(env, {
      APNS_TOPIC: 'com.pendingbot.test',
      APNS_TEAM_ID: 'team',
      APNS_KEY_ID_DEV: 'kid',
      APNS_KEY_ID_PROD: 'kid',
      APNS_KEY_DEV: 'key',
      APNS_KEY_PROD: 'key',
    });

    const { notifyConversationUsers } = await import('../src/lib/push');
    await notifyConversationUsers({
      env,
      conversationId: 'conv-1',
      excludeUserId: 'sender',
      senderName: 'Alice',
      contentPreview: 'hello',
    });

    expect(sendApns).toHaveBeenCalledTimes(1);
    expect(sendApns.mock.calls[0]?.[0].deviceToken).toBe('active-token');
  });
});
