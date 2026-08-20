import { EDGE_API_URL } from '../env';

// Mirrors apps/edge/src/lib/http-error.ts wire shape:
//   { error: { code: string, message?: string, detail?: unknown } }
export type EdgeErrorBody = {
  error?: { code?: string; message?: string; detail?: unknown };
};

// Refine surfaces err.statusCode + err.message in notifications; we also keep
// the stable `code` so pages can branch on it.
export class EdgeApiError extends Error {
  statusCode: number;
  code: string;
  detail?: unknown;
  constructor(statusCode: number, code: string, message: string, detail?: unknown) {
    super(message);
    this.name = 'EdgeApiError';
    this.statusCode = statusCode;
    this.code = code;
    this.detail = detail;
  }
}

type RequestOpts = {
  method?: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE';
  // path is relative to <EDGE>/v1/, e.g. 'admin/users' or 'permission-requests/abc/decide'
  path: string;
  query?: Record<string, string | number | undefined>;
  body?: unknown;
};

function buildUrl(path: string, query?: RequestOpts['query']): string {
  const clean = path.replace(/^\/+/, '');
  const url = new URL(`${EDGE_API_URL}/v1/${clean}`);
  if (query) {
    for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
    }
  }
  return url.toString();
}

// Single choke point for every edge call. Auth is handled entirely by
// Cloudflare Access: the board is served same-origin under /board, so the
// CF_Authorization cookie rides along on every same-origin request and the
// edge injects/verifies the Access JWT. No Bearer token here.
//
// `credentials: 'include'` makes the cookie explicit (same-origin would send
// it by default, but being explicit survives any base-URL change). If the
// Access session has expired, the edge bounces the request to the Access
// login page; we detect that redirect and reload so the top-level nav
// re-authenticates.
export async function edgeFetch<T = unknown>(opts: RequestOpts): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'X-Client-Platform': 'admin-console',
  };

  const res = await fetch(buildUrl(opts.path, opts.query), {
    method: opts.method ?? 'GET',
    headers,
    credentials: 'include',
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });

  // Access session expired → request was redirected to the CF login page.
  // Reload the top-level document so Access re-challenges in the browser.
  if (res.redirected && /cloudflareaccess\.com/.test(res.url)) {
    window.location.reload();
    throw new EdgeApiError(401, 'access_expired', 'Access 会话已过期,正在重新登录');
  }

  const text = await res.text();
  let parsed: unknown = undefined;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }

  if (!res.ok) {
    const envelope = (parsed ?? {}) as EdgeErrorBody;
    const code = envelope.error?.code ?? 'http_error';
    const message =
      envelope.error?.message ??
      (typeof parsed === 'string' && parsed
        ? parsed
        : `${opts.method ?? 'GET'} ${opts.path} failed (${res.status})`);
    throw new EdgeApiError(res.status, code, message, envelope.error?.detail);
  }

  return parsed as T;
}
