import type { Env } from '../types';

const REALTIMEKIT_API_BASE = 'https://api.cloudflare.com/client/v4';

export interface RealtimeKitApp {
  accountId: string;
  appId: string;
  apiToken: string;
}

export interface RealtimeKitMeeting {
  id: string;
  title?: string | null;
}

export interface CreateRealtimeKitMeetingOptions {
  title?: string | null;
  sessionKeepAliveSeconds?: number;
}

export interface RealtimeKitParticipant {
  id: string;
  customParticipantId: string;
  displayName?: string | null;
  presetName: string;
  token: string;
}

export interface AddRealtimeKitParticipantOptions {
  customParticipantId: string;
  displayName?: string | null;
  presetName: string;
}

export interface BootstrapRealtimeKitGroupVoiceOptions {
  conversationId: string;
  humanUserId: string;
  humanDisplayName?: string | null;
  humanPresetName: string;
  bot?: {
    botId: string;
    displayName?: string | null;
    presetName: string;
  };
}

export interface BootstrapRealtimeKitGroupVoiceResult {
  meeting: RealtimeKitMeeting;
  human: RealtimeKitParticipant;
  bot?: RealtimeKitParticipant;
}

type Fetcher = (input: string, init?: RequestInit) => Promise<Response>;

interface RealtimeKitApiError {
  code?: string | number;
  message?: string;
}

interface RealtimeKitApiResponse<T> {
  success?: boolean;
  data?: T;
  error?: RealtimeKitApiError;
  errors?: RealtimeKitApiError[];
}

interface MeetingData {
  id?: string;
  title?: string | null;
}

interface ParticipantData {
  id?: string;
  custom_participant_id?: string;
  name?: string | null;
  preset_name?: string;
  token?: string;
}

export function realtimeKitAppFromEnv(env: Env): RealtimeKitApp | null {
  const accountId = env.REALTIMEKIT_ACCOUNT_ID ?? env.CF_ACCOUNT_ID;
  const appId = env.REALTIMEKIT_APP_ID;
  const apiToken = env.REALTIMEKIT_API_TOKEN;
  if (!accountId || !appId || !apiToken) return null;
  return { accountId, appId, apiToken };
}

function headers(app: RealtimeKitApp): Record<string, string> {
  return {
    Authorization: `Bearer ${app.apiToken}`,
    'Content-Type': 'application/json',
  };
}

function apiPath(app: RealtimeKitApp, path: string): string {
  return `${REALTIMEKIT_API_BASE}/accounts/${app.accountId}/realtime/kit/${app.appId}${path}`;
}

function formatApiError(json: RealtimeKitApiResponse<unknown>, status: number): string {
  const err = json.error ?? json.errors?.[0];
  const code = err?.code ?? status;
  const message = err?.message ?? '';
  return `${code}${message ? ` ${message}` : ''}`;
}

async function realtimeKitFetch<T>(
  app: RealtimeKitApp,
  method: 'POST',
  path: string,
  body: unknown,
  fetcher: Fetcher,
): Promise<T> {
  const resp = await fetcher(apiPath(app, path), {
    method,
    headers: headers(app),
    body: JSON.stringify(body),
  });

  let json: RealtimeKitApiResponse<T>;
  try {
    json = (await resp.json()) as RealtimeKitApiResponse<T>;
  } catch {
    throw new Error(`RealtimeKit ${method} ${path} failed: non-JSON response (${resp.status})`);
  }

  if (!resp.ok || json.success === false) {
    throw new Error(`RealtimeKit ${method} ${path} failed: ${formatApiError(json, resp.status)}`);
  }
  if (!json.data) {
    throw new Error(`RealtimeKit ${method} ${path} failed: missing data`);
  }
  return json.data;
}

export async function createRealtimeKitMeeting(
  app: RealtimeKitApp,
  opts: CreateRealtimeKitMeetingOptions,
  fetcher: Fetcher = fetch,
): Promise<RealtimeKitMeeting> {
  const data = await realtimeKitFetch<MeetingData>(
    app,
    'POST',
    '/meetings',
    {
      title: opts.title ?? null,
      persist_chat: false,
      record_on_start: false,
      live_stream_on_start: false,
      transcribe_on_end: false,
      summarize_on_end: false,
      session_keep_alive_time_in_secs: opts.sessionKeepAliveSeconds ?? 60,
    },
    fetcher,
  );
  if (!data.id) throw new Error('RealtimeKit POST /meetings failed: missing meeting id');
  return { id: data.id, title: data.title };
}

export async function addRealtimeKitParticipant(
  app: RealtimeKitApp,
  meetingId: string,
  opts: AddRealtimeKitParticipantOptions,
  fetcher: Fetcher = fetch,
): Promise<RealtimeKitParticipant> {
  const path = `/meetings/${meetingId}/participants`;
  const data = await realtimeKitFetch<ParticipantData>(
    app,
    'POST',
    path,
    {
      custom_participant_id: opts.customParticipantId,
      ...(opts.displayName != null ? { name: opts.displayName } : {}),
      preset_name: opts.presetName,
    },
    fetcher,
  );
  if (!data.id || !data.custom_participant_id || !data.preset_name || !data.token) {
    throw new Error(`RealtimeKit POST ${path} failed: missing participant token`);
  }
  return {
    id: data.id,
    customParticipantId: data.custom_participant_id,
    displayName: data.name,
    presetName: data.preset_name,
    token: data.token,
  };
}

export async function bootstrapRealtimeKitGroupVoice(
  app: RealtimeKitApp,
  opts: BootstrapRealtimeKitGroupVoiceOptions,
  fetcher: Fetcher = fetch,
): Promise<BootstrapRealtimeKitGroupVoiceResult> {
  const meeting = await createRealtimeKitMeeting(
    app,
    {
      title: `PendingBot group voice ${opts.conversationId}`,
      sessionKeepAliveSeconds: 60,
    },
    fetcher,
  );
  const human = await addRealtimeKitParticipant(
    app,
    meeting.id,
    {
      customParticipantId: `pendingbot:user:${opts.humanUserId}`,
      displayName: opts.humanDisplayName,
      presetName: opts.humanPresetName,
    },
    fetcher,
  );
  const bot = opts.bot
    ? await addRealtimeKitParticipant(
        app,
        meeting.id,
        {
          customParticipantId: `pendingbot:bot:${opts.bot.botId}`,
          displayName: opts.bot.displayName,
          presetName: opts.bot.presetName,
        },
        fetcher,
      )
    : undefined;

  return { meeting, human, ...(bot ? { bot } : {}) };
}
