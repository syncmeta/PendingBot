// Centralised env access for the board SPA.
//
// The board is served SAME-ORIGIN with the edge API: the SPA is bundled into
// the edge worker's static assets and served under bot.pendingname.com/board,
// so the edge base is simply the page's own origin. No build-time config is
// required in prod, and the Cloudflare Access cookie rides along same-origin.
//
// `VITE_EDGE_API_URL` is an OPTIONAL override for local dev, where the Vite dev
// server (:5174) and the edge worker run on different origins. Vite inlines it
// at build time when present; when absent we fall back to same-origin.
//
// History: this var used to be *required* at build time and threw on module
// load when missing. Because the prod build (apps/edge `run deploy`) carries no
// `.env`, every deploy inlined `undefined` and shipped a board that white-
// screened before React mounted. The var is redundant in prod given same-
// origin, so defaulting to `window.location.origin` removes that failure mode.

const sameOrigin = typeof window !== 'undefined' ? window.location.origin : '';

// Edge base, no trailing slash. All routes are <EDGE_API_URL>/v1/*.
export const EDGE_API_URL = (import.meta.env.VITE_EDGE_API_URL ?? sameOrigin).replace(/\/+$/, '');
