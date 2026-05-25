import { describe, expect, it } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
} from './_helpers/fake-supabase';

installFakeSupabaseMock();

describe('route authorization helpers', () => {
  it('loads a group conversation only when the caller can see it and is a participant', async () => {
    const { loadGroupConversationForUser } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      conversations: [
        {
          id: '11111111-1111-4111-8111-111111111111',
          conversation_type: 'group',
          user_id: 'owner-1',
        },
      ],
      conversation_participants: [
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          participant_type: 'user',
          participant_id: 'user-1',
          role: 'member',
        },
      ],
    });

    const result = await loadGroupConversationForUser(
      makeFakeEnv(db),
      'test-jwt',
      'user-1',
      '11111111-1111-4111-8111-111111111111',
    );

    expect(result).toEqual({
      ok: true,
      conversation: {
        id: '11111111-1111-4111-8111-111111111111',
        conversation_type: 'group',
        user_id: 'owner-1',
      },
      membership: {
        participant_id: 'user-1',
        role: 'member',
      },
    });
  });

  it('does not load non-group conversations through the group helper', async () => {
    const { loadGroupConversationForUser } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      conversations: [
        {
          id: '11111111-1111-4111-8111-111111111111',
          conversation_type: 'user_bot',
          user_id: 'user-1',
        },
      ],
    });

    const result = await loadGroupConversationForUser(
      makeFakeEnv(db),
      'test-jwt',
      'user-1',
      '11111111-1111-4111-8111-111111111111',
    );

    expect(result).toEqual({ ok: false, code: 'not_found' });
  });

  it('rejects a visible group when the caller is not a participant', async () => {
    const { loadGroupConversationForUser } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      conversations: [
        {
          id: '11111111-1111-4111-8111-111111111111',
          conversation_type: 'group',
          user_id: 'owner-1',
        },
      ],
      conversation_participants: [],
    });

    const result = await loadGroupConversationForUser(
      makeFakeEnv(db),
      'test-jwt',
      'user-1',
      '11111111-1111-4111-8111-111111111111',
    );

    expect(result).toEqual({ ok: false, code: 'forbidden' });
  });

  it('requires one of the accepted group roles', async () => {
    const { requireGroupRole } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      conversation_participants: [
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          participant_type: 'user',
          participant_id: 'owner-1',
          role: 'owner',
        },
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          participant_type: 'user',
          participant_id: 'member-1',
          role: 'member',
        },
      ],
    });

    await expect(
      requireGroupRole(
        makeFakeEnv(db),
        '11111111-1111-4111-8111-111111111111',
        'owner-1',
        ['owner', 'admin'],
      ),
    ).resolves.toEqual({ ok: true, role: 'owner' });

    await expect(
      requireGroupRole(
        makeFakeEnv(db),
        '11111111-1111-4111-8111-111111111111',
        'member-1',
        ['owner', 'admin'],
      ),
    ).resolves.toEqual({ ok: false, code: 'forbidden', role: 'member' });
  });

  it('checks bot and human group participant membership by participant type', async () => {
    const { isGroupBotParticipant, isGroupHumanParticipant } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      conversation_participants: [
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          participant_type: 'bot',
          participant_id: '22222222-2222-4222-8222-222222222222',
          role: 'member',
        },
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          participant_type: 'user',
          participant_id: 'user-1',
          role: 'member',
        },
      ],
    });

    await expect(
      isGroupBotParticipant(
        makeFakeEnv(db),
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      ),
    ).resolves.toEqual({
      ok: true,
      participantId: '22222222-2222-4222-8222-222222222222',
    });

    await expect(
      isGroupBotParticipant(
        makeFakeEnv(db),
        '11111111-1111-4111-8111-111111111111',
        'user-1',
      ),
    ).resolves.toEqual({ ok: false, code: 'forbidden' });

    await expect(
      isGroupHumanParticipant(
        makeFakeEnv(db),
        '11111111-1111-4111-8111-111111111111',
        'user-1',
      ),
    ).resolves.toEqual({ ok: true, participantId: 'user-1' });
  });

  it('finds the singleton user_user conversation shared by two users', async () => {
    const { findSharedUserUserConversation } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      conversation_participants: [
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          'conversations.conversation_type': 'user_user',
          participant_type: 'user',
          participant_id: 'user-1',
        },
        {
          conversation_id: '22222222-2222-4222-8222-222222222222',
          'conversations.conversation_type': 'group',
          participant_type: 'user',
          participant_id: 'user-1',
        },
        {
          conversation_id: '11111111-1111-4111-8111-111111111111',
          participant_type: 'user',
          participant_id: 'user-2',
        },
      ],
    });

    await expect(
      findSharedUserUserConversation(makeFakeEnv(db), 'user-1', 'user-2'),
    ).resolves.toEqual({
      ok: true,
      conversationId: '11111111-1111-4111-8111-111111111111',
    });

    await expect(
      findSharedUserUserConversation(makeFakeEnv(db), 'user-1', 'user-3'),
    ).resolves.toEqual({ ok: true, conversationId: null });
  });

  it('authorizes message delete only for authored rows or owned bot presentation rows', async () => {
    const { authorizeMessageDelete } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      messages: [
        {
          id: '11111111-1111-4111-8111-111111111111',
          user_id: 'user-1',
          sender_bot_id: null,
          conversation_id: 'conv-user',
        },
        {
          id: '22222222-2222-4222-8222-222222222222',
          user_id: null,
          sender_bot_id: 'bot-1',
          conversation_id: 'conv-user',
        },
        {
          id: '33333333-3333-4333-8333-333333333333',
          user_id: 'user-2',
          sender_bot_id: null,
          conversation_id: 'conv-group',
        },
      ],
      conversations: [
        {
          id: 'conv-user',
          conversation_type: 'user_bot',
          user_id: 'user-1',
        },
        {
          id: 'conv-group',
          conversation_type: 'group',
          user_id: 'user-1',
        },
      ],
    });
    const env = makeFakeEnv(db);

    await expect(
      authorizeMessageDelete(env, '11111111-1111-4111-8111-111111111111', 'user-1'),
    ).resolves.toMatchObject({
      ok: true,
      target: {
        authoredByCaller: true,
        conversationId: 'conv-user',
      },
    });

    await expect(
      authorizeMessageDelete(env, '22222222-2222-4222-8222-222222222222', 'user-1'),
    ).resolves.toMatchObject({
      ok: true,
      target: {
        authoredByCaller: false,
        conversationOwnedByCaller: true,
        conversationType: 'user_bot',
        isBotReply: true,
      },
    });

    await expect(
      authorizeMessageDelete(env, '33333333-3333-4333-8333-333333333333', 'user-1'),
    ).resolves.toEqual({ ok: false, code: 'forbidden' });
  });

  it('authorizes bot use for private ownership and public invites', async () => {
    const { authorizeBotUse } = await import('../src/lib/route-authz');
    const db = makeFakeDb({
      bot_invites: [
        {
          bot_id: 'bot-public',
          user_id: 'invited-user',
        },
      ],
    });
    const env = makeFakeEnv(db);

    await expect(
      authorizeBotUse(env, { id: 'bot-private', visibility: 'private', creator_id: 'owner-user' }, 'owner-user'),
    ).resolves.toEqual({ ok: true, allowed: true });

    await expect(
      authorizeBotUse(env, { id: 'bot-private', visibility: 'private', creator_id: 'owner-user' }, 'other-user'),
    ).resolves.toEqual({ ok: false, code: 'forbidden' });

    await expect(
      authorizeBotUse(env, { id: 'bot-public', visibility: 'public_invite', creator_id: 'owner-user' }, 'invited-user'),
    ).resolves.toEqual({ ok: true, allowed: true });

    await expect(
      authorizeBotUse(env, { id: 'bot-public', visibility: 'public_invite', creator_id: 'owner-user' }, 'other-user'),
    ).resolves.toEqual({ ok: false, code: 'forbidden' });

    await expect(
      authorizeBotUse(env, { id: 'bot-public', visibility: 'public_invite', creator_id: 'owner-user' }, 'owner-user'),
    ).resolves.toEqual({ ok: true, allowed: true });
  });
});
