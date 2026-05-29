// Control protocol between RoomVoiceDO (control plane) and this media
// container (audio plane). One bidirectional WebSocket per room, opened by
// the DO to the container's /control endpoint.
//
//   DO  -> container : ControlCommand  (start / add-bot / remove-bot / ...)
//   container -> DO  : ControlEvent    (bot-tool / turn-usage / leg-closed)
//
// The DO keeps ALL policy: permissions, billing, presence, roster. The
// container only does media (RTK WebRTC client, mix, OpenAI socket) and
// forwards the two things it learns from the OpenAI leg — tool calls and
// per-turn usage — back to the DO. Keep this file byte-identical to the
// edge-side copy at apps/edge/src/durable-objects/room-media-protocol.ts.

/** OpenAI turn-detection block (tri-state mirrors the DO's BotSpec). */
export type TurnDetection =
  | null
  | {
      type: 'server_vad' | 'semantic_vad';
      threshold?: number;
      prefix_padding_ms?: number;
      silence_duration_ms?: number;
      eagerness?: 'low' | 'medium' | 'high' | 'auto';
      create_response?: boolean;
      interrupt_response?: boolean;
    };

/** Per-bot spec the DO hands to the container when a bot joins. */
export interface ContainerBotSpec {
  botId: string;
  model: string;
  instructions: string;
  voice: string;
  /** undefined = omit (OpenAI default); null = disable VAD; object = apply. */
  turnDetection?: TurnDetection;
  /** Realtime function tools — the DO computes these (it owns permissions). */
  tools: unknown[];
  /** RealtimeKit participant credentials for the headless bot client. */
  realtimeKit?: {
    meetingId: string;
    participantId: string;
    authToken: string;
  };
}

/** Usage block inside an OpenAI realtime `response.done` event. */
export interface RealtimeUsage {
  input_token_details?: {
    text_tokens?: number;
    audio_tokens?: number;
    cached_tokens?: number;
    cached_tokens_details?: { text_tokens?: number; audio_tokens?: number };
  };
  output_token_details?: { text_tokens?: number; audio_tokens?: number };
}

export interface MediaParticipantDiagnostic {
  kind: 'human' | 'bot';
  id: string;
  speaking: boolean;
  audioLevel: number;
  source: 'container' | 'model';
  playoutDepthMs?: number;
  underruns?: number;
  maxGapMs?: number;
  droppedOutputMs?: number;
  inputLevel?: number;
  inputFrames?: number;
  quietFrames?: number;
  realtimeKitConnected?: boolean;
  modelSessionReady?: boolean;
}

export interface MediaDiagnostics {
  atMs: number;
  participants: MediaParticipantDiagnostic[];
}

// ── DO -> container ──────────────────────────────────────────────────

export type ControlCommand =
  // Arm (or RESET) the room: the RTK bridge token it echoes in ?t=, and
  // the OpenAI key (passed at runtime so it stays out of the image).
  // `start` is idempotent: receiving it on a warm/reused container
  // instance tears down any existing bot legs + timers BEFORE arming
  // fresh, so a DO that reconnected after a control-socket drop can
  // replay `start` + re-`add-bot` to rebuild room state cleanly without
  // double-running timers or leaking sockets (see Room.start).
  | { t: 'start'; token: string; openaiApiKey: string }
  | { t: 'add-bot'; spec: ContainerBotSpec }
  | { t: 'remove-bot'; botId: string }
  | { t: 'update-tools'; botId: string; tools: unknown[] }
  // Result of a tool the bot invoked (kick / designate_admin) so it can
  // acknowledge out loud. leave_call / end_call get no result (torn down).
  | { t: 'tool-result'; botId: string; callId: string; output: string }
  // Heartbeat: the DO pings on a fixed cadence; the container replies
  // `pong`. A missed pong window is how the DO detects a half-open
  // control socket and triggers reconnect + resync.
  | { t: 'ping' }
  | { t: 'end' };

// ── container -> DO ──────────────────────────────────────────────────

export type ControlEvent =
  | { t: 'ready' }
  // The bot invoked a function tool — the DO decides what to do (it owns
  // permissions + roster). `args` is the raw JSON arguments string.
  | { t: 'bot-tool'; botId: string; name: string; callId: string; args?: string }
  // One completed model turn — the DO bills it from OpenAI's own numbers.
  | { t: 'turn-usage'; botId: string; usage: RealtimeUsage }
  | { t: 'diagnostics'; diagnostics: MediaDiagnostics }
  // The bot's OpenAI socket closed — the DO drops the leg + rebroadcasts.
  | { t: 'leg-closed'; botId: string }
  // Reply to a `ping` — the DO records lastPongAt to keep the link live.
  | { t: 'pong' };
