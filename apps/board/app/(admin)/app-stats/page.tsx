import { supabaseAdmin } from '@/lib/supabase/admin';
import { fmtDay, fmtNumber, fmtUsd } from '@/lib/format';
import { DailyAreaChart, type DailyPoint } from './daily-chart';

// Product-side health page — non-LLM stuff. Pulls from the existing
// pendingbot tables; everything is JS-aggregated since pre-launch
// volume is tiny. Move expensive aggregations into views/SQL fns
// when the page starts groaning.

const WINDOW_DAYS = 30;

function isoDayBound(daysAgo: number) {
  const now = new Date();
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  d.setUTCDate(d.getUTCDate() - daysAgo);
  return d.toISOString();
}

function emptyDays(n: number): DailyPoint[] {
  const out: DailyPoint[] = [];
  const now = new Date();
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
    d.setUTCDate(d.getUTCDate() - i);
    out.push({ day: fmtDay(d), value: 0 });
  }
  return out;
}

export default async function AppStatsPage() {
  const supa = supabaseAdmin();

  const since30 = isoDayBound(WINDOW_DAYS);
  const since7 = isoDayBound(7);
  const since1 = isoDayBound(1);

  // Run independent queries in parallel.
  const [
    totalUsersR,
    totalBotsR,
    totalMessagesR,
    msgs30R,
    newUsers30R,
    topBotsRawR,
    convFeaturesR,
    botSplitR,
    statusBreakR,
    regenerateR,
    surfRunsR,
    skillsR,
    skillSubsR,
    deletionSentimentR,
  ] = await Promise.all([
    supa.from('users').select('*', { count: 'exact', head: true }),
    supa.from('bots').select('*', { count: 'exact', head: true }),
    supa.from('messages').select('*', { count: 'exact', head: true }),
    // Pull (user_id, created_at, role) from messages in the 30d window.
    // For DAU and daily-message charts. Filter out logs to keep volume
    // honest.
    supa
      .from('messages')
      .select('user_id, sender_bot_id, role, created_at, replaces_message_id, status')
      .gte('created_at', since30)
      .neq('role', 'log'),
    supa.from('users').select('created_at').gte('created_at', since30),
    // Top bots: count bot replies in the 30d window. group-by happens
    // in JS after the pull.
    supa
      .from('messages')
      .select('sender_bot_id')
      .eq('role', 'bot')
      .gte('created_at', since30)
      .not('sender_bot_id', 'is', null),
    supa
      .from('conversations')
      .select('feature, conversation_type, round_count')
      .gte('created_at', since30),
    supa.from('bots').select('visibility'),
    supa.from('messages').select('status').gte('created_at', since30),
    // Regenerate signal: bot messages with replaces_message_id != null
    // mean the user clicked "重新生成" / asked again. Total bot msgs
    // for the same window is the denominator.
    supa
      .from('messages')
      .select('replaces_message_id', { count: 'exact', head: true })
      .eq('role', 'bot')
      .gte('created_at', since30)
      .not('replaces_message_id', 'is', null),
    // Envelope/来信: status + budget signals over the window.
    supa
      .from('envelope_runs')
      .select('status, cost_used_usd, cost_budget_usd, started_at, finished_at')
      .gte('created_at', since30)
      .returns<
        {
          status: string;
          cost_used_usd: number | string | null;
          cost_budget_usd: number | string | null;
          started_at: string | null;
          finished_at: string | null;
        }[]
      >(),
    // Skills: visibility split + total.
    supa.from('skills').select('id, visibility, frontmatter, forked_from'),
    // Skill subscriptions — counts per skill across all (user, conv) pairs.
    supa.from('skill_subscriptions').select('skill_id'),
    // Account-deletion sentiment — anonymous tally of which farewell
    // button users picked. No user_id stored, so the row outlives the
    // cascading account wipe by design.
    supa
      .from('account_deletion_log')
      .select('sentiment, deleted_at')
      .returns<{ sentiment: 'see_you_again' | 'farewell_forever'; deleted_at: string }[]>(),
  ]);

  const totalUsers = totalUsersR.count ?? 0;
  const totalBots = totalBotsR.count ?? 0;
  const totalMessages = totalMessagesR.count ?? 0;
  const msgs30 = msgs30R.data ?? [];

  // Active users windows. role='user' ensures we count real human
  // sends, not bot replies that happen to share user_id columns.
  const userMsgs = msgs30.filter((m) => m.role === 'user' && m.user_id);
  const dau24 = new Set(userMsgs.filter((m) => m.created_at >= since1).map((m) => m.user_id))
    .size;
  const wau = new Set(userMsgs.filter((m) => m.created_at >= since7).map((m) => m.user_id)).size;
  const mau = new Set(userMsgs.map((m) => m.user_id)).size;

  // Daily timelines for charts.
  const newUsersByDay = new Map<string, number>();
  for (const u of newUsers30R.data ?? []) {
    const d = fmtDay(u.created_at);
    newUsersByDay.set(d, (newUsersByDay.get(d) ?? 0) + 1);
  }
  const dailyDAU = new Map<string, Set<string>>();
  const dailyMsgs = new Map<string, number>();
  for (const m of userMsgs) {
    const d = fmtDay(m.created_at);
    if (!dailyDAU.has(d)) dailyDAU.set(d, new Set());
    if (m.user_id) dailyDAU.get(d)!.add(m.user_id);
    dailyMsgs.set(d, (dailyMsgs.get(d) ?? 0) + 1);
  }
  const newUsersTimeline = emptyDays(WINDOW_DAYS).map((p) => ({
    ...p,
    value: newUsersByDay.get(p.day) ?? 0,
  }));
  const dauTimeline = emptyDays(WINDOW_DAYS).map((p) => ({
    ...p,
    value: dailyDAU.get(p.day)?.size ?? 0,
  }));
  const msgTimeline = emptyDays(WINDOW_DAYS).map((p) => ({
    ...p,
    value: dailyMsgs.get(p.day) ?? 0,
  }));

  // Top bots.
  const botCounts = new Map<string, number>();
  for (const r of topBotsRawR.data ?? []) {
    if (!r.sender_bot_id) continue;
    botCounts.set(r.sender_bot_id, (botCounts.get(r.sender_bot_id) ?? 0) + 1);
  }
  const topBotIds = [...botCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([id]) => id);
  const { data: topBotRows } = topBotIds.length
    ? await supa
        .from('bots')
        .select('id, slug, display_name, visibility, model_id')
        .in('id', topBotIds)
    : { data: [] as { id: string; slug: string; display_name: string; visibility: string; model_id: string }[] };
  const topBotMap = new Map((topBotRows ?? []).map((b) => [b.id, b]));
  const topBots = topBotIds.map((id) => ({
    id,
    info: topBotMap.get(id),
    count: botCounts.get(id) ?? 0,
  }));

  // Conversation feature / type distribution (last 30d).
  const featureCounts = new Map<string, number>();
  const convTypeCounts = new Map<string, number>();
  let roundSum = 0;
  let roundN = 0;
  for (const c of convFeaturesR.data ?? []) {
    featureCounts.set(c.feature, (featureCounts.get(c.feature) ?? 0) + 1);
    convTypeCounts.set(c.conversation_type, (convTypeCounts.get(c.conversation_type) ?? 0) + 1);
    if (c.round_count != null) {
      roundSum += c.round_count;
      roundN++;
    }
  }
  const avgRounds = roundN > 0 ? roundSum / roundN : null;

  // Bot public/private.
  const botByVis = new Map<string, number>();
  for (const b of botSplitR.data ?? []) {
    botByVis.set(b.visibility, (botByVis.get(b.visibility) ?? 0) + 1);
  }

  // Message status distribution (signals user-perceived quality).
  const statusCounts = new Map<string, number>();
  for (const m of statusBreakR.data ?? []) {
    statusCounts.set(m.status, (statusCounts.get(m.status) ?? 0) + 1);
  }
  const totalMsgWindow = [...statusCounts.values()].reduce((a, b) => a + b, 0);

  const regenerateCount = regenerateR.count ?? 0;
  const totalBotMsgs = msgs30.filter((m) => m.role === 'bot').length;
  const regenRate = totalBotMsgs > 0 ? regenerateCount / totalBotMsgs : null;

  // ── Envelope/来信 runs ──────────────────────────────────────────
  const surf = surfRunsR.data ?? [];
  const surfStatusCounts = new Map<string, number>();
  let surfCostSum = 0;
  let surfBudgetHit = 0; // cost_used / cost_budget >= 0.9
  let surfDurSum = 0;
  let surfDurN = 0;
  for (const r of surf) {
    surfStatusCounts.set(r.status, (surfStatusCounts.get(r.status) ?? 0) + 1);
    const used = Number(r.cost_used_usd ?? 0);
    surfCostSum += used;
    if (r.cost_budget_usd && Number(r.cost_budget_usd) > 0) {
      const ratio = used / Number(r.cost_budget_usd);
      if (ratio >= 0.9) surfBudgetHit++;
    }
    if (r.started_at && r.finished_at) {
      surfDurSum += new Date(r.finished_at).getTime() - new Date(r.started_at).getTime();
      surfDurN++;
    }
  }
  const surfTotal = surf.length;
  const surfDoneCount = surfStatusCounts.get('done') ?? 0;
  const surfErrorCount = surfStatusCounts.get('error') ?? 0;
  const surfAvgDurMin = surfDurN > 0 ? surfDurSum / surfDurN / 60_000 : null;

  // ── Skills ─────────────────────────────────────────────────────
  const skills = skillsR.data ?? [];
  const skillSubs = skillSubsR.data ?? [];
  const skillSubCount = new Map<string, number>();
  for (const s of skillSubs) {
    skillSubCount.set(s.skill_id, (skillSubCount.get(s.skill_id) ?? 0) + 1);
  }
  const skillsByVisibility = new Map<string, number>();
  let forkedCount = 0;
  for (const s of skills) {
    skillsByVisibility.set(s.visibility, (skillsByVisibility.get(s.visibility) ?? 0) + 1);
    if (s.forked_from) forkedCount++;
  }
  const topSkills = skills
    .map((s) => ({
      id: s.id,
      name:
        ((s.frontmatter as Record<string, unknown> | null)?.name as string | undefined) ??
        s.id.slice(0, 8),
      visibility: s.visibility as string,
      subs: skillSubCount.get(s.id) ?? 0,
    }))
    .sort((a, b) => b.subs - a.subs)
    .slice(0, 10);

  // ── Account-deletion sentiment ─────────────────────────────────
  const deletionRows = deletionSentimentR.data ?? [];
  const deletionTotal = deletionRows.length;
  const deletion30 = deletionRows.filter((r) => r.deleted_at >= since30).length;
  const seeYouAgain = deletionRows.filter((r) => r.sentiment === 'see_you_again').length;
  const farewellForever = deletionRows.filter(
    (r) => r.sentiment === 'farewell_forever',
  ).length;

  return (
    <main className="container py-10 space-y-10">
      <header>
        <h1 className="text-2xl font-bold tracking-tight">App stats</h1>
        <p className="text-sm text-muted-foreground">
          产品级指标，最近 {WINDOW_DAYS} 天。
        </p>
      </header>

      <section className="grid gap-4 sm:grid-cols-3 lg:grid-cols-6">
        <Stat label="总用户" value={fmtNumber(totalUsers)} />
        <Stat label="总 bot" value={fmtNumber(totalBots)} />
        <Stat label="总消息" value={fmtNumber(totalMessages)} />
        <Stat label="DAU (24h)" value={fmtNumber(dau24)} accent />
        <Stat label="WAU (7d)" value={fmtNumber(wau)} />
        <Stat label="MAU (30d)" value={fmtNumber(mau)} />
      </section>

      <section className="grid gap-4 lg:grid-cols-3">
        <ChartCard title="每日新用户" data={newUsersTimeline} label="新用户" />
        <ChartCard title="每日活跃用户 (DAU)" data={dauTimeline} label="DAU" />
        <ChartCard title="每日消息量 (来自人)" data={msgTimeline} label="消息" />
      </section>

      <section className="grid gap-6 md:grid-cols-2">
        <Card title="Bot 排行榜（按回复数 30d）">
          <table className="w-full text-sm">
            <tbody>
              {topBots.map((b, i) => (
                <tr key={b.id} className="border-b last:border-0">
                  <td className="px-4 py-2 text-xs text-muted-foreground tabular-nums">
                    #{i + 1}
                  </td>
                  <td className="px-4 py-2">
                    <div>{b.info?.display_name ?? '(未知 bot)'}</div>
                    <div className="text-xs text-muted-foreground font-mono">
                      {b.info?.slug ?? b.id.slice(0, 8)}
                    </div>
                  </td>
                  <td className="px-4 py-2 text-right">
                    {b.info?.visibility === 'public' && (
                      <span className="rounded bg-blue-100 px-1.5 py-0.5 text-xs text-blue-700">
                        public
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums font-medium">
                    {fmtNumber(b.count)}
                  </td>
                </tr>
              ))}
              {topBots.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-4 py-8 text-center text-muted-foreground">
                    无数据
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </Card>

        <Card title="Bot 公私分布">
          <BarList
            entries={[...botByVis.entries()].sort((a, b) => b[1] - a[1])}
            total={[...botByVis.values()].reduce((a, b) => a + b, 0)}
          />
        </Card>
      </section>

      <section className="grid gap-6 md:grid-cols-2">
        <Card title={`对话 feature 分布（30d 创建）`}>
          <BarList
            entries={[...featureCounts.entries()].sort((a, b) => b[1] - a[1])}
            total={[...featureCounts.values()].reduce((a, b) => a + b, 0)}
            footer={
              avgRounds != null ? `平均每对话 ${avgRounds.toFixed(1)} 轮` : undefined
            }
          />
        </Card>
        <Card title={`对话 type 分布（30d 创建）`}>
          <BarList
            entries={[...convTypeCounts.entries()].sort((a, b) => b[1] - a[1])}
            total={[...convTypeCounts.values()].reduce((a, b) => a + b, 0)}
          />
        </Card>
      </section>

      <section className="grid gap-6 md:grid-cols-2">
        <Card title={`消息状态分布（30d）`}>
          <BarList
            entries={[...statusCounts.entries()].sort((a, b) => b[1] - a[1])}
            total={totalMsgWindow}
            highlight={(k) => (k === 'error' ? 'text-destructive' : undefined)}
          />
        </Card>
        <Card title="回答重新生成率（30d）">
          <div className="px-4 py-6">
            <div className="text-3xl font-bold tabular-nums">
              {regenRate == null ? '—' : `${(regenRate * 100).toFixed(1)}%`}
            </div>
            <p className="mt-2 text-sm text-muted-foreground">
              {fmtNumber(regenerateCount)} 条 bot 消息是被重新生成的，总共
              {fmtNumber(totalBotMsgs)} 条 bot 消息。
            </p>
            <p className="mt-2 text-xs text-muted-foreground">
              这是用户对回答不满意的代理指标——明显高于 5% 时，看看是不是某些 bot
              的 prompt / model 有问题。
            </p>
          </div>
        </Card>
      </section>

      <section className="grid gap-6 lg:grid-cols-3">
        <Card title={`奏折 runs（30d 创建）`}>
          <div className="px-4 py-3 space-y-2 text-sm">
            <Row label="总数" value={fmtNumber(surfTotal)} />
            <Row label="完成" value={fmtNumber(surfDoneCount)} />
            <Row
              label="出错"
              value={fmtNumber(surfErrorCount)}
              tone={surfErrorCount > 0 ? 'text-destructive' : undefined}
            />
            <Row label="累计花费" value={fmtUsd(surfCostSum)} />
            <Row
              label="预算用满 (≥90%)"
              value={fmtNumber(surfBudgetHit)}
              tone={surfBudgetHit > 0 ? 'text-amber-700' : undefined}
            />
            <Row
              label="平均运行时长"
              value={surfAvgDurMin == null ? '—' : `${surfAvgDurMin.toFixed(1)} 分钟`}
            />
          </div>
          {surfStatusCounts.size > 0 && (
            <div className="border-t">
              <BarList
                entries={[...surfStatusCounts.entries()].sort((a, b) => b[1] - a[1])}
                total={surfTotal}
                highlight={(k) => (k === 'error' ? 'text-destructive' : undefined)}
              />
            </div>
          )}
        </Card>

        <Card title="Skills">
          <div className="px-4 py-3 space-y-2 text-sm">
            <Row label="总 skill 数" value={fmtNumber(skills.length)} />
            <Row label="public" value={fmtNumber(skillsByVisibility.get('public') ?? 0)} />
            <Row label="private" value={fmtNumber(skillsByVisibility.get('private') ?? 0)} />
            <Row label="fork 自他人" value={fmtNumber(forkedCount)} />
            <Row label="总订阅数" value={fmtNumber(skillSubs.length)} />
          </div>
          {topSkills.length > 0 && (
            <div className="border-t">
              <h4 className="px-4 py-2 text-xs uppercase text-muted-foreground">
                Top by subscriptions
              </h4>
              <ul className="divide-y">
                {topSkills.map((s) => (
                  <li key={s.id} className="flex items-center justify-between px-4 py-1.5">
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-xs">{s.name}</span>
                      {s.visibility === 'public' && (
                        <span className="rounded bg-blue-100 px-1.5 py-0 text-xs text-blue-700">
                          public
                        </span>
                      )}
                    </div>
                    <span className="text-sm tabular-nums">{fmtNumber(s.subs)}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </Card>

        <Card title="注销账号告别情绪">
          <div className="px-4 py-3 space-y-2 text-sm">
            <Row label="累计注销" value={fmtNumber(deletionTotal)} />
            <Row label={`最近 ${WINDOW_DAYS} 天`} value={fmtNumber(deletion30)} />
          </div>
          {deletionTotal > 0 ? (
            <div className="border-t">
              <BarList
                entries={[
                  ['有缘再见 (see_you_again)', seeYouAgain],
                  ['再也不见 (farewell_forever)', farewellForever],
                ]}
                total={deletionTotal}
                highlight={(k) =>
                  k.startsWith('再也不见') ? 'text-destructive' : undefined
                }
              />
            </div>
          ) : (
            <p className="border-t px-4 py-6 text-sm text-muted-foreground">
              还没有人离开 🎉
            </p>
          )}
          <p className="border-t px-4 py-2 text-xs text-muted-foreground">
            两个按钮功能完全相同（都把账号彻底删干净），只为捕捉用户离开时的情绪。
            日志里没有 user_id / IP，行本身在级联删除中独立存活。
          </p>
        </Card>

      </section>
    </main>
  );
}

function Row({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: string;
}) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-muted-foreground">{label}</span>
      <span className={`tabular-nums ${tone ?? ''}`}>{value}</span>
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div
        className={
          accent ? 'mt-1 text-2xl font-bold tabular-nums' : 'mt-1 text-xl font-medium tabular-nums'
        }
      >
        {value}
      </div>
    </div>
  );
}

function ChartCard({
  title,
  data,
  label,
}: {
  title: string;
  data: DailyPoint[];
  label: string;
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <h3 className="text-sm font-medium">{title}</h3>
      <div className="mt-2">
        <DailyAreaChart data={data} label={label} />
      </div>
    </div>
  );
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border bg-card">
      <h3 className="border-b px-4 py-2 text-sm font-medium">{title}</h3>
      <div>{children}</div>
    </div>
  );
}

function BarList({
  entries,
  total,
  footer,
  highlight,
}: {
  entries: [string, number][];
  total: number;
  footer?: string;
  highlight?: (key: string) => string | undefined;
}) {
  if (entries.length === 0) {
    return <p className="px-4 py-6 text-sm text-muted-foreground">无数据</p>;
  }
  return (
    <>
      <ul className="divide-y">
        {entries.map(([k, v]) => {
          const pct = total > 0 ? v / total : 0;
          const tone = highlight?.(k);
          return (
            <li key={k} className="flex items-center gap-3 px-4 py-2">
              <span className={`flex-1 font-mono text-sm ${tone ?? ''}`}>{k}</span>
              <span className="w-32">
                <span
                  className="block h-2 rounded bg-primary/40"
                  style={{ width: `${Math.max(2, pct * 100)}%` }}
                />
              </span>
              <span className="w-20 text-right text-sm tabular-nums">{fmtNumber(v)}</span>
              <span className="w-12 text-right text-xs text-muted-foreground tabular-nums">
                {(pct * 100).toFixed(0)}%
              </span>
            </li>
          );
        })}
      </ul>
      {footer && (
        <p className="border-t px-4 py-2 text-xs text-muted-foreground">{footer}</p>
      )}
    </>
  );
}
