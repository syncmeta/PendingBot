import {
  DeepgramSTT,
  ElevenLabsTTS,
  RealtimeAgent,
  RealtimeKitTransport,
  TextComponent,
} from "@cloudflare/realtime-agents";
import type { Env } from "./env";

// Prototype brain: a plain Workers AI model with no PendingBot persona,
// memory or tools. The point of this prototype is to de-risk the
// RealtimeKit unknowns — multi-participant audio and turn-taking — not to
// ship the final bot. Swapping this for the real PendingBot chat brain
// (persona + memory + billing) is deliberate follow-up work.
class PendingBotBrain extends TextComponent {
  constructor(private readonly env: Env) {
    super();
  }

  onTranscript(
    text: string,
    reply: (text: string | ReadableStream<Uint8Array>) => void,
  ): void {
    void this.respond(text, reply);
  }

  private async respond(
    text: string,
    reply: (text: string | ReadableStream<Uint8Array>) => void,
  ): Promise<void> {
    const prompt = text.trim();
    if (!prompt) return;
    try {
      const result = await this.env.AI.run("@cf/meta/llama-3.1-8b-instruct", {
        prompt,
      });
      const response = (result as { response?: string }).response;
      if (response) reply(response);
    } catch (err) {
      console.error("[voice-agent] brain failed", err);
    }
  }
}

export class PendingBotVoiceAgent extends RealtimeAgent<Env> {
  async init(
    agentId: string,
    meetingId: string,
    authToken: string,
    workerUrl: string,
    accountId: string,
    apiToken: string,
  ): Promise<void> {
    const rtk = new RealtimeKitTransport(meetingId, authToken);

    // RealtimeKitTransport defaults to a `preset_name: "*"` microphone
    // filter, so the agent receives every participant's audio — group
    // voice works without per-track wiring.
    await this.initPipeline(
      [
        rtk,
        new DeepgramSTT(this.env.DEEPGRAM_API_KEY),
        new PendingBotBrain(this.env),
        new ElevenLabsTTS(this.env.ELEVENLABS_API_KEY),
        rtk,
      ],
      agentId,
      workerUrl,
      accountId,
      apiToken,
    );

    await rtk.meeting.join();
  }

  async deinit(): Promise<void> {
    await this.deinitPipeline();
  }
}
