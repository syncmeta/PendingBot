# Subject Foundation Implementation Plan

> **2026-05-28 修订 — spec v2 对齐补充**
>
> 本 plan 的 Task 1 已落地为 `supabase/migrations/20260524084417_subject_foundation.sql`。在 2026-05-28
> 出的 `docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md` §4.2 / §4.3
> 把群账号定位**显著调整**了,以下原 plan 与新 spec 矛盾或需要补丁的地方,列在文件最末
> 「## Spec v2 修订(2026-05-28)」一节。**实施新工作之前先读那一节**,本文上半部分保留作为
> 历史背景与已实施 Task 1 的 SQL 参考。
>
> 重点变化预告:
> - 群账号 = **轻量、可临时**(出门旅游建一个都行) — 不必先有 group conversation
> - `subjects` 表加 `kind` / `created_by`;`group_subject_members` 加 `granted_by` / `granted_at`
> - `bots` / `conversations` 加 `responsible_subject_id`(渐进 nullable 回填)
> - 权限矩阵简化为 α 版三级 role 固定权限(spec v2 §4.3 表格);**充值全员开放、无提现接口**
> - 新增 `grp_*` RPC 套件替代原 plan 散落的 helper

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立个人/群账号责任主体和 subject wallet 兼容层，为 Crew、临时群、runner lease、subject 计费打地基。

**Architecture:** 第一阶段只做 subject 地基，不创建 Crew、临时群或 runner。数据库新增 `subjects`、`subject_wallets`、`group_subject_members` 和 subject helper RPC；Edge 新增 subject billing helper 和 `/v1/me/subject` 只读接口。现有用户钱包路径继续可用，subject wallet 先镜像和兼容。

**Tech Stack:** Supabase/Postgres SQL migrations, RLS, Hono Edge routes, TypeScript, Vitest, Supabase generated types.

---

## 文件结构

- Create: `supabase/migrations/<timestamp>_subject_foundation.sql`
  - 新增 subject 表、subject 钱包、群 subject 成员、helper functions、用户 backfill、触发器、subject debit RPC。
- Modify: `apps/edge/src/lib/billing.ts`
  - 增加 subject balance/debit helper，不改变现有 `requireBalance` 和 `billingDebit` 行为。
- Modify: `apps/edge/src/lib/billing.test.ts`
  - 增加 subject helper 的 RPC 调用和错误吞掉测试。
- Modify: `apps/edge/src/routes/me.ts`
  - 增加 `/v1/me/subject`，让客户端能读当前个人 subject 和 subject wallet。
- Modify: `apps/edge/src/db/schema.ts`
  - 通过 `bun --filter='@pendingbot/edge' run types:db` 生成。
- Test: `apps/edge/src/lib/billing.test.ts`
  - 覆盖新增 TypeScript helper。

## Task 1: 新建 subject foundation migration

**Files:**
- Create: `supabase/migrations/<timestamp>_subject_foundation.sql`

- [ ] **Step 1: 生成 migration 文件**

Run:

```bash
supabase migration new subject_foundation
```

Expected: 生成 `supabase/migrations/<timestamp>_subject_foundation.sql`。

- [ ] **Step 2: 写入 migration SQL**

把生成文件内容替换为：

```sql
-- Subject foundation:
-- - user_account / group_account responsibility subjects;
-- - subject-scoped wallet compatibility layer;
-- - group subject membership controls;
-- - helper RPCs used by Edge and future Crew/temporary-group work.

BEGIN;

SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.subjects (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  subject_type text NOT NULL CHECK (subject_type IN ('user_account', 'group_account')),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  group_conversation_id uuid REFERENCES pendingbot.conversations(id) ON DELETE CASCADE,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subjects_user_kind_chk CHECK (
    (subject_type = 'user_account' AND user_id IS NOT NULL AND group_conversation_id IS NULL)
    OR
    (subject_type = 'group_account' AND user_id IS NULL AND group_conversation_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS subjects_user_account_uniq
  ON pendingbot.subjects(user_id)
  WHERE subject_type = 'user_account';

CREATE UNIQUE INDEX IF NOT EXISTS subjects_group_account_uniq
  ON pendingbot.subjects(group_conversation_id)
  WHERE subject_type = 'group_account';

CREATE TABLE IF NOT EXISTS pendingbot.subject_wallets (
  subject_id uuid PRIMARY KEY REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  balance_credits bigint NOT NULL DEFAULT 0,
  lifetime_topup_credits bigint NOT NULL DEFAULT 0,
  lifetime_spent_credits bigint NOT NULL DEFAULT 0,
  balance_updated_at timestamptz
);

CREATE TABLE IF NOT EXISTS pendingbot.group_subject_members (
  subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  can_manage_wallet boolean NOT NULL DEFAULT false,
  can_manage_runners boolean NOT NULL DEFAULT false,
  can_create_crew boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (subject_id, user_id)
);

CREATE INDEX IF NOT EXISTS group_subject_members_user_idx
  ON pendingbot.group_subject_members(user_id);

CREATE OR REPLACE FUNCTION pendingbot.subject_has_user_access(
  p_subject_id uuid,
  p_user_id uuid
) RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pendingbot, public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pendingbot.subjects s
     WHERE s.id = p_subject_id
       AND s.status = 'active'
       AND (
         (s.subject_type = 'user_account' AND s.user_id = p_user_id)
         OR EXISTS (
           SELECT 1
             FROM pendingbot.group_subject_members gsm
            WHERE gsm.subject_id = s.id
              AND gsm.user_id = p_user_id
         )
       )
  )
$$;

ALTER FUNCTION pendingbot.subject_has_user_access(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.subject_has_user_access(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.subject_has_user_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.subject_has_user_access(uuid, uuid) TO service_role;

ALTER TABLE pendingbot.subjects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subjects_self_read ON pendingbot.subjects;
CREATE POLICY subjects_self_read
  ON pendingbot.subjects FOR SELECT TO authenticated
  USING (
    (subject_type = 'user_account' AND user_id = auth.uid())
    OR pendingbot.subject_has_user_access(id, auth.uid())
  );

GRANT SELECT ON TABLE pendingbot.subjects TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.subjects TO service_role;

ALTER TABLE pendingbot.subject_wallets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subject_wallets_subject_read ON pendingbot.subject_wallets;
CREATE POLICY subject_wallets_subject_read
  ON pendingbot.subject_wallets FOR SELECT TO authenticated
  USING (pendingbot.subject_has_user_access(subject_id, auth.uid()));

GRANT SELECT ON TABLE pendingbot.subject_wallets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.subject_wallets TO service_role;

ALTER TABLE pendingbot.group_subject_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS group_subject_members_self_read ON pendingbot.group_subject_members;
CREATE POLICY group_subject_members_self_read
  ON pendingbot.group_subject_members FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS group_subject_members_admin_read ON pendingbot.group_subject_members;
CREATE POLICY group_subject_members_admin_read
  ON pendingbot.group_subject_members FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
        FROM pendingbot.group_subject_members mine
       WHERE mine.subject_id = group_subject_members.subject_id
         AND mine.user_id = auth.uid()
         AND mine.role IN ('owner', 'admin')
    )
  );

GRANT SELECT ON TABLE pendingbot.group_subject_members TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.group_subject_members TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.ensure_user_subject(
  p_user_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_subject_id uuid;
  v_display_name text;
  v_balance bigint;
  v_lifetime_topup bigint;
  v_lifetime_spent bigint;
  v_balance_updated_at timestamptz;
BEGIN
  SELECT
    COALESCE(NULLIF(display_name, ''), email, '你'),
    balance_credits,
    lifetime_topup_credits,
    lifetime_spent_credits,
    balance_updated_at
    INTO v_display_name, v_balance, v_lifetime_topup, v_lifetime_spent, v_balance_updated_at
    FROM pendingbot.users
   WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.subjects(subject_type, user_id, display_name)
  VALUES ('user_account', p_user_id, v_display_name)
  ON CONFLICT (user_id) WHERE subject_type = 'user_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  INSERT INTO pendingbot.subject_wallets(
    subject_id,
    balance_credits,
    lifetime_topup_credits,
    lifetime_spent_credits,
    balance_updated_at
  ) VALUES (
    v_subject_id,
    COALESCE(v_balance, 0),
    COALESCE(v_lifetime_topup, 0),
    COALESCE(v_lifetime_spent, 0),
    v_balance_updated_at
  )
  ON CONFLICT (subject_id) DO UPDATE SET
    balance_credits = EXCLUDED.balance_credits,
    lifetime_topup_credits = EXCLUDED.lifetime_topup_credits,
    lifetime_spent_credits = EXCLUDED.lifetime_spent_credits,
    balance_updated_at = EXCLUDED.balance_updated_at;

  RETURN v_subject_id;
END $$;

ALTER FUNCTION pendingbot.ensure_user_subject(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.ensure_user_subject(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.ensure_user_subject(uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.ensure_group_subject_for_conversation(
  p_conversation_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_subject_id uuid;
  v_title text;
  v_creator uuid;
BEGIN
  SELECT
    COALESCE(NULLIF(cgm.title, ''), NULLIF(c.title, ''), '群账号'),
    cgm.created_by
    INTO v_title, v_creator
    FROM pendingbot.conversations c
    LEFT JOIN pendingbot.conversation_group_meta cgm
      ON cgm.conversation_id = c.id
   WHERE c.id = p_conversation_id
     AND c.conversation_type = 'group';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group conversation not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO pendingbot.subjects(subject_type, group_conversation_id, display_name)
  VALUES ('group_account', p_conversation_id, v_title)
  ON CONFLICT (group_conversation_id) WHERE subject_type = 'group_account'
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    updated_at = now()
  RETURNING id INTO v_subject_id;

  INSERT INTO pendingbot.subject_wallets(subject_id)
  VALUES (v_subject_id)
  ON CONFLICT (subject_id) DO NOTHING;

  IF v_creator IS NOT NULL THEN
    INSERT INTO pendingbot.group_subject_members(
      subject_id,
      user_id,
      role,
      can_manage_wallet,
      can_manage_runners,
      can_create_crew
    ) VALUES (
      v_subject_id,
      v_creator,
      'owner',
      true,
      true,
      true
    )
    ON CONFLICT (subject_id, user_id) DO UPDATE SET
      role = CASE
        WHEN pendingbot.group_subject_members.role = 'owner' THEN 'owner'
        ELSE EXCLUDED.role
      END,
      can_manage_wallet = pendingbot.group_subject_members.can_manage_wallet OR EXCLUDED.can_manage_wallet,
      can_manage_runners = pendingbot.group_subject_members.can_manage_runners OR EXCLUDED.can_manage_runners,
      can_create_crew = pendingbot.group_subject_members.can_create_crew OR EXCLUDED.can_create_crew;
  END IF;

  RETURN v_subject_id;
END $$;

ALTER FUNCTION pendingbot.ensure_group_subject_for_conversation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.ensure_group_subject_for_conversation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.ensure_group_subject_for_conversation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.billing_debit_subject(
  p_subject_id uuid,
  p_audit_log_id uuid,
  p_credits bigint
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_new_balance bigint;
BEGIN
  IF p_credits <= 0 THEN
    UPDATE pendingbot.audit_log
       SET billing_status = 'skipped'
     WHERE id = p_audit_log_id;

    SELECT balance_credits INTO v_new_balance
      FROM pendingbot.subject_wallets
     WHERE subject_id = p_subject_id;

    RETURN v_new_balance;
  END IF;

  UPDATE pendingbot.subject_wallets
     SET balance_credits = balance_credits - p_credits,
         lifetime_spent_credits = lifetime_spent_credits + p_credits,
         balance_updated_at = now()
   WHERE subject_id = p_subject_id
  RETURNING balance_credits INTO v_new_balance;

  IF NOT FOUND THEN
    UPDATE pendingbot.audit_log
       SET billing_status = 'unbilled'
     WHERE id = p_audit_log_id;
    RETURN NULL;
  END IF;

  UPDATE pendingbot.audit_log
     SET billing_status = CASE WHEN v_new_balance < 0 THEN 'unbilled' ELSE 'billed' END
   WHERE id = p_audit_log_id;

  RETURN v_new_balance;
END $$;

ALTER FUNCTION pendingbot.billing_debit_subject(uuid, uuid, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.billing_debit_subject(uuid, uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.billing_debit_subject(uuid, uuid, bigint) TO service_role;

CREATE OR REPLACE FUNCTION pendingbot.tg_users_ensure_subject()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
BEGIN
  PERFORM pendingbot.ensure_user_subject(NEW.id);
  RETURN NEW;
END $$;

ALTER FUNCTION pendingbot.tg_users_ensure_subject() OWNER TO postgres;

DROP TRIGGER IF EXISTS users_ensure_subject_trg ON pendingbot.users;
CREATE TRIGGER users_ensure_subject_trg
AFTER INSERT OR UPDATE OF display_name, email, balance_credits, lifetime_topup_credits, lifetime_spent_credits, balance_updated_at
ON pendingbot.users
FOR EACH ROW
EXECUTE FUNCTION pendingbot.tg_users_ensure_subject();

INSERT INTO pendingbot.subjects(subject_type, user_id, display_name)
SELECT 'user_account', u.id, COALESCE(NULLIF(u.display_name, ''), u.email, '你')
  FROM pendingbot.users u
ON CONFLICT (user_id) WHERE subject_type = 'user_account'
DO UPDATE SET
  display_name = EXCLUDED.display_name,
  updated_at = now();

INSERT INTO pendingbot.subject_wallets(
  subject_id,
  balance_credits,
  lifetime_topup_credits,
  lifetime_spent_credits,
  balance_updated_at
)
SELECT
  s.id,
  u.balance_credits,
  u.lifetime_topup_credits,
  u.lifetime_spent_credits,
  u.balance_updated_at
  FROM pendingbot.subjects s
  JOIN pendingbot.users u
    ON u.id = s.user_id
 WHERE s.subject_type = 'user_account'
ON CONFLICT (subject_id) DO UPDATE SET
  balance_credits = EXCLUDED.balance_credits,
  lifetime_topup_credits = EXCLUDED.lifetime_topup_credits,
  lifetime_spent_credits = EXCLUDED.lifetime_spent_credits,
  balance_updated_at = EXCLUDED.balance_updated_at;

COMMIT;
```

- [ ] **Step 3: 检查 migration SQL 基本语法**

Run:

```bash
supabase migration list --local
```

Expected: 命令能列出本地 migrations；新 migration 文件名出现在列表或本地文件系统中。这里不要求 linked DB 已应用。

- [ ] **Step 4: 提交 migration**

```bash
git add supabase/migrations/<timestamp>_subject_foundation.sql
git commit -m "db: add subject foundation"
```

## Task 2: TypeScript billing helper

**Files:**
- Modify: `apps/edge/src/lib/billing.ts`
- Test: `apps/edge/src/lib/billing.test.ts`

- [ ] **Step 1: 写 failing tests**

在 `apps/edge/src/lib/billing.test.ts` 的 import 中加入：

```ts
  billingDebitSubject,
  getSubjectBalance,
```

在 `stubSupa` 的 `handlers` 类型里加入：

```ts
    subject_wallets: (
      subjectId: string,
    ) => { data: { balance_credits: number; lifetime_topup_credits?: number; lifetime_spent_credits?: number } | null };
```

在 `maybeSingle()` 中加入：

```ts
          if (table === 'subject_wallets' && handlers.subject_wallets) {
            return handlers.subject_wallets((this as { _eq?: string })._eq as string);
          }
```

在 `billing.test.ts` 末尾加入：

```ts
describe('subject billing helpers', () => {
  it('reads subject wallet balance', async () => {
    const supa = stubSupa({
      subject_wallets: () => ({
        data: {
          balance_credits: 1200,
          lifetime_topup_credits: 2000,
          lifetime_spent_credits: 800,
        },
      }),
    });
    await expect(getSubjectBalance(supa, 'subject-1')).resolves.toEqual({
      balance_credits: 1200,
      lifetime_topup_credits: 2000,
      lifetime_spent_credits: 800,
    });
  });

  it('returns null when subject wallet is missing', async () => {
    const supa = stubSupa({
      subject_wallets: () => ({ data: null }),
    });
    await expect(getSubjectBalance(supa, 'subject-1')).resolves.toBeNull();
  });

  it('calls billing_debit_subject RPC', async () => {
    const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
    const supa = stubSupa({
      rpc: (fn, args) => {
        calls.push({ fn, args });
        return { data: 900, error: null };
      },
    });
    await expect(billingDebitSubject(supa, 'subject-1', 'audit-1', 100)).resolves.toBe(900);
    expect(calls).toEqual([
      {
        fn: 'billing_debit_subject',
        args: {
          p_subject_id: 'subject-1',
          p_audit_log_id: 'audit-1',
          p_credits: 100,
        },
      },
    ]);
  });

  it('swallows billing_debit_subject RPC errors', async () => {
    const supa = stubSupa({
      rpc: () => ({ data: null, error: { message: 'boom' } }),
    });
    await expect(billingDebitSubject(supa, 'subject-1', 'audit-1', 100)).resolves.toBeNull();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run:

```bash
bun --filter='@pendingbot/edge' run test src/lib/billing.test.ts
```

Expected: FAIL，错误包含 `getSubjectBalance` 或 `billingDebitSubject` 未导出。

- [ ] **Step 3: 实现 helper**

在 `apps/edge/src/lib/billing.ts` 的 `BalanceInfo` 相关区域后加入：

```ts
export type SubjectBalanceInfo = BalanceInfo;

export async function getSubjectBalance(
  supa: SupabaseClient,
  subjectId: string,
): Promise<SubjectBalanceInfo | null> {
  const { data, error } = await supa
    .from('subject_wallets')
    .select('balance_credits, lifetime_topup_credits, lifetime_spent_credits')
    .eq('subject_id', subjectId)
    .maybeSingle();
  if (error || !data) return null;
  return {
    balance_credits: Number(data.balance_credits) || 0,
    lifetime_topup_credits: Number(data.lifetime_topup_credits) || 0,
    lifetime_spent_credits: Number(data.lifetime_spent_credits) || 0,
  };
}
```

在 `billingDebit` 后加入：

```ts
export async function billingDebitSubject(
  supa: SupabaseClient,
  subjectId: string,
  auditLogId: string,
  credits: number,
): Promise<number | null> {
  const { data, error } = await supa.rpc('billing_debit_subject', {
    p_subject_id: subjectId,
    p_audit_log_id: auditLogId,
    p_credits: credits,
  });
  if (error) {
    console.warn('[billing_debit_subject]', error.message ?? String(error));
    return null;
  }
  return typeof data === 'number' ? data : null;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:

```bash
bun --filter='@pendingbot/edge' run test src/lib/billing.test.ts
```

Expected: PASS。

- [ ] **Step 5: 提交 helper**

```bash
git add apps/edge/src/lib/billing.ts apps/edge/src/lib/billing.test.ts
git commit -m "edge: add subject billing helpers"
```

## Task 3: `/v1/me/subject` 只读接口

**Files:**
- Modify: `apps/edge/src/routes/me.ts`
- Test: manual typecheck for this phase

- [ ] **Step 1: 更新 imports**

在 `apps/edge/src/routes/me.ts` 中把 billing import 改成：

```ts
import {
  getBalance,
  getConfigInt,
  getSubjectBalance,
  redeemCode,
  RedemptionError,
} from '../lib/billing';
```

- [ ] **Step 2: 添加 route**

在 `/v1/me/balance` route 后加入：

```ts
// GET /v1/me/subject — personal subject + subject wallet compatibility
// read. This is the bridge for the Crew/temporary-group foundation:
// clients can learn the current user's responsible subject without
// switching the existing /me/balance UI all at once.
meRoutes.get('/subject', async (c) => {
  const userJwt = c.var.userJwt!;
  const userId = c.var.userId!;
  const supa = userClient(c.env, userJwt);

  const { data: subject, error } = await supa
    .from('subjects')
    .select('id, subject_type, display_name, status, created_at, updated_at')
    .eq('subject_type', 'user_account')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    console.error('[me/subject] subject read failed', error);
    return jsonError(c, 500, 'internal_error');
  }
  if (!subject) {
    return jsonError(c, 404, 'subject_not_found', {
      message: '个人责任主体尚未初始化',
    });
  }

  const wallet = await getSubjectBalance(supa, subject.id as string);
  return c.json({
    subject,
    wallet: {
      balance_credits: wallet?.balance_credits ?? 0,
      lifetime_topup_credits: wallet?.lifetime_topup_credits ?? 0,
      lifetime_spent_credits: wallet?.lifetime_spent_credits ?? 0,
    },
  });
});
```

- [ ] **Step 3: 跑 Edge typecheck**

Run:

```bash
bun --filter='@pendingbot/edge' run typecheck
```

Expected: PASS。如果 schema 尚未生成导致 `subjects` / `subject_wallets` 类型不存在，先执行 Task 4。

- [ ] **Step 4: 提交 route**

```bash
git add apps/edge/src/routes/me.ts
git commit -m "edge: expose personal subject"
```

## Task 4: 应用 migration 并生成 schema types

**Files:**
- Modify: `apps/edge/src/db/schema.ts`

- [ ] **Step 1: 应用 linked DB migration**

Run:

```bash
supabase db push --linked
```

Expected: 新 migration 应用到 linked DB，输出显示没有 SQL error。

- [ ] **Step 2: 生成 TypeScript schema**

Run:

```bash
bun --filter='@pendingbot/edge' run types:db
```

Expected: `apps/edge/src/db/schema.ts` 更新，包含 `subjects`、`subject_wallets`、`group_subject_members` 和新增 RPC 类型。

- [ ] **Step 3: 跑 typecheck**

Run:

```bash
bun --filter='@pendingbot/edge' run typecheck
```

Expected: PASS。

- [ ] **Step 4: 提交 schema**

```bash
git add apps/edge/src/db/schema.ts
git commit -m "chore(db): regen schema after subject foundation"
```

## Task 5: 数据库冒烟验证

**Files:**
- No code changes.

- [ ] **Step 1: 验证 personal subject 回填**

Run:

```bash
supabase db query --linked "select count(*) as subjects from pendingbot.subjects where subject_type = 'user_account';"
```

Expected: `subjects` 大于 0。

- [ ] **Step 2: 验证 subject wallet 回填**

Run:

```bash
supabase db query --linked "select count(*) as wallets from pendingbot.subject_wallets sw join pendingbot.subjects s on s.id = sw.subject_id where s.subject_type = 'user_account';"
```

Expected: `wallets` 等于或接近 personal subject 数；如果少于 personal subject 数，停止并检查 migration。

- [ ] **Step 3: 验证 group subject 懒创建 RPC**

先找一个 group conversation：

```bash
supabase db query --linked "select id from pendingbot.conversations where conversation_type = 'group' limit 1;"
```

拿到 `<group_id>` 后运行：

```bash
supabase db query --linked "select pendingbot.ensure_group_subject_for_conversation('<group_id>'::uuid) as subject_id;"
```

Expected: 返回一个 uuid。

- [ ] **Step 4: 验证没有破坏旧余额接口**

Run:

```bash
bun --filter='@pendingbot/edge' run typecheck
```

Expected: PASS。旧 `/v1/me/balance` 仍然编译通过。

## Task 6: 收尾检查

**Files:**
- No code changes unless previous tasks found a bug.

- [ ] **Step 1: 全量相关测试**

Run:

```bash
bun --filter='@pendingbot/edge' run test src/lib/billing.test.ts
```

Expected: PASS。

- [ ] **Step 2: Edge typecheck**

Run:

```bash
bun --filter='@pendingbot/edge' run typecheck
```

Expected: PASS。

- [ ] **Step 3: 检查 staged / unstaged 内容**

Run:

```bash
git status -sb
git log --oneline main..HEAD
```

Expected: worktree clean；分支上有 subject foundation 相关小提交和设计提交。

## 覆盖范围核对

本计划覆盖设计 spec 的 Phase 1：

- subject 表；
- subject wallet；
- group subject membership；
- personal subject backfill；
- group subject lazy creation；
- subject RLS helper；
- subject debit RPC；
- Edge subject billing helper；
- `/v1/me/subject` 兼容读取；
- schema type generation。

本计划不覆盖：

- `temporary_group` / `crew` conversation type；
- human help request；
- dispatch/session events；
- runner host 和 runner lease；
- iOS/macOS UI。

这些需要在 Phase 1 验证通过后分别写独立计划。

---

## Spec v2 修订（2026-05-28）

新 spec(`docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md`)在 §4
重新校准了「Subject 模型」。本节列出**与原 plan 的差异**与后续两份迁移做的对齐;原 plan 中
2026-05-24 已落地的 SQL **不动**(数据库不喜欢 retroactive 改时间戳),都用增量迁移收敛。

### 1. 群账号定位:轻量化、可独立创建（spec v2 §4.2）

**spec 原文要点**:

- 群账号跟 Notion workspace 那种重资产**完全不同**
- 出门旅游临时建一个群账号都行,家用一台电脑共享也合适
- 任何协作平台都需要组织账号,但 PendingBot 的组织账号**比业界主流轻量得多**

**原 plan 把 `subjects.group_conversation_id` 设为非空** → 跟新定位冲突(必须先有 group
conversation 才能建 group_account)。修订:

- 迁移 `20260528083506_subject_v2_schema_alignment.sql` 放宽 `subjects_user_kind_chk`,
  允许 `group_account` 行的 `group_conversation_id IS NULL`(独立创建的群账号)
- 旧绑了 conversation 的 group_account 行不动,继续可用
- 后续 group_account 创建路径 = `grp_create_group_subject(display_name)`,**不强求绑 conversation**

### 2. Subject 表字段补齐(spec v2 字段名)

| 字段 | 原 plan | spec v2 期望 | 迁移做的事 |
|---|---|---|---|
| `subjects.kind` | 没有(用 `subject_type`) | `kind` | 加列,触发器保持两个字段同步,以 `kind` 为准 |
| `subjects.created_by` | 没有 | `created_by uuid REFERENCES users(id)` | 加列,回填:user_account → 自己;legacy group_account → conversation_group_meta.created_by |
| `group_subject_members.granted_by` | 没有(只有 `created_at`) | `granted_by` | 加列,owner 行回填为自己(临时);其余 NULL,等真正经手时再填 |
| `group_subject_members.granted_at` | `created_at` | `granted_at` | 加列,从 `created_at` 回填 |
| `subject_wallets.updated_at` | `balance_updated_at` | `updated_at` | 加列,触发器把两个时间戳并行推进 |

`subject_type` / `created_at` / `balance_updated_at` **不删** — 老代码(crew_announcement_mentions、
device_login_grants、billing_debit_subject)还在引用,留作 alias。

### 3. bots / conversations 加 responsible_subject_id

原 plan 没碰这两张表(留给 Crew 阶段)。spec v2 §4.1 明确:**每个 crew / temporary group /
session / runner host / fly machine 都绑唯一 `responsible_subject_id`**。bots 和 conversations
是基础对象,这一步先把列加上,nullable + 回填到 owner 的 user subject。

迁移 `20260528083616_bots_conversations_responsible_subject.sql`:

- 兜底回填所有 `pendingbot.users` 行的 user_account subject(老 plan 的回填只覆盖了 2026-05-24
  存量,新增 user 走触发器,但触发器从 INSERT 起才挂)
- `bots.responsible_subject_id` = `creator_id` 对应的 user_account subject(preset bot creator_id
  NULL → 留 NULL,后续运营策略决定)
- `conversations.responsible_subject_id` = `user_id` 对应的 user_account subject(bot-only /
  system conversation → 留 NULL)

### 4. 权限矩阵 α 简化版（spec v2 §4.3）

原 plan 在 `group_subject_members` 上散布了 `can_manage_wallet` / `can_manage_runners` /
`can_create_crew` 三个布尔位 — 这是「可自定义权限」的雏形。spec v2 §4.3 明确把 α 版收紧成
**固定三级 role 默认权限,v1 不允许自定义**:

| 操作 | owner | admin | member |
|---|---|---|---|
| 在群下任一 crew 里对话/看摘要 | ✅ | ✅ | ✅ |
| 创建群下的 crew | ✅ | ✅ | ✅ |
| 删除群下的 crew | ✅ | ✅ | 仅自己创建的 |
| **群钱包充值** | ✅ | ✅ | ✅ |
| 加 member / 踢 member | ✅ | ✅ | ❌ |
| 启动 / 销毁 Fly machine | ✅ | ✅ | ❌ |
| 创建 / 删除 captain bot | ✅ | ✅ | ❌ |
| **批准外部 crew 认本群下 crew 为父** | ✅ | ✅ | ❌ |
| **接受跨主体协作邀请** | ✅ | ✅ | ❌ |
| **登录代表群账号**(扫码到 PendingCrew Mac/iPad) | ✅ | ✅ | ❌ |
| 加/踢 admin、转让 ownership、解散群 | ✅ | ❌ | ❌ |

**关键约束**:

- **单 owner**(v1 不做 multi-owner,转让足够解决继承场景)
- **充值全员开放** — owner / admin / member 都能调 `grp_topup_wallet`
- **无提现接口** — 规避「金融服务」合规风险,简化产品;schema 不留接口
- **群账号 = 永远 unified billing** — 没有 BYOK 概念

布尔位字段(`can_manage_*`)留作 legacy 数据,不再扩展,但也不删 — 删的话 RPC 老路径会断。
后续如需「自定义权限」(post-v1),从 RPC 守卫开始改,而不是回到布尔位模式。

### 5. 新 RPC 套件(替代原 plan 的散落 helper)

迁移 `20260528083639_group_account_permission_rpcs.sql` 实现:

| RPC | 调用者 | 行为 |
|---|---|---|
| `grp_create_group_subject(display_name)` | 任何 authenticated user | 建 group_account + wallet + 自己 owner 行 |
| `grp_add_member(group_subject_id, user_id)` | owner/admin | 加 member |
| `grp_remove_member(group_subject_id, user_id)` | owner/admin | 踢 member;踢 admin 仅 owner |
| `grp_promote_to_admin(group_subject_id, user_id)` | owner only | member → admin |
| `grp_demote_admin(group_subject_id, user_id)` | owner only | admin → member |
| `grp_transfer_ownership(group_subject_id, to_user_id)` | owner only | 原 owner 自动降为 admin |
| `grp_topup_wallet(group_subject_id, credits)` | 任何 group member | 充值;**不提供提现** |

全部 `SECURITY DEFINER` + 内部 `auth.uid()` 检查。`service_role` 可 bypass(支付 webhook
后台调用)。原 plan 的 `ensure_user_subject` / `ensure_group_subject_for_conversation` /
`billing_debit_subject` **保留**,RPC 之间互补。

### 6. RLS 状态

- `subjects` / `subject_wallets` / `group_subject_members` 的老 SELECT 策略仍生效(2026-05-24 那份迁移)
- WRITE 暂时**只通过 RPC**(security definer),不放 client-side INSERT/UPDATE/DELETE — 这是 α
  版务实选择,避免精细 RLS write policy 写错
- **完整 RLS(尤其跨群 read / member 自管 read 边界)留到 T1.3** 一起做(扫码登录会同时
  打开「以 subject 身份读 subject_wallets」路径)

### 7. 后续 phase 关联

- **T1.3 扫码登录** 依赖本步的 `created_by` / `granted_by` / RPC 套件,以及 `responsible_subject_id` 列
- **T2.x Crew schema** 依赖本步的 `subjects` + responsible_subject_id 链路(crew_* 表已用 FK)
- **billing path** 仍走原 plan 的 `billing_debit_subject`(未改),只是入口主体变成 `responsible_subject_id`
