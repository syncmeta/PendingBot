import type { PendingBotVoiceAgent } from "./agent";

export interface Env {
  VOICE_AGENT: DurableObjectNamespace<PendingBotVoiceAgent>;
  AI: Ai;

  // Cloudflare account id + a token scoped "Realtime — Admin"; the agent
  // pipeline backend (agents.realtime.cloudflare.com) is reached with these.
  ACCOUNT_ID: string;
  CF_TOKEN: string;

  // Pipeline provider keys — STT and TTS legs of the prototype pipeline.
  DEEPGRAM_API_KEY: string;
  ELEVENLABS_API_KEY: string;

  // Shared secret callers must present on /join + /leave so a stranger
  // can't make the bot join an arbitrary meeting. Pipeline callbacks on
  // /agentsInternal* are exempt (they originate from Cloudflare).
  AGENT_INVOKE_SECRET: string;
}
