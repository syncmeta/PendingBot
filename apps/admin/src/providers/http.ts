import { EDGE_API_URL } from '../env';
import { getAccessToken } from '../supabase';

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

// Single choke point for every edge call. Attaches the Supabase JWT, parses
// the typed error envelope, and throws EdgeApiError on non-2xx.
export async function edgeFetch<T = unknown>(opts: RequestOpts): Promise<T> {
  const token = await getAccessToken();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'X-Client-Platform': 'admin-console',
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = await fetch(buildUrl(opts.path, opts.query), {
    method: opts.method ?? 'GET',
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });

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
