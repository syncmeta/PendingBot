// Cloudflare Realtime TURN — short-lived ICE relay credentials.
//
// Used by the 'webrtc_turn' voice transport: the middle fallback
// between direct iOS<->OpenAI WebRTC and the WebSocket relay. The iOS
// client still does the WebRTC SDP exchange with OpenAI, but routes its
// media through Cloudflare's TURN servers — which gets a call through
// NATs/firewalls that block a direct peer path.
//
// Credentials are minted per call (POST .../credentials/generate) and
// are valid for `ttlSeconds`; the 30-minute call cap means a single
// mint comfortably outlives any call.

import type { AppBindings } from '../types';

/** A WebRTC RTCIceServer entry as the iOS client consumes it. */
export interface TurnIceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/**
 * Mint Cloudflare TURN credentials. Returns null when the TURN key
 * isn't configured (TURN_KEY_ID / TURN_KEY_API_TOKEN unset) or the
 * Cloudflare API call fails — callers treat null as "TURN unavailable".
 */
export async function generateTurnCredentials(
  env: AppBindings['Bindings'],
  ttlSeconds = 3600,
): Promise<TurnIceServer[] | null> {
  const keyId = env.TURN_KEY_ID;
  const token = env.TURN_KEY_API_TOKEN;
  if (!keyId || !token) return null;

  let resp: Response;
  try {
    resp = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ ttl: ttlSeconds }),
      },
    );
  } catch (err) {
    console.warn('[cf-turn] fetch failed', err);
    return null;
  }
  if (!resp.ok) {
    console.warn(
      '[cf-turn] non-2xx',
      resp.status,
      (await resp.text()).slice(0, 200),
    );
    return null;
  }

  // Cloudflare returns a single iceServers object: { urls, username,
  // credential }. Normalize urls to an array and wrap in a one-element
  // list so the wire shape is a plain RTCIceServer[].
  const data = (await resp.json()) as {
    iceServers?: {
      urls?: string[] | string;
      username?: string;
      credential?: string;
    };
  };
  const ice = data.iceServers;
  if (!ice || !ice.urls) {
    console.warn('[cf-turn] response missing iceServers.urls');
    return null;
  }
  const urls = Array.isArray(ice.urls) ? ice.urls : [ice.urls];
  return [{ urls, username: ice.username, credential: ice.credential }];
}
