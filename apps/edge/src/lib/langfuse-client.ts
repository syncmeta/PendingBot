// Shared singleton Langfuse client.
//
// The Langfuse SDK keeps per-instance state (the prompt cache and the
// ingestion batch buffer), so newing a client per call throws that state away
// and defeats the SDK's own caching. Both the prompt loader and the LLM-trace
// helper go through this single accessor instead.
//
// Returns null when the keys are unset — callers degrade (prompt loader falls
// back to KV-only / fails loud; trace helper no-ops).

import { Langfuse } from 'langfuse';
import type { Env } from '../types';

let client: Langfuse | null = null;
let clientKey: string | null = null;

export function getLangfuseClient(env: Env): Langfuse | null {
  if (!env.LANGFUSE_PUBLIC_KEY || !env.LANGFUSE_SECRET_KEY) return null;
  // Rebuild if the credentials change (keyed on public key + base url; the
  // secret moves together with the public key so it's not part of the key).
  const key = `${env.LANGFUSE_PUBLIC_KEY}@${env.LANGFUSE_BASE_URL ?? 'default'}`;
  if (client && clientKey === key) return client;
  client = new Langfuse({
    publicKey: env.LANGFUSE_PUBLIC_KEY,
    secretKey: env.LANGFUSE_SECRET_KEY,
    baseUrl: env.LANGFUSE_BASE_URL,
  });
  clientKey = key;
  return client;
}
