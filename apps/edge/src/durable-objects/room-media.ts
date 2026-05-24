import { Container } from '@cloudflare/containers';
import type { Env } from '../types';

// Container-enabled Durable Object wrapping the group-voice media container
// (apps/voice-container). One instance per room, keyed by conversation_id
// via getContainer(env.ROOM_MEDIA, conversationId).
//
// It only manages the container lifecycle and proxies inbound WebSocket
// upgrades to it — the base Container.fetch() auto-forwards WS to the
// container's defaultPort. RoomVoiceDO opens the /control socket through
// this binding; the headless RealtimeKit page uses the container-local
// /rtk/bot endpoint.
//
// All audio + pacing lives in the container; all policy (permissions,
// billing, presence, roster) stays in RoomVoiceDO. See
// apps/voice-container/src/{index,room,protocol}.ts.
export class RoomMediaContainerDO extends Container<Env> {
  defaultPort = 8080;
  // A call runs up to 30 min; the control + RTK sockets keep the
  // container active for its lifetime. Once the call ends (RoomVoiceDO
  // sends 'end' and the sockets close) reclaim the idle instance promptly
  // so we don't pay for warm-but-empty containers between calls.
  sleepAfter = '1m';
}
