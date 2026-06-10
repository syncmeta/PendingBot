# PendingCrew 登录 / 家族 SSO 实现 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development(推荐)或 superpowers:executing-plans 逐 task 执行。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 让 PendingCrew 能复用本机同公司 app 的登录态近乎一键登录,但只拿到自己 scoped 的 grant —— 共享账号、分开授权、不共享全权 session。

**Architecture:** 新增一个 **per-user 的"家族 SSO 凭据"**(`pfa_` token,独立表,只能 mint 子 grant、换不出 session),放进同 team 共享 keychain 组。任意一层登录成功都顺手签发它;之后任意同 team app 调 `POST /v1/device-grant/mint` 自助换自己的 device-grant。复用现有 `subject_device_grants` + `subject_can_authorize_device_grant` 授权检查。

**Tech Stack:** Cloudflare Workers(Hono)+ Supabase Postgres(`pendingbot` schema)+ edge vitest;PendingCrew Swift（macOS）。

**Spec:** `docs/superpowers/specs/2026-06-08-pendingcrew-login-sso-design.md`。

**精化(vs spec D1)**:家族凭据是**账号级(per-user)**,而 device-grant 是 **subject 级**,二者 scope 不同 → 家族凭据用**独立 per-user 表 `family_sso_credentials`**,而非往 `subject_device_grants` 塞 `family_sso` kind。设计意图(mint-only、不换 session、可级联撤销)不变。

**分支/边界**:edge schema 改动从主 worktree `db push` + `types:db`(需用户在场确认那一拍)。不动 `feat/session-crew-comms` 已落内容。**L2 批准网页**不在本 plan(单独排)。

---

## 文件结构

**Edge(新建/改)**
- Create `supabase/migrations/<ts>_family_sso_credentials.sql` — 家族凭据表 + mint RPC + revoke RPC。
- Modify `apps/edge/src/routes/device-login.ts` — consume 时顺手签发家族凭据;poll 响应回传。
- Create `apps/edge/src/routes/device-grant.ts` — `POST /mint`(家族凭据认证)+ `POST /revoke`。
- Modify `apps/edge/src/index.ts`(或路由挂载处)— 挂 `device-grant.ts`。
- Modify `apps/edge/src/db/schema.ts` — regen(`types:db`)。
- Test `apps/edge/tests/device-grant-mint.test.ts`(+ `device-login.test.ts` 若有，加家族凭据断言）。

**App(改/新建)**
- Modify `apps/pendingcrew/Resources/PendingCrew.entitlements` — 加共享组。
- Modify `apps/pendingcrew/Sources/Support/KeychainStore.swift` — 共享组读写(`kSecAttrAccessGroup`)。
- Create `apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift` — 家族凭据读写(共享组)。
- Modify `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift` — `mintGrant(...)` + `pollChallenge` 解 familyCredential。
- Modify `apps/pendingcrew/Sources/Stores/AppModel.swift` — 启动静默 L1 + 存家族凭据。
- Modify `apps/pendingcrew/Sources/Views/LoginView.swift` — QR 成功后存家族凭据(L3）。
- Modify `apps/pendingcrew/Sources/Mac/Views/CrewSidebarView.swift` — 本机模式下"登录"入口(sheet → LoginView）。

---

## Phase A — Edge：家族凭据表 + mint/revoke（vitest 可验大半）

### Task A1：迁移 — `family_sso_credentials` 表 + mint/revoke RPC

**Files:** Create `supabase/migrations/<ts>_family_sso_credentials.sql`（`<ts>` = `date -u +%Y%m%d%H%M%S`，见 CLAUDE.md "Before writing a new migration"）。

- [ ] **Step 1: 写迁移**

```sql
-- 家族 SSO 凭据：账号级(per-user)、mint-only、换不出 session。同公司 app 共享
-- (放共享 keychain 组)，各自调 mint 换自己 scoped 的 device-grant。
BEGIN;
SET search_path TO pendingbot, public;

CREATE TABLE IF NOT EXISTS pendingbot.family_sso_credentials (
  id uuid PRIMARY KEY DEFAULT pendingbot.uuidv7(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL,
  device_name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked','expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '90 days'),
  last_used_at timestamptz,
  revoked_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS family_sso_credentials_token_hash_uniq
  ON pendingbot.family_sso_credentials(token_hash);
CREATE INDEX IF NOT EXISTS family_sso_credentials_user_idx
  ON pendingbot.family_sso_credentials(user_id, status, created_at DESC);

-- 子 grant 加一列：记是哪张家族凭据 mint 出来的（级联撤销用）。
ALTER TABLE pendingbot.subject_device_grants
  ADD COLUMN IF NOT EXISTS parent_family_credential_id uuid
  REFERENCES pendingbot.family_sso_credentials(id) ON DELETE SET NULL;

-- 签发家族凭据（consume / approve 路径调）。
CREATE OR REPLACE FUNCTION pendingbot.issue_family_sso_credential(
  p_id uuid, p_user_id uuid, p_token_hash text, p_device_name text
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = pendingbot, public AS $$
  INSERT INTO pendingbot.family_sso_credentials(id, user_id, token_hash, device_name)
  VALUES (p_id, p_user_id, p_token_hash, p_device_name)
  RETURNING id;
$$;
ALTER FUNCTION pendingbot.issue_family_sso_credential(uuid, uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.issue_family_sso_credential(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.issue_family_sso_credential(uuid, uuid, text, text) TO service_role;

-- 用家族凭据 mint 一张子 device-grant：校验凭据 active/未过期 → 拿 user_id →
-- 复用 subject_can_authorize_device_grant 授权检查 → 插 grant。换不出 session。
CREATE OR REPLACE FUNCTION pendingbot.mint_device_grant_from_family(
  p_family_token_hash text,
  p_grant_id uuid,
  p_token_hash text,
  p_subject_id uuid,
  p_grant_kind text,
  p_scopes jsonb,
  p_app_kind text,
  p_device_name text,
  p_device_public_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pendingbot, public AS $$
DECLARE
  fam pendingbot.family_sso_credentials%ROWTYPE;
BEGIN
  SELECT * INTO fam FROM pendingbot.family_sso_credentials
   WHERE token_hash = p_family_token_hash FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'family credential not found' USING ERRCODE = '42501';
  END IF;
  IF fam.status <> 'active' OR fam.expires_at <= now() THEN
    RAISE EXCEPTION 'family credential inactive' USING ERRCODE = 'P0001';
  END IF;
  IF p_grant_kind NOT IN ('pendingbot_client','pendingcrew_control','pendingcrew_runner') THEN
    RAISE EXCEPTION 'bad grant kind' USING ERRCODE = 'P0001';
  END IF;
  IF NOT pendingbot.subject_can_authorize_device_grant(p_subject_id, fam.user_id, p_grant_kind) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  INSERT INTO pendingbot.subject_device_grants(
    id, subject_id, granted_by_user_id, app_kind, platform,
    device_name, device_public_key, grant_kind, scopes, token_hash,
    status, parent_family_credential_id
  ) VALUES (
    p_grant_id, p_subject_id, fam.user_id, p_app_kind, 'macos',
    p_device_name, p_device_public_key, p_grant_kind, p_scopes, p_token_hash,
    'active', fam.id
  );
  UPDATE pendingbot.family_sso_credentials SET last_used_at = now() WHERE id = fam.id;

  RETURN jsonb_build_object('grant_id', p_grant_id, 'subject_id', p_subject_id,
                            'grant_kind', p_grant_kind, 'scopes', p_scopes);
END $$;
ALTER FUNCTION pendingbot.mint_device_grant_from_family(text,uuid,text,uuid,text,jsonb,text,text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.mint_device_grant_from_family(text,uuid,text,uuid,text,jsonb,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.mint_device_grant_from_family(text,uuid,text,uuid,text,jsonb,text,text,text) TO service_role;

-- 撤销家族凭据 + 级联撤其 mint 出的子 grant。
CREATE OR REPLACE FUNCTION pendingbot.revoke_family_sso_credential(p_family_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pendingbot, public AS $$
BEGIN
  UPDATE pendingbot.family_sso_credentials
     SET status='revoked', revoked_at=now() WHERE id = p_family_id;
  UPDATE pendingbot.subject_device_grants
     SET status='revoked', revoked_at=now()
   WHERE parent_family_credential_id = p_family_id AND status='active';
END $$;
ALTER FUNCTION pendingbot.revoke_family_sso_credential(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.revoke_family_sso_credential(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.revoke_family_sso_credential(uuid) TO service_role;

ALTER TABLE pendingbot.family_sso_credentials ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_sso_credentials_self_read ON pendingbot.family_sso_credentials;
CREATE POLICY family_sso_credentials_self_read
  ON pendingbot.family_sso_credentials FOR SELECT TO authenticated
  USING (user_id = auth.uid());
GRANT SELECT ON TABLE pendingbot.family_sso_credentials TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.family_sso_credentials TO service_role;

COMMIT;
```

- [ ] **Step 2: 应用 + regen（需用户在场确认 db push）**

从主 worktree:`supabase db push --linked` → `bun --filter='@pendingbot/edge' run types:db` → `bun --filter='@pendingbot/edge' run typecheck`。

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/<ts>_family_sso_credentials.sql apps/edge/src/db/schema.ts
git commit -m "db: family_sso_credentials 表 + mint/revoke RPC"
```

### Task A2：`POST /v1/device-grant/mint` 端点

**Files:** Create `apps/edge/src/routes/device-grant.ts`;Modify `apps/edge/src/index.ts`（挂路由，参照 `deviceLoginRoutes` 的挂法）；Test `apps/edge/tests/device-grant-mint.test.ts`。

- [ ] **Step 1: 写失败测试** `apps/edge/tests/device-grant-mint.test.ts`

参照 `apps/edge/tests/*.test.ts` 现有风格(Miniflare / mock serviceClient)。断言:
1. 合法家族凭据 + `grantKind=pendingcrew_control` + scopes ⊆ allowed → 200 + `deviceGrantToken` 以 `pdg_` 开头。
2. `scopes` 超 `allowedScopesForGrant(grantKind)` → 400。
3. 无 `Authorization: Bearer pfa_…` → 401。
4. RPC 返回 not-authorized（`42501`）→ 403。

```ts
it('mints a scoped grant from a family credential', async () => {
  const res = await app.request('/v1/device-grant/mint', {
    method: 'POST',
    headers: { Authorization: 'Bearer pfa_validtoken', 'Content-Type': 'application/json' },
    body: JSON.stringify({
      subjectId: SUBJECT_UUID, grantKind: 'pendingcrew_control',
      scopes: ['subject:read','crew:read'], appKind: 'pendingcrew_macos',
      deviceName: 'Mac', devicePublicKey: 'pk-1234567890abcdef',
    }),
  }, env);
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(body.deviceGrantToken).toMatch(/^pdg_/);
});
```

- [ ] **Step 2: 跑测试确认 fail**

Run: `cd apps/edge && ./node_modules/.bin/vitest run device-grant-mint`
Expected: FAIL（路由不存在 / 404）。

- [ ] **Step 3: 写端点** `apps/edge/src/routes/device-grant.ts`

复用 `device-login.ts` 里的 `sha256Hex` / `randomToken` / `allowedScopesForGrant` / `scopesSubsetOf` / `appGrantCompatible`（抽到 `apps/edge/src/lib/device-grant-scopes.ts` 共享，避免 DRY 违例；device-login.ts 同步 import）。

```ts
import { Hono } from 'hono';
import { z } from 'zod';
import { serviceClient } from '../lib/supabase';
import { jsonError } from '../lib/http-error';
import type { Json } from '../db/schema';
import type { AppBindings } from '../types';
import {
  AppKind, GrantKind, Scope, sha256Hex, randomToken,
  appGrantCompatible, allowedScopesForGrant, scopesSubsetOf,
} from '../lib/device-grant-scopes';

export const deviceGrantRoutes = new Hono<AppBindings>();

const MintBody = z.object({
  subjectId: z.string().uuid(),
  grantKind: GrantKind,
  scopes: z.array(Scope).default(['subject:read']),
  appKind: AppKind,
  deviceName: z.string().trim().min(1).max(120),
  devicePublicKey: z.string().trim().min(16).max(4096),
});

deviceGrantRoutes.post('/mint', async (c) => {
  const auth = c.req.header('Authorization') ?? '';
  const fam = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!fam.startsWith('pfa_')) return jsonError(c, 401, 'unauthorized');

  let body: z.infer<typeof MintBody>;
  try { body = MintBody.parse(await c.req.json()); }
  catch (err) { return jsonError(c, 400, 'invalid_body', { detail: String(err) }); }

  if (!appGrantCompatible(body.appKind, body.grantKind))
    return jsonError(c, 400, 'invalid_body', { message: 'grant kind does not match app kind' });
  if (!scopesSubsetOf(body.scopes, allowedScopesForGrant(body.grantKind)))
    return jsonError(c, 400, 'invalid_body', { message: 'requested scopes exceed grant kind' });

  const svc = serviceClient(c.env) as any;
  const familyHash = await sha256Hex(fam);
  const grantToken = randomToken('pdg');
  const grantId = crypto.randomUUID();
  const tokenHash = await sha256Hex(grantToken);

  const { data, error } = await svc.rpc('mint_device_grant_from_family', {
    p_family_token_hash: familyHash,
    p_grant_id: grantId,
    p_token_hash: tokenHash,
    p_subject_id: body.subjectId,
    p_grant_kind: body.grantKind,
    p_scopes: body.scopes as Json,
    p_app_kind: body.appKind,
    p_device_name: body.deviceName,
    p_device_public_key: body.devicePublicKey,
  });
  if (error) {
    const m = String(error.message ?? error);
    if (/not authorized/i.test(m)) return jsonError(c, 403, 'forbidden');
    if (/not found|inactive/i.test(m)) return jsonError(c, 401, 'unauthorized', { message: m });
    return jsonError(c, 500, 'database_error', { detail: m });
  }
  const row = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>;
  return c.json({
    deviceGrantToken: grantToken,
    grantId, subjectId: body.subjectId, grantKind: body.grantKind,
    scopes: Array.isArray(row.scopes) ? row.scopes : body.scopes,
  });
});
```

挂载（`apps/edge/src/index.ts`，紧挨现有 deviceLogin 挂法）:
```ts
import { deviceGrantRoutes } from './routes/device-grant';
app.route('/v1/device-grant', deviceGrantRoutes);
```

- [ ] **Step 4: 跑测试确认 pass**

Run: `cd apps/edge && ./node_modules/.bin/vitest run device-grant-mint` → PASS。再 `bun --filter='@pendingbot/edge' run typecheck`。

- [ ] **Step 5: Commit**

```bash
git add apps/edge/src/routes/device-grant.ts apps/edge/src/lib/device-grant-scopes.ts \
  apps/edge/src/routes/device-login.ts apps/edge/src/index.ts apps/edge/tests/device-grant-mint.test.ts
git commit -m "edge: POST /v1/device-grant/mint（家族凭据换 scoped grant）+ scope helpers 抽共享"
```

### Task A3：登录成功时顺手签发家族凭据（L3 + poll 回传）

**Files:** Modify `apps/edge/src/routes/device-login.ts`（poll/consume 路径 + approve 路径）；Test 同 `device-grant-mint.test.ts` 或 `device-login.test.ts`。

- [ ] **Step 1: 写失败测试** — approve 后 poll，响应除 `deviceGrantToken` 外应含 `familyCredential`（`pfa_…`），且能用它 mint。

- [ ] **Step 2: 实现** — 在 `GET /challenges/:id` 的 consume 成功分支（device-login.ts:218 后），若该 user 还没活跃家族凭据则签发一张:

```ts
// consume 成功后：为审批人签发/复用家族凭据，回传给 app 存共享组。
let familyCredential: string | null = null;
const approvedBy = typeof grantRow.granted_by_user_id === 'string' ? grantRow.granted_by_user_id : null;
// 注：consume RPC 需在 RETURN 里多带 granted_by_user_id（同步小改 RPC）。
if (approvedBy) {
  const famToken = randomToken('pfa');
  const famId = crypto.randomUUID();
  const { error: famErr } = await svc.rpc('issue_family_sso_credential', {
    p_id: famId, p_user_id: approvedBy,
    p_token_hash: await sha256Hex(famToken),
    p_device_name: typeof grantRow.device_name === 'string' ? grantRow.device_name : 'Mac',
  });
  if (!famErr) familyCredential = famToken;
}
return c.json({ status: 'approved', deviceGrantToken: grantToken, /* …现有字段… */, familyCredential });
```

（consume RPC 的 `RETURN jsonb_build_object(...)` 加 `'granted_by_user_id', challenge_row.approved_by_user_id` + `'device_name', challenge_row.device_name`，放进 A1 迁移或一个紧跟的小迁移。）

- [ ] **Step 3: 跑测试 + typecheck → PASS**
- [ ] **Step 4: Commit** `git commit -m "edge: 登录 consume 时签发家族凭据，poll 回传"`

---

## Phase B — App：共享 keychain + 自助 mint（macOS build 可验编译）

### Task B1：entitlement 加共享组

**Files:** Modify `apps/pendingcrew/Resources/PendingCrew.entitlements`。

- [ ] **Step 1:** `keychain-access-groups` array 追加共享组:
```xml
<key>keychain-access-groups</key>
<array>
  <string>$(AppIdentifierPrefix)com.pendingname.pendingcrew</string>
  <string>$(AppIdentifierPrefix)com.pendingname.shared</string>
</array>
```
- [ ] **Step 2:** macOS build 编译过（签名环境会校验组；headless ad-hoc 回落不阻塞编译）。
- [ ] **Step 3: Commit** `git commit -m "pendingcrew: entitlement 加共享 keychain 组"`

### Task B2：`FamilyCredentialStore`（共享组读写）

**Files:** Create `apps/pendingcrew/Sources/Support/FamilyCredentialStore.swift`；参照 `KeychainStore.swift` 的 `kSecUseDataProtectionKeychain` 写法,但**显式带** `kSecAttrAccessGroup`。

- [ ] **Step 1: 写**（自包含 Foundation；可编进 PendingCrewTests）

```swift
import Foundation
/// 家族 SSO 凭据（pfa_…）放**共享 keychain 组**，同 team 的 PendingBot 也能读/写。
enum FamilyCredentialStore {
    static let sharedGroup = "M42BKJN82S.com.pendingname.shared"
    static let service = "com.pendingname.family-sso"
    static func get() -> String? {
        var q: [String: Any] = baseQuery(); q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
    static func set(_ token: String) {
        SecItemDelete(baseQuery() as CFDictionary)
        var q = baseQuery(); q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func clear() { SecItemDelete(baseQuery() as CFDictionary) }
    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccessGroup as String: sharedGroup,
         kSecUseDataProtectionKeychain as String: true]
    }
}
```
- [ ] **Step 2: 单测**（Tests/PendingCrewTests + project.yml 加源）：set→get→clear 往返（注:CI/真机带共享组 entitlement 才真过；headless 可能 errSecMissingEntitlement → 测试容错或标 skip）。
- [ ] **Step 3:** xcodegen + macOS build。
- [ ] **Step 4: Commit** `git commit -m "pendingcrew: FamilyCredentialStore 共享组读写"`

### Task B3：`PendingCrewAPI.mintGrant` + poll 解 familyCredential

**Files:** Modify `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift`。

- [ ] **Step 1:** 加 `mintGrant`:
```swift
struct MintGrantResponse: Decodable { let deviceGrantToken: String?; let grantKind: String? }
func mintGrant(familyCredential: String, subjectId: String, grantKind: String,
               scopes: [String], deviceName: String, devicePublicKey: String) async throws -> MintGrantResponse {
    let body: [String: Any] = ["subjectId": subjectId, "grantKind": grantKind, "scopes": scopes,
                               "appKind": "pendingcrew_macos", "deviceName": deviceName,
                               "devicePublicKey": devicePublicKey]
    return try await post(path: "v1/device-grant/mint", body: body,
                          authenticated: false, bearer: familyCredential)   // 带 Authorization: Bearer pfa_…
}
```
（`post(...)` 若没有 `bearer` 参数,加一个可选参数走 `Authorization` 头。）
- [ ] **Step 2:** `PollChallengeResponse` 加 `familyCredential: String?`。
- [ ] **Step 3:** typecheck（build）。
- [ ] **Step 4: Commit** `git commit -m "pendingcrew: API mintGrant + poll 解 familyCredential"`

### Task B4：启动静默 L1 + 存家族凭据

**Files:** Modify `apps/pendingcrew/Sources/Stores/AppModel.swift`。

- [ ] **Step 1:** 加 `tryFamilySSO()`:启动时若无 credential 但共享组有家族凭据 → 列 subject（需要一个不需 grant 的 me/subject 探针,或先用默认个人 subject）→ `mintGrant(grantKind:"pendingcrew_control")` → `saveDeviceGrantToken`。失败静默(留本机模式)。
- [ ] **Step 2:** `saveDeviceGrantToken` 之外加 `saveFamilyCredential(_:)` → `FamilyCredentialStore.set`。
- [ ] **Step 3:** `PendingCrewApp.init` / RootView `.task` 调 `await model.tryFamilySSO()`。
- [ ] **Step 4:** macOS build。
- [ ] **Step 5: Commit** `git commit -m "pendingcrew: 启动静默家族 SSO + 存凭据"`

---

## Phase C — L3 接线 + 登录入口

### Task C1：QR 登录成功后存家族凭据

**Files:** Modify `apps/pendingcrew/Sources/Views/LoginView.swift`（:190 拿到 token 处）。

- [ ] **Step 1:** poll 响应里若有 `familyCredential` → `model.saveFamilyCredential(it)`（与 `saveDeviceGrantToken` 同一拍）。
- [ ] **Step 2: build + Commit** `git commit -m "pendingcrew: QR 登录成功存家族凭据（L1 bootstrap）"`

### Task C2：本机模式侧栏"登录"入口

**Files:** Modify `apps/pendingcrew/Sources/Mac/Views/CrewSidebarView.swift`。

- [ ] **Step 1:** `.local` 模式的身份菜单加"登录 PendingBot 账号" → `@State showingLogin` → `.sheet(isPresented:) { LoginView() }`。登录成功(`model.mode == .logged`)自动关 sheet（`.onChange(of: model.isAuthenticated)`）。
- [ ] **Step 2: build + Commit** `git commit -m "pendingcrew: 本机模式侧栏加可选登录入口"`

---

## 人工尾巴（需用户 / 真机 / 部署）

- [x] ~~**D4 provisioning**~~ **勘误：keychain group 不需要 Apple Developer portal 配置**（portal 里只有 App Groups——那是共享容器机制，另一回事）。provisioning profile 自动允许 `TEAMID.*` 下所有 keychain 组；只要两个 app 的 entitlements 各声明 `$(AppIdentifierPrefix)com.pendingname.shared` + 非 ad-hoc 签名即可。已落：PendingCrew `2de2f4d7`（B1）+ PendingBot `e630da0e`，双 macOS build 绿。剩"真机跨 app 互读"归入下面的验证条。
- [ ] **PendingBot 侧**:PendingBot(Mac/手机)登录成功时也**存一份家族凭据进共享组**（对称改 PendingBot 客户端 + 它的 approve 流回传 familyCredential）。本 plan 只做 PendingCrew 侧 + edge;PendingBot 侧单列。
- [ ] **跨 app 真读验**:两个真签名 app 装同机 → PendingBot 写、PendingCrew 读到家族凭据 → 秒登。headless 验不了（errSecMissingEntitlement）。
- [ ] **部署 edge** + 真 Supabase 会话跑 mint 全链路。
- [ ] **L2 批准网页**（`bot.pendingname.com/d/:id` + ASWebAuthenticationSession）—— 单独 plan。
- [ ] **安全负向测试**:拿 `pfa_` 打业务端点 → 必须 401（family 凭据换不出 session/数据访问）。

---

## Self-Review

**Spec 覆盖**:L1(A1-A2 mint + B 全 app 侧)✓;L3 顺手发凭据(A3+C1)✓;共享组(B1-B2)✓;不过权(mint RPC 不碰 session + 负向测试)✓;撤销/级联(A1 revoke RPC)✓;三层 fallback 的 L1/L3 ✓,**L2 明确划出本 plan**。
**占位扫描**:无 TBD;每个 code step 给了真 SQL/TS/Swift。`tryFamilySSO` 的"subject 探针"是已知薄弱点(B4 Step1 注明:需一个不要 grant 的 subject 列举法,或先默认个人 subject)——这是真实现里要定的细节,非占位,标注了。
**类型一致**:`mintGrant`/`MintGrantResponse`/`familyCredential`/`FamilyCredentialStore` 命名跨 task 一致;edge `mint_device_grant_from_family` 参数序与端点调用序一致。
**已知风险**:B4 的 subject 列举(L1 要知道给哪个 subject mint)—— 个人账号默认 subject 即可,群账号选择留 UI 二期。
