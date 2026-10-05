import type { Env } from '../types';
import { runEnvelope } from '../lib/envelope-runner';
import type { EnvelopeMessage } from './envelope-types';

// ENVELOPE_QUEUE consumer. One message = one envelope run. runEnvelope
// owns its own error handling (flips the row to status='error' and
// audits whatever was spent), so every message is acked — never retried:
// a redelivery would re-run a half-billed letter from scratch. If the
// invocation itself dies, the row stays 'running' and the envelope reaper
// cron flips it to 'error'.
export async function consumeEnvelopeBatch(
  batch: MessageBatch<EnvelopeMessage>,
  env: Env,
  run: typeof runEnvelope = runEnvelope,
): Promise<void> {
  for (const msg of batch.messages) {
    try {
      await run({ env, ...msg.body });
    } catch (err) {
      console.error('[queue:envelope] run failed', msg.body?.envelopeRunId, err);
    }
    msg.ack();
  }
}
