import type { EnvelopeSettings } from '../lib/envelope-runner';

// Wire shape of a message on ENVELOPE_QUEUE: everything runEnvelope needs
// except the worker Env (the consumer has its own). Must stay
// structured-clone-safe — Cloudflare Queues serializes the body.
//
// Why a queue and not ctx.waitUntil: an envelope loop runs for minutes
// (MAX_WALL_MS in envelope-loop.ts), but waitUntil only extends an HTTP
// invocation by 30s after the response is sent — the runtime then cancels
// the promise without running its catch, so every user-triggered letter
// died after turn 0 and was later reaped to status='error' (「写丢了」).
// A queue consumer invocation gets 15 minutes of wall time.
export interface EnvelopeMessage {
  envelopeRunId: string;
  conversationId: string;
  userId: string;
  botId: string;
  settings: EnvelopeSettings;
}

// Queue name as bound in wrangler.jsonc; the shared `queue` handler in
// src/index.ts routes on batch.queue.
export const ENVELOPE_QUEUE_NAME = 'pendingbot-envelope';
