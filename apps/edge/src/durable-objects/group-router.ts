import { runGroupRouter } from '../llm/group-router';
import { dispatchGroupTurn } from '../lib/group-dispatch';
import { serviceClient } from '../lib/supabase';
import type { Env } from '../types';

// One DO instance per group conversation. Single-writer in / single-
// alarm out lets us:
//
//   1. Track a sliding 60s window of recent message timestamps
//      (lightweight: just numbers, no message bodies).
//   2. Decide per arrival whether to fire the small-model router
//      immediately (sparse traffic) or schedule it for "8s after
//      the next quiet moment" (busy traffic, ≥10 msgs/min).
//   3. Run the router itself in alarm() — naturally serialized so
//      the same group can never have two router calls racing.
//
// The DO has no permanent state beyond what fits in storage: we keep
// `recentMessages` (a number[] of ms timestamps), `alarmAt` (unix ms
// of the pending alarm or null), and `lastRoutedAt` (cutoff for the
// next alarm's message pull). All values are <1KB combined; storage
// usage is well under the included quota at any reasonable scale.
//
// Why not Cloudflare Queues: queues are 1m batch granularity and have
// no per-key serialization; we'd need extra dedup logic for the same
// group's pending events. DO state + alarm() is exactly what we need.

const WINDOW_MS = 60_000;
const BUSY_THRESHOLD = 10;          // ≥10 msgs/min → debounce mode
const DEBOUNCE_MS = 8_000;          // wait this long after last msg
const MAX_ALARM_TTL_MS = 5 * 60_000; // upper bound to bound DO bills

export class GroupRouterDO {
  state: DurableObjectState;
  env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  // Single fetch endpoint. The caller (messages.ts group branch)
  // POSTs /signal with a JSON body { conversationId, messageId,
  // mentionedBotIds? }. mentionedBotIds bypasses the router entirely
  // and goes straight to dispatchGroupTurn — see M5.
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/signal' && request.method === 'POST') {
      const body = (await request.json()) as {
        conversationId: string;
        mentionedBotIds?: string[];
      };

      // Mention path — wake immediately, no debounce. Runs in
      // background so the caller's HTTP response isn't blocked.
      if (body.mentionedBotIds && body.mentionedBotIds.length > 0) {
        // Persist the conv id for any subsequent alarm() that runs.
        await this.state.storage.put('conversationId', body.conversationId);
        const botIds = body.mentionedBotIds;
        // Fire-and-forget; alarm() and signalNewMessage are decoupled
        // from this path. We don't need to await — DO will keep the
        // promise alive via the runtime.
        this.state.waitUntil(
          dispatchGroupTurn({
            env: this.env,
            conversationId: body.conversationId,
            wakeBotIds: botIds,
            reason: 'mention',
          }).catch((err) =>
            console.error('[GroupRouterDO] mention dispatch failed', err),
          ),
        );
        return Response.json({ ok: true, path: 'mention' });
      }

      // Default path — track + maybe schedule.
      await this.handleSignal(body.conversationId);
      return Response.json({ ok: true, path: 'tracked' });
    }

    if (url.pathname === '/resume' && request.method === 'POST') {
      // Continue-vote 'allowed' resumption: the user said "yes" so
      // dispatch the previously-pending bots NOW. Caller passes the
      // same wakeBotIds that were on the continue_request row.
      const body = (await request.json()) as {
        conversationId: string;
        wakeBotIds: string[];
      };
      this.state.waitUntil(
        dispatchGroupTurn({
          env: this.env,
          conversationId: body.conversationId,
          wakeBotIds: body.wakeBotIds,
          reason: 'continue_resume',
        }).catch((err) =>
          console.error('[GroupRouterDO] continue resume dispatch failed', err),
        ),
      );
      return Response.json({ ok: true, path: 'resume' });
    }

    return new Response('not found', { status: 404 });
  }

  // alarm() is the alarm-triggered router run. Called by the runtime
  // when our previously-scheduled `setAlarm()` fires.
  async alarm(): Promise<void> {
    const conversationId = (await this.state.storage.get<string>('conversationId')) ?? null;
    if (!conversationId) {
      // Lost the conv id (DO state truncated?) — bail.
      await this.clearAlarmState();
      return;
    }
    const lastRoutedAt = (await this.state.storage.get<number>('lastRoutedAt')) ?? 0;

    // Pull all messages newer than lastRoutedAt. Bound the read to a
    // sane window so a long-paused group doesn't pull thousands of rows
    // on first alarm.
    const supa = serviceClient(this.env);
    const since = new Date(Math.max(lastRoutedAt, Date.now() - 60 * 60_000)).toISOString();

    const { data: rawMsgs } = await supa
      .from('messages')
      .select('id, role, user_id, sender_bot_id, content, created_at')
      .eq('conversation_id', conversationId)
      .in('role', ['user', 'bot', 'human'])
      .gt('created_at', since)
      .order('created_at', { ascending: true })
      .limit(200);

    const msgs = (rawMsgs ?? []) as Array<{
      id: string;
      role: 'user' | 'bot' | 'human';
      user_id: string | null;
      sender_bot_id: string | null;
      content: string | null;
      created_at: string;
    }>;
    if (msgs.length === 0) {
      await this.clearAlarmState();
      return;
    }

    // Resolve sender labels (nicknames, falling back to display_name
    // for bots and short id for humans whose name we don't cache here).
    const senderLabels = await this.resolveSenderLabels(supa, conversationId, msgs);

    const recentMessages = msgs.map((m) => ({
      id: m.id,
      role: m.role,
      sender_label: senderLabels.get(`${m.role}:${m.user_id ?? m.sender_bot_id ?? ''}`) ?? '某人',
      content: m.content ?? '',
    }));

    const decision = await runGroupRouter({
      env: this.env,
      conversationId,
      recentMessages,
    });

    if (decision.wakeBots.length > 0) {
      this.state.waitUntil(
        dispatchGroupTurn({
          env: this.env,
          conversationId,
          wakeBotIds: decision.wakeBots,
          reason: 'router',
        }).catch((err) =>
          console.error('[GroupRouterDO] router dispatch failed', err),
        ),
      );
    }

    // Bump lastRoutedAt to now so the next alarm only sees newer msgs,
    // even if no bots were woken (the router decided no one was relevant
    // — that's still a valid "we processed this" signal).
    await this.state.storage.put('lastRoutedAt', Date.now());
    await this.clearAlarmState();
  }

  // ─────────────────────────────────────────────────────────────────
  // Internal helpers
  // ─────────────────────────────────────────────────────────────────

  private async handleSignal(conversationId: string): Promise<void> {
    await this.state.storage.put('conversationId', conversationId);

    const now = Date.now();
    const recent = (await this.state.storage.get<number[]>('recentMessages')) ?? [];
    const cutoff = now - WINDOW_MS;
    const trimmed = recent.filter((t) => t > cutoff);
    trimmed.push(now);
    await this.state.storage.put('recentMessages', trimmed);

    const alarmAt = await this.state.storage.get<number>('alarmAt');

    if (trimmed.length >= BUSY_THRESHOLD) {
      // Debounce mode: schedule alarm DEBOUNCE_MS after now (each new
      // message in the busy window pushes the alarm out, batching
      // them). Skip if we already have a later alarm.
      const targetAt = now + DEBOUNCE_MS;
      if (!alarmAt || alarmAt < now || alarmAt < targetAt - 500) {
        const ceiling = (await this.firstMessageInWindow()) + MAX_ALARM_TTL_MS;
        const finalAt = Math.min(targetAt, ceiling);
        await this.state.storage.setAlarm(finalAt);
        await this.state.storage.put('alarmAt', finalAt);
      }
    } else {
      // Sparse traffic — route immediately. Schedule a near-zero
      // alarm so the routing happens off the request path; this also
      // collapses bursts of 2-3 messages within the same tick.
      if (!alarmAt || alarmAt < now) {
        const at = now + 250;
        await this.state.storage.setAlarm(at);
        await this.state.storage.put('alarmAt', at);
      }
    }
  }

  private async firstMessageInWindow(): Promise<number> {
    const recent = (await this.state.storage.get<number[]>('recentMessages')) ?? [];
    return recent[0] ?? Date.now();
  }

  private async clearAlarmState(): Promise<void> {
    await this.state.storage.delete('alarmAt');
    // recentMessages can stay; the cutoff filter will trim them next
    // time anyway. Keeps state minimal.
  }

  private async resolveSenderLabels(
    supa: ReturnType<typeof serviceClient>,
    conversationId: string,
    msgs: Array<{ role: string; user_id: string | null; sender_bot_id: string | null }>,
  ): Promise<Map<string, string>> {
    const labels = new Map<string, string>();
    const userIds = new Set<string>();
    const botIds = new Set<string>();
    for (const m of msgs) {
      if (m.role === 'bot' && m.sender_bot_id) botIds.add(m.sender_bot_id);
      if ((m.role === 'user' || m.role === 'human') && m.user_id) userIds.add(m.user_id);
    }

    // Per-group nicknames + bot display_name fallbacks via one read.
    if (userIds.size > 0 || botIds.size > 0) {
      const { data: parts } = await supa
        .from('conversation_participants')
        .select('participant_type, participant_id, nickname')
        .eq('conversation_id', conversationId);
      const nicknameMap = new Map(
        (parts ?? []).map((p) => [
          `${p.participant_type}:${p.participant_id}`,
          p.nickname as string | null,
        ]),
      );

      if (botIds.size > 0) {
        const { data: bots } = await supa
          .from('bots')
          .select('id, display_name')
          .in('id', Array.from(botIds));
        for (const b of bots ?? []) {
          const nick = nicknameMap.get(`bot:${b.id}`);
          labels.set(`bot:${b.id}`, nick || (b.display_name as string));
        }
      }
      if (userIds.size > 0) {
        const { data: users } = await supa
          .from('users')
          .select('id, display_name')
          .in('id', Array.from(userIds));
        for (const u of users ?? []) {
          const nick = nicknameMap.get(`user:${u.id}`);
          labels.set(`user:${u.id}`, nick || (u.display_name as string) || '某人');
          // role can be 'human' too — point that key at the same label.
          labels.set(`human:${u.id}`, nick || (u.display_name as string) || '某人');
        }
      }
    }

    return labels;
  }
}
