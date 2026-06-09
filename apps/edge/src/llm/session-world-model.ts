// T4.2 — Crew session 世界观 system prompt 的渲染器(spec v2 §9.5)。
//
// 输入:session_id。从 DB 取 crew/captain/members/parents/children/shares
// /permission_mode,塞进 prompts/<locale>/session-world-model.md 的 {{var}}
// 槽,返回填好的字符串。
//
// 设计原则:
//   * 模板字符串严格走 prompt-loader → Langfuse Prompt Management override 链
//     (永远不要在 .ts 里内联 prompt 文本 —— 见 memory feedback_no_hardcoded_prompts)
//   * 缺数据时降级到清晰的占位文案(中文:「(暂无)」/英文:「(none yet)」),
//     绝不输出 "{{var}}" 字面值
//   * permission_mode 这个字段 DB 还没建(待 T4.3 加列),先用默认值
//     "automatic" 注入,T4.3 真接上 enum 后改这里的 fallback
//
// 用法:
//   const md = await renderSessionWorldModel(env, sessionId);
//   // 把 md 当作一条 'system' role 消息丢进 agent 的 system_prompt
//
// 不接 PendingCrew runner —— runner 接入(把 md 写入 Claude Code /
// Codex 的 system prompt 启动参数)留 T4.2 后续 / T4.1 P0(runner 侧)。

import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { ensurePromptOverridesLoaded, getPrompt } from './prompt-loader';
import type { Locale } from '../i18n/types';

export interface RenderOptions {
  /** Locale to use for the world-model template. Defaults to 'zh'. */
  locale?: Locale;
}

/**
 * Render the spec v2 §9.5 world-model prompt for a given crew session.
 *
 * Returns the filled markdown ready to be injected as a `system` role
 * message at the head of the agent's prompt. Returns `null` when the
 * session doesn't exist.
 */
export async function renderSessionWorldModel(
  env: Env,
  sessionId: string,
  options: RenderOptions = {},
): Promise<string | null> {
  const locale: Locale = options.locale ?? 'zh';
  const svc = serviceClient(env);
  await ensurePromptOverridesLoaded(env).catch(() => {
    // override load failure is non-fatal; we fall back to bundled.
  });

  // ── Session row ────────────────────────────────────────────────────
  const { data: session, error: sErr } = await svc
    .from('crew_sessions')
    .select(
      'id, crew_conversation_id, runner_kind, task_brief, assigned_to_member_id, status, responsible_subject_id',
    )
    .eq('id', sessionId)
    .maybeSingle();
  if (sErr) {
    throw new Error(`session lookup failed: ${sErr.message}`);
  }
  if (!session) return null;

  const crewId = session.crew_conversation_id;

  // ── Crew meta (title / captain / runtime / working_directory / lineage) ─
  const { data: meta, error: metaErr } = await svc
    .from('temporary_group_meta')
    .select(
      'conversation_id, title, captain_bot_id, runtime_location, working_directory, parent_temporary_group_id',
    )
    .eq('conversation_id', crewId)
    .maybeSingle();
  if (metaErr) {
    throw new Error(`crew meta lookup failed: ${metaErr.message}`);
  }

  // ── Members (humans + bots, surfaces "who's in this crew") ─────────
  const { data: members, error: mErr } = await svc
    .from('temporary_group_members')
    .select('id, member_kind, user_id, bot_id, display_name, role, status, represents_crew_id')
    .eq('conversation_id', crewId)
    .eq('status', 'active');
  if (mErr) {
    throw new Error(`crew members lookup failed: ${mErr.message}`);
  }

  // ── Parents + children (DAG context for spec §7) ──────────────────
  const { data: parentEdges } = await svc
    .from('crew_parent_links')
    .select('parent_crew_id, child_share_bps')
    .eq('child_crew_id', crewId);
  const { data: childEdges } = await svc
    .from('crew_parent_links')
    .select('child_crew_id, child_share_bps')
    .eq('parent_crew_id', crewId);

  const linkedCrewIds = Array.from(new Set([
    ...((parentEdges ?? []).map((e) => e.parent_crew_id)),
    ...((childEdges ?? []).map((e) => e.child_crew_id)),
  ]));
  const lineageMeta = new Map<string, { title: string; responsibleSubjectId: string }>();
  if (linkedCrewIds.length > 0) {
    const { data: rows } = await svc
      .from('temporary_group_meta')
      .select('conversation_id, title, responsible_subject_id')
      .in('conversation_id', linkedCrewIds);
    for (const row of rows ?? []) {
      // responsible_subject_id is nullable since the account-deletion
      // cascade SET-NULLs it when the responsible user deletes their
      // account (the temp group survives, disowned). Skip those — there's
      // no responsible subject to surface in the lineage context.
      if (!row.responsible_subject_id) continue;
      lineageMeta.set(row.conversation_id, {
        title: row.title ?? '(untitled crew)',
        responsibleSubjectId: row.responsible_subject_id,
      });
    }
  }

  // ── Responsibility shares + subject display info ─────────────────
  const { data: shareRows } = await svc
    .from('crew_responsibility_shares')
    .select('subject_id, share_bps, is_tiebreaker')
    .eq('crew_conversation_id', crewId);

  const subjectIds = new Set<string>();
  for (const r of shareRows ?? []) subjectIds.add(r.subject_id);
  for (const v of lineageMeta.values()) subjectIds.add(v.responsibleSubjectId);
  const subjectsArr = Array.from(subjectIds);
  const subjectName = new Map<string, string>();
  if (subjectsArr.length > 0) {
    const { data: subjs } = await svc
      .from('subjects')
      .select('id, display_name')
      .in('id', subjectsArr);
    for (const s of subjs ?? []) subjectName.set(s.id, s.display_name);
  }

  // ── Captain bot display name ──────────────────────────────────────
  let captainName: string | null = null;
  if (meta?.captain_bot_id) {
    const { data: bot } = await svc
      .from('bots')
      .select('id, display_name')
      .eq('id', meta.captain_bot_id)
      .maybeSingle();
    captainName = bot?.display_name ?? null;
  }

  // ── Build the substitution table ──────────────────────────────────
  const isZh = locale === 'zh';
  const placeholderNone = isZh ? '(暂无)' : '(none yet)';

  const humanRoster = (() => {
    const rows = (members ?? []).filter((m) => m.member_kind === 'human');
    if (rows.length === 0) return placeholderNone;
    return rows
      .map((m) => {
        const name = m.display_name || (isZh ? '(无名)' : '(unnamed)');
        const role = m.role ?? 'member';
        const uid = m.user_id ?? '?';
        return `- **${name}** — role: ${role}, user_id: \`${uid}\``;
      })
      .join('\n');
  })();

  const captainBlock = (() => {
    if (!meta?.captain_bot_id) {
      return isZh
        ? '本 crew 暂无指定 captain。'
        : 'No captain has been assigned to this crew yet.';
    }
    const name = captainName ?? (isZh ? '(未命名)' : '(unnamed)');
    return isZh
      ? `Captain bot: **${name}** (bot_id: \`${meta.captain_bot_id}\`)`
      : `Captain bot: **${name}** (bot_id: \`${meta.captain_bot_id}\`)`;
  })();

  const lineageBlock = (() => {
    const parents = (parentEdges ?? []).map((e) => {
      const info = lineageMeta.get(e.parent_crew_id);
      const subjId = info?.responsibleSubjectId;
      const subj = subjId ? subjectName.get(subjId) ?? subjId : '?';
      return isZh
        ? `- 父 crew: **${info?.title ?? '?'}** (\`${e.parent_crew_id}\`) — 责任主体: ${subj},边权: 父占 ${10_000 - e.child_share_bps}bps / 子占 ${e.child_share_bps}bps`
        : `- Parent crew: **${info?.title ?? '?'}** (\`${e.parent_crew_id}\`) — responsible subject: ${subj}, parent share ${10_000 - e.child_share_bps}bps / child share ${e.child_share_bps}bps`;
    });
    const children = (childEdges ?? []).map((e) => {
      const info = lineageMeta.get(e.child_crew_id);
      const subjId = info?.responsibleSubjectId;
      const subj = subjId ? subjectName.get(subjId) ?? subjId : '?';
      return isZh
        ? `- 子 crew: **${info?.title ?? '?'}** (\`${e.child_crew_id}\`) — 责任主体: ${subj},边权: 子保留 ${e.child_share_bps}bps`
        : `- Child crew: **${info?.title ?? '?'}** (\`${e.child_crew_id}\`) — responsible subject: ${subj}, child share ${e.child_share_bps}bps`;
    });
    if (parents.length === 0 && children.length === 0) {
      return isZh
        ? '本 crew 没有父 / 子 crew —— 是一个独立的任务组。'
        : 'This crew has no parents or children — it stands alone.';
    }
    return [...parents, ...children].join('\n');
  })();

  const sharesBlock = (() => {
    const rows = shareRows ?? [];
    if (rows.length === 0) return placeholderNone;
    return rows
      .map((r) => {
        const name = subjectName.get(r.subject_id) ?? r.subject_id;
        const pct = (r.share_bps / 100).toFixed(2);
        const marker = r.is_tiebreaker ? (isZh ? ' ← 拍板方' : ' ← tiebreaker') : '';
        return `- **${name}**: ${pct}%${marker}`;
      })
      .join('\n');
  })();

  const tiebreakerBlock = (() => {
    const tb = (shareRows ?? []).find((r) => r.is_tiebreaker);
    if (!tb) {
      return isZh
        ? '暂无拍板方 —— 责任比例还没设定。'
        : 'No tiebreaker yet — responsibility shares are not configured.';
    }
    const name = subjectName.get(tb.subject_id) ?? tb.subject_id;
    return isZh
      ? `**${name}**(占 ${(tb.share_bps / 100).toFixed(2)}% 责任,标记为 tiebreaker)`
      : `**${name}** (holding ${(tb.share_bps / 100).toFixed(2)}% responsibility, marked as tiebreaker)`;
  })();

  // permission_mode: not yet in DB (T4.3). For now default to 'automatic',
  // matching spec v2 §10.2 ("crew-level default = 自动"). Once the column
  // lands, replace the default with the real value.
  const permissionMode = isZh ? '自动(automatic)' : 'automatic';

  const substitutions: Record<string, string> = {
    sessionId: session.id,
    sessionTaskBrief: session.task_brief || (isZh ? '(无任务描述)' : '(no task brief)'),
    runnerKind: session.runner_kind,
    crewId,
    crewTitle: meta?.title ?? (isZh ? '(未命名 crew)' : '(unnamed crew)'),
    runtimeLocation: meta?.runtime_location ?? 'local_host',
    workingDirectory: meta?.working_directory ?? (isZh ? '(未设置)' : '(unset)'),
    humanRoster,
    captainBlock,
    lineageBlock,
    sharesBlock,
    tiebreakerBlock,
    permissionMode,
  };

  // Pull the template via prompt-loader (Board override-aware).
  const template = getPrompt('session-world-model', locale);
  return applySubstitutions(template, substitutions);
}

function applySubstitutions(template: string, vars: Record<string, string>): string {
  let out = template;
  for (const [k, v] of Object.entries(vars)) {
    out = out.split(`{{${k}}}`).join(v);
  }
  return out;
}
