import { Hono } from 'hono';
import { z } from 'zod';
import { requireSession } from '@pendingbot/identity';
import { serviceClient, userClient } from '../lib/supabase';
import { UUID_RE } from '../lib/ids';
import { jsonError } from '../lib/http-error';
import type { AppBindings, Env } from '../types';

const DEFAULT_SEARCH_LIMIT = 50;
const MAX_SEARCH_LIMIT = 200;
const DEFAULT_CONTEXT_SIDE = 50;
const MAX_CONTEXT_SIDE = 100;

const ISODate = z.string().datetime({ offset: true });

export type MessageSearchCursor = {
  createdAt: string;
  messageId: string;
};

export type MessageSearchDbRow = {
  conversation_id: string;
  conversation_title: string;
  conversation_type: string;
  message_id: string;
  message_seq: number;
  text: string;
  sender_name: string;
  sender_id: string | null;
  created_at: string;
  attachment_metadata: unknown[] | null;
  matched_fields: string[];
};

export type MessageSearchStore = {
  authorizeConversation(
    env: Env,
    input: { userJwt: string; conversationId: string },
  ): Promise<boolean>;
  search(
    env: Env,
    input: {
      userId: string;
      tokens: string[];
      conversationId: string | null;
      after: string | null;
      before: string | null;
      cursor: MessageSearchCursor | null;
      fetchLimit: number;
    },
  ): Promise<MessageSearchDbRow[]>;
  loadContext(
    env: Env,
    input: {
      userJwt: string;
      conversationId: string;
      aroundSeq: number;
      before: number;
      after: number;
    },
  ): Promise<Record<string, unknown>[] | null>;
};

/** Mirrors Foundation's case/diacritic/width folding for query tokens. */
export function normalizeMessageSearchValue(value: string): string {
  return value
    .normalize('NFKD')
    .replace(/\p{M}/gu, '')
    .toLocaleLowerCase('en-US');
}

/** JavaScript's Unicode-aware whitespace split matches Swift Character.isWhitespace. */
export function tokenizeMessageSearchQuery(query: string): string[] {
  return query
    .split(/\s+/u)
    .map(normalizeMessageSearchValue)
    .filter((token) => token.length > 0);
}

export function encodeMessageSearchCursor(cursor: MessageSearchCursor): string {
  return btoa(JSON.stringify(cursor))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

export function decodeMessageSearchCursor(raw: string): MessageSearchCursor {
  try {
    const base64 = raw.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, '=');
    const parsed = JSON.parse(atob(padded)) as Partial<MessageSearchCursor>;
    if (
      typeof parsed.createdAt !== 'string'
      || !ISODate.safeParse(parsed.createdAt).success
      || typeof parsed.messageId !== 'string'
      || !UUID_RE.test(parsed.messageId)
    ) {
      throw new Error('invalid cursor payload');
    }
    return { createdAt: parsed.createdAt, messageId: parsed.messageId };
  } catch {
    throw new Error('invalid cursor');
  }
}

function boundedInteger(raw: string | undefined, fallback: number, min: number, max: number): number {
  if (raw == null || raw === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(parsed)));
}

function optionalISO(raw: string | undefined): string | null | undefined {
  if (raw == null || raw === '') return null;
  return ISODate.safeParse(raw).success ? raw : undefined;
}

function visibleContextRows<T extends { metadata?: unknown; status?: unknown }>(rows: T[]): T[] {
  return rows.filter((row) => {
    if (row.status === 'deleted' || row.status === 'replaced') return false;
    const metadata = row.metadata;
    if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) return true;
    return (metadata as { source?: unknown }).source !== 'voice_call_summary';
  });
}

const CONTEXT_COLUMNS = 'id, client_message_id, conversation_id, user_id, sender_bot_id, role, log_kind, log_payload, attachments, content, status, created_at, message_seq, citations, metadata, parent_message_id, bubble_group_id, model_slug';

const defaultStore: MessageSearchStore = {
  async authorizeConversation(env, input) {
    const { data, error } = await userClient(env, input.userJwt)
      .from('conversations')
      .select('id')
      .eq('id', input.conversationId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data != null;
  },

  async search(env, input) {
    const { data, error } = await serviceClient(env).rpc('search_messages_for_user', {
      p_user_id: input.userId,
      p_tokens: input.tokens,
      p_conversation_id: input.conversationId,
      p_after: input.after,
      p_before: input.before,
      p_cursor_created_at: input.cursor?.createdAt ?? null,
      p_cursor_message_id: input.cursor?.messageId ?? null,
      p_limit: input.fetchLimit,
    });
    if (error) throw new Error(error.message);
    return (data ?? []) as MessageSearchDbRow[];
  },

  async loadContext(env, input) {
    const db = userClient(env, input.userJwt);
    const targetResult = await db
      .from('messages')
      .select(CONTEXT_COLUMNS)
      .eq('conversation_id', input.conversationId)
      .eq('message_seq', input.aroundSeq)
      .maybeSingle();
    if (targetResult.error) throw new Error(targetResult.error.message);
    if (!targetResult.data) return null;

    const beforePromise = input.before > 0
      ? db
          .from('messages')
          .select(CONTEXT_COLUMNS)
          .eq('conversation_id', input.conversationId)
          .lt('message_seq', input.aroundSeq)
          .order('message_seq', { ascending: false })
          .limit(input.before)
      : Promise.resolve({ data: [], error: null });
    const afterPromise = input.after > 0
      ? db
          .from('messages')
          .select(CONTEXT_COLUMNS)
          .eq('conversation_id', input.conversationId)
          .gt('message_seq', input.aroundSeq)
          .order('message_seq', { ascending: true })
          .limit(input.after)
      : Promise.resolve({ data: [], error: null });

    const [beforeResult, afterResult] = await Promise.all([beforePromise, afterPromise]);
    if (beforeResult.error) throw new Error(beforeResult.error.message);
    if (afterResult.error) throw new Error(afterResult.error.message);

    const beforeRows = visibleContextRows(beforeResult.data ?? []);
    const targetRows = visibleContextRows([targetResult.data]);
    const afterRows = visibleContextRows(afterResult.data ?? []);
    return [...beforeRows.reverse(), ...targetRows, ...afterRows];
  },
};

export function createMessageSearchRoutes(store: MessageSearchStore = defaultStore): Hono<AppBindings> {
  const routes = new Hono<AppBindings>();
  routes.use('*', requireSession());
  routes.get('/search', async (c) => {
    const query = c.req.query('query') ?? '';
    const tokens = tokenizeMessageSearchQuery(query);
    if (tokens.length === 0) {
      return jsonError(c, 400, 'invalid_query', { message: 'query is required' });
    }

    const scope = c.req.query('scope') ?? 'global';
    if (scope !== 'global' && scope !== 'current') {
      return jsonError(c, 400, 'invalid_query', { message: 'scope must be current or global' });
    }
    const rawConversationId = c.req.query('conversation_id');
    const conversationId = scope === 'current' ? rawConversationId ?? null : null;
    if (scope === 'current' && (!conversationId || !UUID_RE.test(conversationId))) {
      return jsonError(c, 400, 'invalid_query', { message: 'current scope requires conversation_id' });
    }

    const after = optionalISO(c.req.query('after'));
    const before = optionalISO(c.req.query('before'));
    if (after === undefined || before === undefined) {
      return jsonError(c, 400, 'invalid_query', { message: 'after and before must be ISO8601' });
    }
    if (after && before && Date.parse(after) > Date.parse(before)) {
      return jsonError(c, 400, 'invalid_query', { message: 'after must not be later than before' });
    }

    let cursor: MessageSearchCursor | null = null;
    const rawCursor = c.req.query('cursor');
    if (rawCursor) {
      try {
        cursor = decodeMessageSearchCursor(rawCursor);
      } catch {
        return jsonError(c, 400, 'invalid_query', { message: 'invalid cursor' });
      }
    }

    const limit = boundedInteger(c.req.query('limit'), DEFAULT_SEARCH_LIMIT, 1, MAX_SEARCH_LIMIT);
    const userId = c.var.userId!;
    const userJwt = c.var.userJwt!;

    try {
      if (conversationId) {
        const authorized = await store.authorizeConversation(c.env, { userJwt, conversationId });
        if (!authorized) {
          return jsonError(c, 403, 'forbidden', { message: '无权访问该会话' });
        }
      }

      const rows = await store.search(c.env, {
        userId,
        tokens,
        conversationId,
        after,
        before,
        cursor,
        fetchLimit: limit + 1,
      });
      const hasMore = rows.length > limit;
      const page = rows.slice(0, limit);
      const results = page.map((row) => ({
        conversationId: row.conversation_id,
        conversationTitle: row.conversation_title,
        conversationType: row.conversation_type,
        messageId: row.message_id,
        messageSeq: row.message_seq,
        text: row.text,
        senderName: row.sender_name,
        senderId: row.sender_id,
        createdAt: row.created_at,
        attachmentMetadata: row.attachment_metadata ?? [],
        matchedFields: row.matched_fields,
      }));
      const last = page.at(-1);
      const nextCursor = hasMore && last
        ? encodeMessageSearchCursor({ createdAt: last.created_at, messageId: last.message_id })
        : null;
      return c.json({ results, nextCursor });
    } catch (error) {
      return jsonError(c, 500, 'database_error', {
        detail: error instanceof Error ? error.message : String(error),
      });
    }
  });
  return routes;
}

export function createConversationMessageRoutes(
  store: MessageSearchStore = defaultStore,
): Hono<AppBindings> {
  const routes = new Hono<AppBindings>();
  routes.use('*', requireSession());
  routes.get('/:id/messages', async (c) => {
    const conversationId = c.req.param('id');
    if (!UUID_RE.test(conversationId)) {
      return jsonError(c, 400, 'invalid_query', { message: 'invalid conversation id' });
    }
    const rawAround = c.req.query('around_seq');
    const aroundSeq = Number(rawAround);
    if (!rawAround || !Number.isSafeInteger(aroundSeq) || aroundSeq < 1) {
      return jsonError(c, 400, 'invalid_query', { message: 'around_seq must be a positive integer' });
    }
    const before = boundedInteger(c.req.query('before'), DEFAULT_CONTEXT_SIDE, 0, MAX_CONTEXT_SIDE);
    const after = boundedInteger(c.req.query('after'), DEFAULT_CONTEXT_SIDE, 0, MAX_CONTEXT_SIDE);
    const userJwt = c.var.userJwt!;

    try {
      const authorized = await store.authorizeConversation(c.env, { userJwt, conversationId });
      if (!authorized) {
        return jsonError(c, 403, 'forbidden', { message: '无权访问该会话' });
      }
      const rows = await store.loadContext(c.env, {
        userJwt,
        conversationId,
        aroundSeq,
        before,
        after,
      });
      if (rows == null) {
        return jsonError(c, 404, 'not_found', { message: 'message not found' });
      }
      return c.json({ rows });
    } catch (error) {
      return jsonError(c, 500, 'database_error', {
        detail: error instanceof Error ? error.message : String(error),
      });
    }
  });
  return routes;
}

export const messageSearchRoutes = createMessageSearchRoutes();
export const conversationMessageRoutes = createConversationMessageRoutes();
