// ── 边缘读投影授权门 ↔ Supabase RLS 对齐护栏 ─────────────────────────────
//
// 背景:RLS 是数据层的强制授权;消息/会话搬进 CF 投影 DO 后这层没了,
// 授权必须在 worker(apps/edge/src/routes/projections.ts + lib/conv-cache.ts)
// 显式重做。本文件守护一个隐式不变量,它此前没有任何自动化测试:
//
//   授权门放行的 (user, conversation) 集合  ⊆  RLS 允许集合。
//   门比 RLS 宽 = 越权读(重点防);窄 = 功能缺失。
//
// ── RLS 真源(最后生效定义,按 migrations 文件名字典序)──────────────────
// messages SELECT(messages_participant_read,20260520034417 重定义覆盖 0001):
//     is_participant(conversation_id)
//       AND coalesce(metadata->>'source','') <> 'voice_call_summary'
// messages SELECT(messages_temporary_group_read,20260524085639,OR 叠加):
//     can_view_temporary_group(conversation_id, auth.uid())
// conversations SELECT(conversations_participant_read,0001):
//     is_participant(id)
// conversations SELECT(conversations_temporary_group_view,20260524085639,OR 叠加):
//     conversation_type IN ('temporary_group','crew')
//       AND can_view_temporary_group(id, auth.uid())
//
// 其中:
//   is_participant(conv) := 存在 conversation_participants 行
//     (conversation_id=conv, participant_type='user', participant_id=auth.uid())
//   can_view_temporary_group(conv,u) := temporary_group_meta.status ∈
//     {active,closing,closed} 且 (subject_has_user_access(responsible_subject,u)
//     或 is_temporary_group_human_member(conv,u))
//
// ── 授权门语义(projections.ts /messages/tail)────────────────────────────
//   单 owner 类型(SINGLE_OWNER_TYPES):user_id === caller ? 放行 : 落 resolveConv
//   非单 owner(群 / crew / temporary_group / subagent / 未知):不本地放行,
//     走边缘 roster(is-member)或 resolveConv 带 user JWT 读 Supabase(RLS 权威)。
//   resolveConv 返回非空 = RLS 已放行 → authorized;返回 null → 403。
//
// ── 单 owner 本地放行为何 ⊆ RLS(核心安全论证)────────────────────────────
//   RLS messages/conversations SELECT 走 is_participant,即要求 caller 在
//   conversation_participants 有 participant_type='user' 行。所有单 owner 会话
//   创建 RPC(open_user_bot_conv / open_self_conv / bootstrap 等)都在建会话的
//   同一事务里把 owner 以 ('user', user_id, 'owner') 播种进 participants。因此
//   「user_id === caller」⟹ is_participant(caller) 为真 ⟹ 落入 RLS 允许集。
//   —— 只要多方类型不被误加进 SINGLE_OWNER_TYPES,本地放行永不越过 RLS。
//
// 这个测试不连真 DB:它把上面的 RLS 谓词与授权门判定各建成纯 TS 模型,对每类
// 会话形态构造 fixture,断言「门放行 ⟹ RLS 放行」。真 DB 端到端授权归
// tests/migrations-security.test.ts 与真机 QA;这里守的是逻辑不变量 + 文本漂移。

import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { SINGLE_OWNER_TYPES } from '../src/lib/conv-cache';

const repoRoot = join(import.meta.dirname, '..', '..', '..');
const migrationsDir = join(repoRoot, 'supabase/migrations');

// ── RLS 谓词的纯 TS 模型(镜像上面的真源)────────────────────────────────

interface Participant {
  participant_type: 'user' | 'bot';
  participant_id: string;
}

interface ConvFixture {
  id: string;
  conversation_type: string;
  user_id: string | null; // conversations.user_id(单 owner 的 owner)
  participants: Participant[]; // conversation_participants 行
  // temporary_group_meta(仅 temporary_group / crew 有)
  tempGroup?: {
    status: 'active' | 'closing' | 'closed' | 'pending';
    subjectMembers: string[]; // subject_has_user_access 为真的 user
    humanMembers: string[]; // is_temporary_group_human_member 为真的 user(active)
  };
}

/** RLS: is_participant(conv) —— caller 是否有 user participant 行。 */
function rlsIsParticipant(conv: ConvFixture, caller: string): boolean {
  return conv.participants.some(
    (p) => p.participant_type === 'user' && p.participant_id === caller,
  );
}

/** RLS: can_view_temporary_group(conv, caller)。 */
function rlsCanViewTempGroup(conv: ConvFixture, caller: string): boolean {
  const tg = conv.tempGroup;
  if (!tg) return false;
  if (!['active', 'closing', 'closed'].includes(tg.status)) return false;
  return tg.subjectMembers.includes(caller) || tg.humanMembers.includes(caller);
}

/** RLS messages SELECT 允许 caller 读该会话(participant OR temp-group 支路)。 */
function rlsCanReadMessages(conv: ConvFixture, caller: string): boolean {
  return rlsIsParticipant(conv, caller) || rlsCanViewTempGroup(conv, caller);
}

// ── 授权门判定的纯 TS 模型(镜像 projections.ts /messages/tail)────────────
// 关键点:单 owner 走本地 user_id 比对;其它类型不本地放行,交给 roster/RLS。
// resolveConv 的「群带 user JWT 读 Supabase」等价于 rlsCanReadMessages ——
// 所以模型里非单 owner 的最终放行 = RLS 结果(门此处不会比 RLS 宽)。

/** 门是否**本地(免 Supabase)**放行 —— 这是唯一可能宽于 RLS 的支路。 */
function gateLocalAuthorizes(conv: ConvFixture, caller: string): boolean {
  if (SINGLE_OWNER_TYPES.has(conv.conversation_type)) {
    return conv.user_id === caller;
  }
  // 非单 owner:门不本地放行(落 roster / resolveConv,权威 = RLS)。
  return false;
}

/** 门最终是否放行(含 resolveConv/roster 兜底,后者 == RLS)。 */
function gateAuthorizes(conv: ConvFixture, caller: string): boolean {
  if (gateLocalAuthorizes(conv, caller)) return true;
  // 兜底:群 roster ⊆ RLS 成员;resolveConv 带 user JWT 读 == RLS。
  return rlsCanReadMessages(conv, caller);
}

// ── Fixtures:按真实 conversation_type 枚举 + 关键攻击面 ───────────────────

const ME = 'user-me';
const OTHER = 'user-other';
const SUBJECT = 'user-subject-owner';

function fixtures(): ConvFixture[] {
  return [
    // 1:1 bot 会话 —— owner=ME,ME 是 participant。
    {
      id: 'c-user-bot',
      conversation_type: 'user_bot',
      user_id: ME,
      participants: [
        { participant_type: 'user', participant_id: ME },
        { participant_type: 'bot', participant_id: 'bot-1' },
      ],
    },
    // self 会话。
    {
      id: 'c-self',
      conversation_type: 'self',
      user_id: ME,
      participants: [{ participant_type: 'user', participant_id: ME }],
    },
    // 1:1 human(user_user)—— 双方都是 participant,user_id 是发起方 ME。
    {
      id: 'c-user-user',
      conversation_type: 'user_user',
      user_id: ME,
      participants: [
        { participant_type: 'user', participant_id: ME },
        { participant_type: 'user', participant_id: OTHER },
      ],
    },
    // 群会话 —— ME 是成员。非单 owner:门不本地放行,靠 roster/RLS。
    {
      id: 'c-group-member',
      conversation_type: 'group',
      user_id: null,
      participants: [
        { participant_type: 'user', participant_id: ME },
        { participant_type: 'user', participant_id: OTHER },
      ],
    },
    // 群会话 —— ME 非成员(被移除 / 从未加入)。门必须不放行。
    {
      id: 'c-group-nonmember',
      conversation_type: 'group',
      user_id: null,
      participants: [{ participant_type: 'user', participant_id: OTHER }],
    },
    // subagent 会话 —— 多方语义,ME 非 participant。门绝不本地放行。
    {
      id: 'c-subagent',
      conversation_type: 'subagent',
      user_id: ME, // 即便 DB 里 user_id 恰是 ME,类型非单 owner ⇒ 不本地放行
      participants: [{ participant_type: 'user', participant_id: OTHER }],
    },
    // crew 临时群 —— ME 通过 subject 授权可见,但不在 participants。
    {
      id: 'c-crew-subject',
      conversation_type: 'crew',
      user_id: null,
      participants: [],
      tempGroup: { status: 'active', subjectMembers: [ME], humanMembers: [] },
    },
    // temporary_group —— ME 是 human member。
    {
      id: 'c-temp-human',
      conversation_type: 'temporary_group',
      user_id: null,
      participants: [],
      tempGroup: { status: 'active', subjectMembers: [], humanMembers: [ME] },
    },
    // temporary_group —— ME 无任何可见资格(非 subject、非 human member)。
    {
      id: 'c-temp-outsider',
      conversation_type: 'temporary_group',
      user_id: SUBJECT, // 诱饵:user_id 存在但类型非单 owner
      participants: [],
      tempGroup: {
        status: 'active',
        subjectMembers: [SUBJECT],
        humanMembers: [OTHER],
      },
    },
    // temporary_group 已 pending(未激活)—— RLS can_view 为假。
    {
      id: 'c-temp-pending',
      conversation_type: 'temporary_group',
      user_id: null,
      participants: [],
      tempGroup: { status: 'pending', subjectMembers: [ME], humanMembers: [] },
    },
    // 未知/未来类型 —— 不在 SINGLE_OWNER_TYPES,门必须保守不本地放行。
    {
      id: 'c-unknown-type',
      conversation_type: 'future_unlisted_type',
      user_id: ME,
      participants: [{ participant_type: 'user', participant_id: OTHER }],
    },
  ];
}

const CALLERS = [ME, OTHER, SUBJECT, 'user-random'];

describe('projection read gate ⊆ Supabase RLS', () => {
  it('核心不变量:门放行的 (user, conv) 必落在 RLS 允许集(门绝不比 RLS 宽)', () => {
    for (const conv of fixtures()) {
      for (const caller of CALLERS) {
        if (gateAuthorizes(conv, caller)) {
          expect(
            rlsCanReadMessages(conv, caller),
            `越权读!门放行 caller=${caller} conv=${conv.id}(${conv.conversation_type}) 但 RLS 不允许`,
          ).toBe(true);
        }
      }
    }
  });

  it('单 owner 本地放行支路(唯一免-Supabase 面)独立收紧:仍 ⊆ RLS', () => {
    for (const conv of fixtures()) {
      for (const caller of CALLERS) {
        if (gateLocalAuthorizes(conv, caller)) {
          // 本地放行必是单 owner 类型
          expect(SINGLE_OWNER_TYPES.has(conv.conversation_type)).toBe(true);
          // 且 caller 必是 RLS participant(owner 建会话时已播种)
          expect(
            rlsIsParticipant(conv, caller),
            `本地放行越权!caller=${caller} conv=${conv.id} 非 RLS participant`,
          ).toBe(true);
        }
      }
    }
  });

  it('多方类型绝不出现在 SINGLE_OWNER_TYPES(误加即越权:owner 本地放行绕过成员判定)', () => {
    for (const multi of ['group', 'temporary_group', 'crew', 'subagent']) {
      expect(
        SINGLE_OWNER_TYPES.has(multi),
        `${multi} 是多方会话,一旦进 SINGLE_OWNER_TYPES,user_id===caller 会绕过 roster/RLS 成员判定 = 越权读`,
      ).toBe(false);
    }
  });

  it('conv-cache 与 projections.ts 共享同一 SINGLE_OWNER_TYPES(单源,防两处 Set 漂移)', async () => {
    // projections.ts 现在 import 的就是本常量;这里断言其确切成员集,
    // 任何一处改动都要显式改这个断言,逼作者复核 RLS 对齐。
    expect([...SINGLE_OWNER_TYPES].sort()).toEqual(
      ['discuss', 'portrait', 'self', 'surf', 'user_bot', 'user_user'].sort(),
    );
  });
});

// ── RLS policy 文本指纹(漂移警报)────────────────────────────────────────
// 迁移 append-only。这里按文件名字典序拼接「所有相关 CREATE POLICY / 定义
// 谓词的迁移文件全文」,归一化空白后 hash。任一相关 policy 文本一变 → hash 变
// → 测试红,失败信息提示:改了 RLS 请回 projections.ts 核对授权门再更新指纹。
//
// 取「最后生效」= 收集所有触及目标 policy 名的迁移(按序),而非只取最初定义,
// 这样后续 DROP+CREATE 重定义也会纳入指纹。谨慎选文件而非全目录 hash,避免
// 无关迁移(新加一张表)造成误报连连的脆测试。

const RLS_POLICY_MIGRATIONS = [
  // messages_participant_read / conversations_participant_read / is_participant 初定义
  '0001_init.sql',
  // messages_participant_read 重定义(叠加 voice_call_summary 隐藏)
  '20260520034417_hide_voice_summary_from_user_select.sql',
  // messages_temporary_group_read / conversations_temporary_group_view / can_view_temporary_group
  '20260524085639_temporary_groups_crew_schema.sql',
];

/** 从一个迁移里抽出与「读投影授权门对齐」相关的 SQL 片段(policy + 谓词函数)。 */
function extractRelevantSql(sql: string): string {
  const wanted =
    /(create\s+policy\s+(messages_participant_read|messages_temporary_group_read|conversations_participant_read|conversations_temporary_group_view)\b[\s\S]*?;)|(create\s+(or\s+replace\s+)?function\s+pendingbot\.(is_participant|can_view_temporary_group|is_temporary_group_human_member)\s*\([\s\S]*?\$\$;)/gi;
  const hits = sql.match(wanted) ?? [];
  return hits.join('\n');
}

/** 归一化:小写 + 折叠空白(注释/缩进重排不算「语义变更」,谓词才算)。 */
function normalize(s: string): string {
  return s
    .replace(/--[^\n]*/g, ' ') // 行注释
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

describe('RLS policy 文本漂移警报', () => {
  it('相关 SELECT policy 谓词未变(变了请先核对 projections.ts 授权门再更新指纹)', () => {
    const fragments = RLS_POLICY_MIGRATIONS.map((f) =>
      extractRelevantSql(readFileSync(join(migrationsDir, f), 'utf8')),
    );
    // 每个迁移都应抽到内容(否则文件被改名/policy 被挪走 = 需要人来看)
    for (let i = 0; i < RLS_POLICY_MIGRATIONS.length; i++) {
      expect(
        fragments[i].length,
        `${RLS_POLICY_MIGRATIONS[i]} 里没抽到目标 policy/谓词 —— policy 可能被挪走或改名,请核对授权门`,
      ).toBeGreaterThan(0);
    }
    const fingerprint = createHash('sha256')
      .update(fragments.map(normalize).join('\n----\n'))
      .digest('hex');

    // 期望指纹。RLS 谓词有意变更时:核对 projections.ts + conv-cache.ts 的
    // 授权门是否仍 ⊆ 新 RLS,确认后把这里更新成新值(commit 里说清改了什么)。
    const EXPECTED =
      'a789ae64e1e4b0ae7ef1c49c81c8ab0400eac3da04022009a7180a05f085fd5a';
    expect(
      fingerprint,
      `RLS policy 文本变了(新指纹 ${fingerprint})。请:1) 核对 projections.ts/conv-cache.ts 授权门是否仍 ⊆ 新 RLS;2) 确认后更新本测试 EXPECTED 指纹。`,
    ).toBe(EXPECTED);
  });

  it('未有后续迁移重定义这四条 policy(有的话说明漏进了指纹集,需要补进 RLS_POLICY_MIGRATIONS)', () => {
    const all = readdirSync(migrationsDir)
      .filter((f) => f.endsWith('.sql'))
      .sort();
    const touching = all.filter((f) =>
      /create\s+policy\s+(messages_participant_read|messages_temporary_group_read|conversations_participant_read|conversations_temporary_group_view)\b/i.test(
        readFileSync(join(migrationsDir, f), 'utf8'),
      ),
    );
    // 触及这四条 policy 的迁移集必须恰好等于我们纳入指纹的集合。
    expect(touching).toEqual(
      RLS_POLICY_MIGRATIONS.filter((f) => touching.includes(f)),
    );
    // 反向:touching 里不该有 RLS_POLICY_MIGRATIONS 之外的文件。
    for (const f of touching) {
      expect(
        RLS_POLICY_MIGRATIONS,
        `新迁移 ${f} 重定义了目标 policy 但没纳入指纹集 —— 请核对授权门并把它加进 RLS_POLICY_MIGRATIONS`,
      ).toContain(f);
    }
  });
});
