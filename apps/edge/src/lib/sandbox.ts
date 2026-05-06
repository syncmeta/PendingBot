import type { Env } from '../types';

// Thin fetch wrapper around the Daytona REST API. We talk to two hosts:
//
//   app.daytona.io/api          — sandbox lifecycle (create, delete)
//   proxy.app.daytona.io/toolbox/{id}/...
//                               — code execution against a running sandbox
//
// Auth is a single bearer token (DAYTONA_API_KEY). Free-tier limits at the
// time of writing: 300 sandbox creations/min, 10k lifecycle ops/min, 10k
// general requests/min — comfortable headroom for a per-conversation
// sandbox model with idle cleanup.
//
// We do NOT use the official @daytonaio/sdk package because it pulls Node
// built-ins that aren't available on the Cloudflare Workers runtime. The
// REST surface we need is small enough that fetch is cleaner than wrestling
// with polyfills.

const DEFAULT_API_URL = 'https://app.daytona.io/api';
const DEFAULT_TOOLBOX_URL = 'https://proxy.app.daytona.io/toolbox';

// Sandbox creation defaults: 1 vCPU / 1 GiB RAM / 3 GiB disk Python image.
// Daytona's defaults already match this; we send `{}` and rely on it.
const CREATE_BODY = '{}';

// Common Python data-stack packages installed once per sandbox at first use.
// Kept tight so the bootstrap pip install doesn't burn too much wall time
// (each line below buys ~5–15s of cold pip on the first run; reused after).
const BOOTSTRAP_PACKAGES = [
  'numpy',
  'pandas',
  'matplotlib',
  'pillow',
  'requests',
  'httpx',
  'python-dateutil',
];

// Hard caps for code-run output. The chat agent loops on tool results, so
// huge stdout would balloon the prompt. 8 KiB of output per call is
// already plenty for any reasonable interactive task.
const RESULT_TRUNCATE_CHARS = 8000;

// Per-call execution timeout (ms passed to Daytona's process.code-run).
// 30s is enough for almost any pandas/numpy step and bounds runaway loops.
const CODE_RUN_TIMEOUT_MS = 30_000;

// pip-install timeout for the one-shot bootstrap. Generous because the
// first install on a cold sandbox can be slow.
const BOOTSTRAP_TIMEOUT_MS = 180_000;

export interface CodeRunResult {
  stdout: string;        // post-truncation; combined stdout+stderr per Daytona's stateless run
  exitCode: number;
  truncated: boolean;
}

/// Create a fresh sandbox. Caller persists the returned id (and bootstraps
/// it the first time it's used).
export async function createSandbox(env: Env): Promise<string> {
  const res = await daytonaFetch(env, 'mgmt', 'POST', '/sandbox', CREATE_BODY);
  const json = (await res.json()) as { id?: string };
  if (!json.id) throw new Error('daytona create: missing id in response');
  return json.id;
}

/// Run Python source in a sandbox. `code` goes through Daytona's stateless
/// code-run endpoint (`process/code-run`), which captures stdout+stderr
/// into a single `result` field and returns an `exitCode`.
export async function runPython(
  env: Env,
  sandboxId: string,
  code: string,
  opts: { timeoutMs?: number } = {},
): Promise<CodeRunResult> {
  const body = JSON.stringify({
    code,
    timeout: opts.timeoutMs ?? CODE_RUN_TIMEOUT_MS,
  });
  const res = await daytonaFetch(
    env,
    'toolbox',
    'POST',
    `/${sandboxId}/process/code-run`,
    body,
  );
  const json = (await res.json()) as { result?: string; exitCode?: number };
  const raw = json.result ?? '';
  const truncated = raw.length > RESULT_TRUNCATE_CHARS;
  return {
    stdout: truncated ? raw.slice(0, RESULT_TRUNCATE_CHARS) : raw,
    exitCode: json.exitCode ?? 0,
    truncated,
  };
}

/// One-shot pip install of the BOOTSTRAP_PACKAGES set. Called on first use
/// of a sandbox. Errors fall through to the caller — the caller decides
/// whether to mark `bootstrapped=true` based on success.
export async function bootstrapPython(env: Env, sandboxId: string): Promise<CodeRunResult> {
  // `pip install` runs as a shell command, not python code. Daytona's
  // toolbox exposes `process/execute` for shell, but `process/code-run`
  // only takes Python. We shell out via the Python `subprocess` module
  // so we keep using one endpoint shape.
  const code = [
    'import subprocess, sys',
    `pkgs = ${JSON.stringify(BOOTSTRAP_PACKAGES)}`,
    'r = subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", *pkgs], capture_output=True, text=True)',
    'print(r.stdout)',
    'if r.returncode != 0:',
    '    import sys',
    '    print(r.stderr, file=sys.stderr)',
    '    sys.exit(r.returncode)',
  ].join('\n');
  return runPython(env, sandboxId, code, { timeoutMs: BOOTSTRAP_TIMEOUT_MS });
}

/// Best-effort delete; cron sweep will clean up if this fails.
export async function deleteSandbox(env: Env, sandboxId: string): Promise<void> {
  try {
    await daytonaFetch(env, 'mgmt', 'DELETE', `/sandbox/${sandboxId}`);
  } catch (err) {
    console.warn('[sandbox] delete failed', sandboxId, err);
  }
}

// ── Internal ────────────────────────────────────────────────────────────────

type Host = 'mgmt' | 'toolbox';

async function daytonaFetch(
  env: Env,
  host: Host,
  method: 'GET' | 'POST' | 'DELETE',
  path: string,
  body?: string,
): Promise<Response> {
  const apiKey = env.DAYTONA_API_KEY;
  if (!apiKey) throw new Error('DAYTONA_API_KEY not configured');

  const base = host === 'mgmt'
    ? (env.DAYTONA_API_URL || DEFAULT_API_URL)
    : (env.DAYTONA_TOOLBOX_URL || DEFAULT_TOOLBOX_URL);
  const url = `${base}${path}`;

  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${apiKey}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`daytona ${method} ${path} failed: ${res.status} ${text.slice(0, 200)}`);
  }
  return res;
}
