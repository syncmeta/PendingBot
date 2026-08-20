// Pre-flight check for OpenAI Realtime voice calls.
//
// OpenAI publishes a positive list of supported countries at
// https://platform.openai.com/docs/supported-countries. Maintaining the
// inverse here as a small blocklist keeps the gate simple and lets us
// fail fast with a clear error message (and a link to that very page)
// before signing an ephemeral key the user could not redeem anyway.
//
// Cloudflare populates `request.cf.country` from the edge's GeoIP — it
// reflects the network the request reaches us from, not the device's
// SIM or app store region. A user on a CN VPN landing on CN-IP egress
// will be blocked here; same user on a non-CN exit node passes.
//
// Update procedure when OpenAI changes its supported-country list:
// open the URL above, sort manually, drop / add entries to BLOCKED. The
// canonical positive list is long (~150 entries) and changes rarely;
// keeping the short negative list inline beats parsing a remote file.

// ISO-3166-1 alpha-2 codes that are not in OpenAI's supported list as
// of 2026-05. Cloudflare also reports 'T1' for Tor exit nodes — block
// those too on the same code path. Empty / unknown country (cf.country
// is sometimes 'XX' for unrecognized IP ranges) is blocked: we'd rather
// reject a legitimate user who can retry on a stable network than mint
// a token that the upstream will reject mid-call.
const BLOCKED: ReadonlySet<string> = new Set([
  'CN', // China mainland
  'HK', // Hong Kong
  'MO', // Macao
  'RU', // Russia
  'BY', // Belarus
  'IR', // Iran
  'KP', // North Korea
  'CU', // Cuba
  'SY', // Syria
  'VE', // Venezuela
  'AF', // Afghanistan
  'MM', // Myanmar / Burma
  'T1', // Tor exit
  'XX', // Cloudflare's catch-all for unknown
]);

export interface RegionCheck {
  allowed: boolean;
  country: string | null;
}

/**
 * Decide whether the caller's edge country is allowed to start an
 * OpenAI Realtime session. Pass `request.cf?.country` (string | undefined)
 * as captured from the Cloudflare worker; we normalize to uppercase
 * ISO-3166-1 alpha-2 and consult the blocklist.
 *
 * Returns the normalized country alongside the decision so callers can
 * include it in the structured error body (helps user / support debug
 * "but I'm in Singapore" reports).
 */
export function checkOpenAIRegion(country: string | null | undefined): RegionCheck {
  if (!country) {
    return { allowed: false, country: null };
  }
  const upper = country.toUpperCase();
  return { allowed: !BLOCKED.has(upper), country: upper };
}

/**
 * The public URL we link users to so they can verify their region
 * against OpenAI's authoritative list. Exposed so route handlers and
 * tests share one source.
 */
export const OPENAI_SUPPORTED_URL =
  'https://platform.openai.com/docs/supported-countries';
