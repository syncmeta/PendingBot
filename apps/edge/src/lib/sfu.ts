// Client for the Cloudflare Realtime SFU API — specifically the
// WebSocket Media Transport Adapter, which bridges WebRTC tracks on the
// SFU to/from a plain WebSocket endpoint (the SFU does the Opus<->PCM
// transcoding). The group-voice bridge (RoomVoiceDO) uses it both ways:
//
//   Stream  (location "remote") — SFU streams a human's track out to us
//                                 as PCM; we mix it into the bot's ears.
//   Ingest  (location "local")  — we send the bot's PCM in; the SFU
//                                 makes a WebRTC track everyone hears.
//
// All calls authenticate with the SFU app secret as a bearer token.
// Docs: developers.cloudflare.com/realtime/sfu/media-transport-adapters/websocket-adapter/

const SFU_API_BASE = 'https://rtc.live.cloudflare.com/v1';

export interface SfuApp {
  appId: string;
  appSecret: string;
}

export interface StreamAdapterSpec {
  /** Existing SFU session that owns the track to stream out. */
  sessionId: string;
  /** Track on that session to stream out as PCM. */
  trackName: string;
  /** wss:// endpoint the SFU dials and pushes PCM frames to. */
  endpoint: string;
}

export interface IngestAdapterSpec {
  /** Name for the WebRTC track the SFU creates from the ingested PCM. */
  trackName: string;
  /** wss:// endpoint the SFU dials to pull PCM frames from. */
  endpoint: string;
}

export interface AdapterResult {
  adapterId: string;
  /** Ingest only — the session + track the SFU created for the new track. */
  sessionId?: string;
  trackName?: string;
}

// Response shape is inferred to mirror the request (`tracks: [...]`) — the
// docs publish the request and close bodies but not the create response
// verbatim. Parsing is defensive so a shape surprise throws cleanly.
interface AdapterTrackResponse {
  adapterId?: string;
  sessionId?: string;
  trackName?: string;
  errorCode?: string;
  errorDescription?: string;
}
interface AdapterApiResponse {
  tracks?: AdapterTrackResponse[];
  errorCode?: string;
  errorDescription?: string;
}

function authHeaders(app: SfuApp): Record<string, string> {
  return {
    Authorization: `Bearer ${app.appSecret}`,
    'Content-Type': 'application/json',
  };
}

async function postAdapter(app: SfuApp, body: unknown): Promise<AdapterResult> {
  const resp = await fetch(
    `${SFU_API_BASE}/apps/${app.appId}/adapters/websocket/new`,
    { method: 'POST', headers: authHeaders(app), body: JSON.stringify(body) },
  );
  let json: AdapterApiResponse;
  try {
    json = (await resp.json()) as AdapterApiResponse;
  } catch {
    throw new Error(`SFU adapter create: non-JSON response (${resp.status})`);
  }
  const track = json.tracks?.[0];
  if (!resp.ok || json.errorCode || track?.errorCode) {
    const code = json.errorCode ?? track?.errorCode ?? String(resp.status);
    const detail = json.errorDescription ?? track?.errorDescription ?? '';
    throw new Error(`SFU adapter create failed: ${code} ${detail}`);
  }
  if (!track?.adapterId) {
    throw new Error('SFU adapter create returned no adapterId');
  }
  return {
    adapterId: track.adapterId,
    sessionId: track.sessionId,
    trackName: track.trackName,
  };
}

/** Stream an existing SFU track out to our WebSocket endpoint as PCM. */
export function createStreamAdapter(
  app: SfuApp,
  spec: StreamAdapterSpec,
): Promise<AdapterResult> {
  return postAdapter(app, {
    tracks: [
      {
        location: 'remote',
        sessionId: spec.sessionId,
        trackName: spec.trackName,
        endpoint: spec.endpoint,
        outputCodec: 'pcm',
      },
    ],
  });
}

/** Ingest PCM from our WebSocket endpoint as a new WebRTC track. */
export function createIngestAdapter(
  app: SfuApp,
  spec: IngestAdapterSpec,
): Promise<AdapterResult> {
  return postAdapter(app, {
    tracks: [
      {
        location: 'local',
        trackName: spec.trackName,
        endpoint: spec.endpoint,
        inputCodec: 'pcm',
        mode: 'buffer',
      },
    ],
  });
}

/** Tear down an adapter instance by id. Best-effort — never throws. */
export async function closeAdapter(app: SfuApp, adapterId: string): Promise<void> {
  try {
    await fetch(`${SFU_API_BASE}/apps/${app.appId}/adapters/websocket/close`, {
      method: 'POST',
      headers: authHeaders(app),
      body: JSON.stringify({ tracks: [{ adapterId }] }),
    });
  } catch {
    // Adapter lifetimes are also bounded by the SFU's own session
    // timeout, so a failed close is not fatal — just log upstream.
  }
}

// =============================================================================
// SFU session / track API — the WebRTC peer side
// =============================================================================
//
// Distinct from the WebSocket-adapter API above: these endpoints manage
// real WebRTC sessions and tracks. The group-voice human-join path uses
// them to negotiate each human's RTCPeerConnection against the SFU on
// behalf of iOS (the worker is the "Backend Server" in the SFU docs'
// lifecycle diagram).
//
// Docs: developers.cloudflare.com/realtime/sfu/https-api/
// Schema: developers.cloudflare.com/realtime/static/realtime-api-2024-05-21.yaml

export interface SfuSessionDescription {
  type: 'offer' | 'answer';
  sdp: string;
}

// A track in a tracks/new request. `local` publishes a track the peer is
// sending (identified by its `mid` in the offer); `remote` subscribes to
// a track another session published (identified by sessionId+trackName).
export interface SfuTrackRequest {
  location: 'local' | 'remote';
  trackName?: string;
  mid?: string;
  sessionId?: string;
}

export interface SfuTrackResult {
  location?: 'local' | 'remote';
  trackName?: string;
  mid?: string;
  sessionId?: string;
  errorCode?: string;
  errorDescription?: string;
}

export interface NewTracksResult {
  sessionDescription?: SfuSessionDescription;
  // When true the peer must immediately answer the returned offer via
  // /renegotiate before the new tracks flow.
  requiresImmediateRenegotiation?: boolean;
  tracks: SfuTrackResult[];
}

interface SessionApiResponse {
  sessionId?: string;
  sessionDescription?: SfuSessionDescription;
  requiresImmediateRenegotiation?: boolean;
  tracks?: SfuTrackResult[];
  errorCode?: string;
  errorDescription?: string;
}

async function sfuFetch(
  app: SfuApp,
  method: 'POST' | 'PUT' | 'GET',
  path: string,
  body?: unknown,
): Promise<SessionApiResponse> {
  const resp = await fetch(`${SFU_API_BASE}/apps/${app.appId}${path}`, {
    method,
    headers: authHeaders(app),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json: SessionApiResponse;
  try {
    json = (await resp.json()) as SessionApiResponse;
  } catch {
    throw new Error(`SFU ${method} ${path}: non-JSON response (${resp.status})`);
  }
  if (!resp.ok || json.errorCode) {
    throw new Error(
      `SFU ${method} ${path} failed: ${json.errorCode ?? resp.status} ` +
        `${json.errorDescription ?? ''}`,
    );
  }
  return json;
}

/** Create a new SFU session. Returns the session id. */
export async function createSfuSession(app: SfuApp): Promise<string> {
  const json = await sfuFetch(app, 'POST', '/sessions/new');
  if (!json.sessionId) throw new Error('SFU session create returned no sessionId');
  return json.sessionId;
}

/**
 * Add tracks to a session. Pass the peer's SDP offer to publish local
 * tracks or subscribe to remote ones; the SFU replies with an answer (or
 * an offer when `requiresImmediateRenegotiation` is set).
 */
export async function newSfuTracks(
  app: SfuApp,
  sessionId: string,
  opts: {
    sessionDescription?: SfuSessionDescription;
    tracks: SfuTrackRequest[];
    autoDiscover?: boolean;
  },
): Promise<NewTracksResult> {
  const json = await sfuFetch(app, 'POST', `/sessions/${sessionId}/tracks/new`, {
    sessionDescription: opts.sessionDescription,
    tracks: opts.tracks,
    autoDiscover: opts.autoDiscover,
  });
  return {
    sessionDescription: json.sessionDescription,
    requiresImmediateRenegotiation: json.requiresImmediateRenegotiation,
    tracks: json.tracks ?? [],
  };
}

/** Answer the SFU's renegotiation offer (e.g. after new remote tracks). */
export async function renegotiateSfuSession(
  app: SfuApp,
  sessionId: string,
  sessionDescription: SfuSessionDescription,
): Promise<void> {
  await sfuFetch(app, 'PUT', `/sessions/${sessionId}/renegotiate`, {
    sessionDescription,
  });
}

/** Close tracks on a session by their `mid`. Best-effort — never throws. */
export async function closeSfuTracks(
  app: SfuApp,
  sessionId: string,
  mids: string[],
): Promise<void> {
  try {
    await sfuFetch(app, 'PUT', `/sessions/${sessionId}/tracks/close`, {
      tracks: mids.map((mid) => ({ mid })),
      force: true,
    });
  } catch {
    // Session timeout reclaims tracks anyway — a failed close is not fatal.
  }
}
