import { PendingBotVoiceAgent } from "./agent";
import type { Env } from "./env";

export { PendingBotVoiceAgent };

// Worker entry for the group-voice prototype.
//
//   POST /join?meetingId=<id>   Authorization: Bearer <meeting-auth-token>
//                               X-Agent-Secret: <AGENT_INVOKE_SECRET>
//     -> bot joins the RealtimeKit meeting
//
//   POST /leave?meetingId=<id>  X-Agent-Secret: <AGENT_INVOKE_SECRET>
//     -> bot leaves and the pipeline is torn down
//
// /agentsInternal* is the Cloudflare pipeline callback path and is
// forwarded straight to the Durable Object.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const meetingId = url.searchParams.get("meetingId");
    if (!meetingId) {
      return new Response("missing meetingId", { status: 400 });
    }

    const stub = env.VOICE_AGENT.get(env.VOICE_AGENT.idFromName(meetingId));

    if (url.pathname.startsWith("/agentsInternal")) {
      return stub.fetch(request);
    }

    if (request.headers.get("X-Agent-Secret") !== env.AGENT_INVOKE_SECRET) {
      return new Response("forbidden", { status: 403 });
    }

    switch (url.pathname) {
      case "/join": {
        const authHeader = request.headers.get("Authorization") ?? "";
        const authToken = authHeader.startsWith("Bearer ")
          ? authHeader.slice("Bearer ".length)
          : null;
        if (!authToken) {
          return new Response("missing meeting auth token", { status: 401 });
        }
        await stub.init(
          meetingId,
          meetingId,
          authToken,
          url.host,
          env.ACCOUNT_ID,
          env.CF_TOKEN,
        );
        return Response.json({ ok: true, meetingId });
      }
      case "/leave": {
        await stub.deinit();
        return Response.json({ ok: true, meetingId });
      }
    }

    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
