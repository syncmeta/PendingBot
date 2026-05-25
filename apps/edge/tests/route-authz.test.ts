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
});
