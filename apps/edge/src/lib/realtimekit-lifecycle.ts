import { publishToHub, type VoiceCallEvent } from './realtime-publish';
import { serviceClient } from './supabase';
import type { Env } from '../types';

export interface RealtimeKitRoomState {
  id: string;
  title?: string | null;
  startedAt: number;
  initiatorId: string;
  humanIds: string[];
}

type CachedRealtimeKitMeeting = Pick<RealtimeKitRoomState, 'id' | 'title'> &
  Partial<Pick<RealtimeKitRoomState, 'startedAt' | 'initiatorId' | 'humanIds'>>;

export function addRealtimeKitHuman(
  state: CachedRealtimeKitMeeting,
  userId: string,
  nowMs: number,
): RealtimeKitRoomState {
  const humanIds = state.humanIds ?? [];
  return {
    id: state.id,
    title: state.title ?? null,
    startedAt: state.startedAt ?? nowMs,
    initiatorId: state.initiatorId ?? userId,
    humanIds: humanIds.includes(userId) ? humanIds : [...humanIds, userId],
  };
}

export function removeRealtimeKitHuman(
  state: RealtimeKitRoomState,
  userId: string,
): RealtimeKitRoomState {
  return {
    ...state,
    humanIds: state.humanIds.filter((id) => id !== userId),
  };
}

export function realtimeKitStateEvent(
  conversationId: string,
  state: RealtimeKitRoomState,
): VoiceCallEvent {
  return {
    type: 'voice_call',
    event: 'state',
    conversation_id: conversationId,
    started_at: state.startedAt,
    initiator_id: state.initiatorId,
    participants: state.humanIds.map((id) => ({ kind: 'human' as const, id })),
    pending: [],
  };
}

export function realtimeKitEndedEvent(conversationId: string): VoiceCallEvent {
  return {
    type: 'voice_call',
    event: 'ended',
    conversation_id: conversationId,
  };
}

export async function recordRealtimeKitState(
  env: Env,
  conversationId: string,
  state: RealtimeKitRoomState,
): Promise<void> {
  try {
    await serviceClient(env)
      .from('voice_active_calls')
      .upsert(
        {
          conversation_id: conversationId,
          started_at: new Date(state.startedAt).toISOString(),
          initiator_id: state.initiatorId,
        },
        { onConflict: 'conversation_id' },
      );
  } catch (err) {
    console.warn('[realtimekit] active-index upsert failed', err);
  }

  await publishToHub(env, `conv:${conversationId}`, realtimeKitStateEvent(conversationId, state));
}

export async function recordRealtimeKitEnded(
  env: Env,
  conversationId: string,
): Promise<void> {
  try {
    await serviceClient(env)
      .from('voice_active_calls')
      .delete()
      .eq('conversation_id', conversationId);
  } catch (err) {
    console.warn('[realtimekit] active-index clear failed', err);
  }

  await publishToHub(env, `conv:${conversationId}`, realtimeKitEndedEvent(conversationId));
}
