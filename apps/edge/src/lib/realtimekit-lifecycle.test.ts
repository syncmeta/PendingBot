import { describe, expect, it } from 'vitest';
import {
  addRealtimeKitHuman,
  removeRealtimeKitHuman,
  realtimeKitEndedEvent,
  realtimeKitStateEvent,
  type RealtimeKitRoomState,
} from './realtimekit-lifecycle';

const baseState: RealtimeKitRoomState = {
  id: 'meeting-1',
  title: 'Group voice',
  startedAt: 1_765_000_000_000,
  initiatorId: 'user-a',
  humanIds: ['user-a'],
};

describe('RealtimeKit room lifecycle helpers', () => {
  it('creates a formal room state when the first human joins', () => {
    const state = addRealtimeKitHuman(
      { id: 'meeting-1', title: 'Group voice' },
      'user-a',
      1_765_000_000_000,
    );

    expect(state).toEqual(baseState);
  });

  it('adds later humans without changing the original initiator or start time', () => {
    const state = addRealtimeKitHuman(baseState, 'user-b', 1_765_000_100_000);
    const duplicate = addRealtimeKitHuman(state, 'user-b', 1_765_000_200_000);

    expect(duplicate.startedAt).toBe(baseState.startedAt);
    expect(duplicate.initiatorId).toBe('user-a');
    expect(duplicate.humanIds).toEqual(['user-a', 'user-b']);
  });

  it('turns the cached room state into the conv-channel voice_call snapshot', () => {
    expect(realtimeKitStateEvent('conv-1', baseState)).toEqual({
      type: 'voice_call',
      event: 'state',
      conversation_id: 'conv-1',
      started_at: 1_765_000_000_000,
      initiator_id: 'user-a',
      participants: [{ kind: 'human', id: 'user-a' }],
      pending: [],
    });
  });

  it('removes humans and emits a compact ended event for the last leave', () => {
    expect(removeRealtimeKitHuman(baseState, 'user-a').humanIds).toEqual([]);
    expect(realtimeKitEndedEvent('conv-1')).toEqual({
      type: 'voice_call',
      event: 'ended',
      conversation_id: 'conv-1',
    });
  });
});
