# PendingCrew machine 概念 + 新建流程精简 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PendingCrew 的"运行位置"升级成一等的 machine（Supabase 表，RLS 限本账号），新建 crew 表单砍到"标题(可选自动)+machine(登录多机才显示)+工作目录(三选一默认 CrewGround)"，删除 tag，分类职责改由父 crew 承载。

**Architecture:** 新增 `pendingbot.machine` 表（本机/peer/fly 三类统一进表，RLS 按 subject）。crew 新增 `machine_id` FK 作为事实源；为不牵连 world-model/crew-comms 等 6+ 处读取方，`runtime_location` 保留为**写入时派生的镜像列**（来源 = 所选 machine 的 kind），仅 drop 低耦合的 `peer_device_id`/`fly_machine_id` 与其联动 CHECK 约束。tag 列连根删。Swift 端 models 保留 `runtimeLocation`（仍由 edge 下发派生值，列表/inspector 展示不变），新增 `machineId` + Machine 模型。

**Tech Stack:** Supabase Postgres（迁移 + plpgsql RPC）、Cloudflare Workers/Hono（TypeScript edge）、SwiftUI（macOS + iPadOS，apps/pendingcrew）、vitest、xcodebuild。

**关键约束（已核实）：**
- crew 实体 = `pendingbot.temporary_group_meta`（PK = conversation_id），创建走 RPC `create_crew_with_captain`（最新定义在 `supabase/migrations/20260529014827_crew_rpcs_accept_actor.sql`）。
- `runtime_location` CHECK + `temporary_group_meta_runtime_target_chk`（联动 peer/fly id）在 `supabase/migrations/20260528105149_crew_v2_schema_extensions.sql`。
- `runtime_location`/`runtime_kind` 消费点：`apps/edge/src/llm/session-world-model.ts:69,241`、`apps/edge/src/routes/messages.ts:1442`、`apps/edge/src/routes/crew.ts:248,266,510,545`、`apps/edge/src/routes/crews.ts:100,152,292,352,434`、`apps/edge/src/routes/crew-comms.ts:457,753` → 故保留 `runtime_location`。
- `peer_device_id`/`fly_machine_id` 仅在 `crews.ts` 创建校验处被写/读 → 可安全 drop。
- DAG 父边 attach/detach UI 已存在：`apps/pendingcrew/Sources/Mac/Views/CrewDetailInspector.swift` `parentDAGSection`（lines 244-320）+ `CrewStore.attachParent/detachParent` + edge `POST /v1/crews/:crewId/attach-parent`（crews.ts:205）。parentCrewIds 是**纯本地概念**（edge 不下发）。
- 离线地名兜底：iOS 已有 `apps/pendingbot/Resources/names.txt`（~19684 条中文地名）+ `NameCorpus`；pendingcrew **无**本地地名列表；服务端 `random_place_name()` RPC + `GET /v1/groups/random-name`（groups.ts:192）。**注意**：现有 corpus 是中文地名，非"全世界地名"——见 Task 12 决策注。
- 迁移命名：`YYYYMMDDhhmmss_snake_case.sql`（用 `supabase migration new <name>` 或 `date -u +%Y%m%d%H%M%S`）。
- 应用迁移流程（CLAUDE.md）：`supabase db push --linked`（在主 worktree）→ `bun --filter='@pendingbot/edge' run types:db` → `typecheck` → commit `chore(db): regen schema.ts after <name>`。
- 设备身份：pendingcrew 用 device-grant 登录（`PendingCrewAPI.createDeviceLoginChallenge`/`mintGrant`，appKind=`pendingcrew_macos`），凭据存 Keychain（`AppModel.saveDeviceGrantToken`）。当前**没有**稳定 device_id；Task 9 需引入一个本地持久化的安装级 UUID。

---

## File Structure

**新建：**
- `supabase/migrations/<ts>_machine_table.sql` — machine 表 + RLS + grants + 索引
- `supabase/migrations/<ts>_crew_machine_id.sql` — crew 加 machine_id、drop peer/fly id 列+约束、改 RPC 派生 runtime_location
- `supabase/migrations/<ts>_crew_drop_tag.sql` — drop tag 列 + 从 RPC 去 tag
- `apps/edge/src/routes/machines.ts` — machine 注册/列表端点
- `apps/edge/src/routes/machines.test.ts` — vitest
- `apps/pendingcrew/Sources/Models/Machine.swift` — Machine 模型 + kind→icon/label
- `apps/pendingcrew/Sources/Resources/crewground_places.txt` — CrewGround 离线地名兜底
- `apps/pendingcrew/Sources/Stores/DeviceIdentity.swift` — 稳定安装级 device_id

**修改：**
- `apps/edge/src/index.ts`（或路由挂载处）— 注册 machinesRoutes
- `apps/edge/src/routes/crews.ts` — 创建/列表/详情去 tag、去 runtime 三件套、接 machineId
- `apps/pendingcrew/Sources/Models/CrewSummary.swift` / `CrewDetail.swift` — 去 tag、加 machineId
- `apps/pendingcrew/Sources/Services/CrewModels.swift` — CreateCrewRequest 去 tag/runtime 三件套、加 machineId、改工厂
- `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift` — 协议加 listMachines/registerSelfMachine；Edge/Local 两实现
- `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift` — machine 端点客户端
- `apps/pendingcrew/Sources/Stores/LocalCrewStore.swift` — LocalCrew 去 tag、createCrew 去 tag
- `apps/pendingcrew/Sources/Stores/CrewStore.swift`（或 PendingCrewBackend.swift 内）— listMachines 缓存 + 登录时 registerSelfMachine
- `apps/pendingcrew/Sources/Mac/Views/CreateCrewSheet.swift` — 表单重构（核心）
- `apps/pendingcrew/Sources/Views/CrewListView.swift` — 去 tag 副标题
- `apps/pendingcrew/Sources/Mac/Views/CrewDetailInspector.swift` — 去 tag Label、relay 去 tag、加"新建子 crew"入口
- `apps/pendingcrew/project.yml` — 把新 Resources 目录纳入 bundle（若未自动纳入）
- `docs/tech-debt.md` / `docs/progress.md` — 账本

---

## Phase 0 — DB 基础

### Task 1: machine 表迁移

**Files:**
- Create: `supabase/migrations/<ts>_machine_table.sql`

- [ ] **Step 1: 生成迁移文件**

在主 worktree 跑：`supabase migration new machine_table`（或 `date -u +%Y%m%d%H%M%S` 取前缀手建）。

- [ ] **Step 2: 写表 + RLS + grants（照 `20260520145200_user_bot_contacts.sql` 的 RLS 模板，但 scope 到 subject）**

参考 subject 访问判定：现有 `accessibleSubjectIds`（crews.ts:607）走 service-role，但 RLS 要用 SQL 判定。用本人 `user_account` subject + `group_subject_members` 两条路径。machine 只挂本人 `user_account` subject（不挂群），所以 RLS 用 `subject_id` 属于 `auth.uid()` 的 user_account 即可：

```sql
set search_path = pendingbot, public;

create table pendingbot.machine (
  id              uuid primary key default gen_random_uuid(),
  subject_id      uuid not null references pendingbot.subjects(id) on delete cascade,
  kind            text not null check (kind in ('computer','fly')),
  device_id       text,                         -- 电脑安装级 id；fly 行为 null
  display_name    text not null,
  fly_machine_id  text,                          -- kind='fly' 专用
  status          text,                          -- online/offline 等，可空
  last_seen_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- 同一 subject 同一 device 只一行（computer）；fly 行 device_id null 不参与唯一
  constraint machine_kind_target_chk check (
    (kind = 'computer' and device_id is not null and fly_machine_id is null)
    or (kind = 'fly' and fly_machine_id is not null)
  )
);

create unique index machine_subject_device_uniq
  on pendingbot.machine (subject_id, device_id)
  where device_id is not null;

create index machine_subject_idx on pendingbot.machine (subject_id, created_at desc);

alter table pendingbot.machine enable row level security;

-- helper：该 subject 是否为调用者本人的 user_account
-- （沿用现有 subjects 表结构：subject_type='user_account' and user_id=auth.uid()）
create policy machine_self_read on pendingbot.machine for select
  using (exists (
    select 1 from pendingbot.subjects s
    where s.id = machine.subject_id
      and s.subject_type = 'user_account'
      and s.user_id = auth.uid()
  ));

create policy machine_self_insert on pendingbot.machine for insert
  with check (exists (
    select 1 from pendingbot.subjects s
    where s.id = machine.subject_id
      and s.subject_type = 'user_account'
      and s.user_id = auth.uid()
  ));

create policy machine_self_update on pendingbot.machine for update
  using (exists (
    select 1 from pendingbot.subjects s
    where s.id = machine.subject_id
      and s.subject_type = 'user_account'
      and s.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from pendingbot.subjects s
    where s.id = machine.subject_id
      and s.subject_type = 'user_account'
      and s.user_id = auth.uid()
  ));

create policy machine_self_delete on pendingbot.machine for delete
  using (exists (
    select 1 from pendingbot.subjects s
    where s.id = machine.subject_id
      and s.subject_type = 'user_account'
      and s.user_id = auth.uid()
  ));

grant select, insert, update, delete on table pendingbot.machine to authenticated;
grant select, insert, update, delete on table pendingbot.machine to service_role;
```

> 实现期核对：`pendingbot.subjects` 实际列名（`subject_type` / `user_id` / `status`）以 `apps/edge/src/db/schema.ts` 的 subjects Row 为准，若不同则同步改 policy。

- [ ] **Step 3: 加 upsert-self RPC（service-role 写，给 edge 调用）**

```sql
create or replace function pendingbot.upsert_self_machine(
  p_subject_id uuid,
  p_device_id text,
  p_display_name text
) returns uuid
language plpgsql
security definer
set search_path = pendingbot, public
as $$
declare v_id uuid;
begin
  insert into pendingbot.machine (subject_id, kind, device_id, display_name, last_seen_at, status, updated_at)
  values (p_subject_id, 'computer', p_device_id, p_display_name, now(), 'online', now())
  on conflict (subject_id, device_id) where device_id is not null
  do update set display_name = excluded.display_name,
                last_seen_at = now(), status = 'online', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function pendingbot.upsert_self_machine(uuid, text, text) to service_role;
```

- [ ] **Step 4: 不在本任务 push**（迁移在 Task 4 一次性 push）。语法自检：肉眼核 + 留到 Task 4 的 `db push` 验证。

---

### Task 2: crew 加 machine_id + 改 RPC 派生 runtime_location

**Files:**
- Create: `supabase/migrations/<ts>_crew_machine_id.sql`
- 参考（只读）：`supabase/migrations/20260529014827_crew_rpcs_accept_actor.sql`（RPC 现状）、`20260528105149_crew_v2_schema_extensions.sql`（约束）

- [ ] **Step 1: 生成迁移** `supabase migration new crew_machine_id`

- [ ] **Step 2: 加列 + drop 低耦合列与约束**

```sql
set search_path = pendingbot, public;

alter table pendingbot.temporary_group_meta
  add column if not exists machine_id uuid references pendingbot.machine(id) on delete set null;

create index if not exists tgm_machine_idx
  on pendingbot.temporary_group_meta (machine_id);

-- 联动约束牵涉将被删的列，先删约束再删列
alter table pendingbot.temporary_group_meta
  drop constraint if exists temporary_group_meta_runtime_target_chk;

alter table pendingbot.temporary_group_meta
  drop column if exists peer_device_id,
  drop column if exists fly_machine_id;
```

> runtime_location 列**保留**（多处读取），由 RPC 写入时派生。cloud_machine_id 列原样保留（不在本次范围）。

- [ ] **Step 3: 改 `create_crew_with_captain` RPC：去 p_peer_device_id/p_fly_machine_id，加 p_machine_id，派生 runtime_location 并写 machine_id**

先 Read `20260529014827_crew_rpcs_accept_actor.sql` 拿到 RPC 完整现状签名与函数体，再 `create or replace` 整体重写。派生规则：
- `p_machine_id is null` → `runtime_location = 'local_host'`
- machine.kind='fly' → `'fly_machine'`
- machine.kind='computer' 且 device_id = 当前设备 → `'local_host'`；否则 `'peer_device'`（RPC 内拿不到"当前设备"，所以 computer 一律按调用方传入的 `p_runtime_location` 兜底，或简化：kind='computer'→'local_host'，kind='fly'→'fly_machine'。peer 的区分留给客户端展示层）。

**采用简化派生（RPC 内）**：`runtime_location := case when p_machine_id is null then 'local_host' when (select kind from pendingbot.machine where id = p_machine_id) = 'fly' then 'fly_machine' else 'local_host' end`，并 `set machine_id = p_machine_id`。peer 与本机的展示区分由客户端按 machine.device_id 是否等于本机判断（见 Task 9/13）。

完整 `create or replace function ...`：保持除签名外的全部既有逻辑（captain 生成、成员插入、root/parent 设置等），仅：①参数表去掉 `p_peer_device_id`、`p_fly_machine_id`，加 `p_machine_id uuid default null`；②insert/update `temporary_group_meta` 时去掉 peer/fly 列，加 `machine_id = p_machine_id`，`runtime_location = <派生>`。`grant execute` 同步更新签名。

- [ ] **Step 4: 留到 Task 4 push。**

---

### Task 3: drop tag 列

**Files:**
- Create: `supabase/migrations/<ts>_crew_drop_tag.sql`

- [ ] **Step 1: 生成迁移** `supabase migration new crew_drop_tag`

- [ ] **Step 2: 若 RPC 写 tag，先从 RPC 去掉再 drop 列**

```sql
set search_path = pendingbot, public;
-- 若 create_crew_with_captain 有 p_tag 参数/写 tag，在 Task 2 的 RPC 重写里一并去掉 tag。
-- 本迁移只 drop 列：
alter table pendingbot.temporary_group_meta
  drop column if exists tag;
```

> 执行顺序：本迁移时间戳必须晚于 Task 2（RPC 已不再引用 tag）。Read Task 2 产出的 RPC，确认无 `tag` 残留再 drop。

---

### Task 4: 应用三个迁移 + schema regen + typecheck + commit

- [ ] **Step 1: push（主 worktree）** `supabase db push --linked`，预期三个迁移全 apply 无错。
- [ ] **Step 2: regen schema** `bun --filter='@pendingbot/edge' run types:db`（注意脚本内含 `2>/dev/null`，别裸调 supabase gen）。
- [ ] **Step 3: typecheck** `bun --filter='@pendingbot/edge' run typecheck` — 预期此处会因 crews.ts 仍引用旧列/tag 报错；本 task 只需确认 schema.ts 已含 machine 表 + machine_id、无 tag/peer_device_id/fly_machine_id。crews.ts 的修复在 Task 6。
- [ ] **Step 4: commit** `git add supabase/migrations/<3 files> apps/edge/src/db/schema.ts && git commit -m "db: machine 表 + crew.machine_id 收口 runtime 三件套 + drop tag"`（schema 与迁移同提，过 lefthook schema-regen-check）。

---

## Phase 1 — Edge

### Task 5: machine 注册/列表端点

**Files:**
- Create: `apps/edge/src/routes/machines.ts`
- Create: `apps/edge/src/routes/machines.test.ts`
- Modify: 路由挂载处（grep `crewsRoutes` 在 `apps/edge/src/index.ts` 的挂载行，照样 `app.route('/v1/machines', machinesRoutes)`）

- [ ] **Step 1: 写端点**（`requireSession` 中间件；用 `accessibleSubjectIds` 或直接查本人 user_account subject）

```ts
import { Hono } from 'hono';
import { z } from 'zod';
import { serviceClient } from '../lib/supabase'; // 实现期核对实际导出
import { jsonError } from '../lib/http-error';

export const machinesRoutes = new Hono</* Env 泛型照 crews.ts */>();

// GET /v1/machines — 列出本账号的机器
machinesRoutes.get('/', async (c) => {
  const userId = c.var.userId;
  const supa = serviceClient(c.env);
  const { data: subj } = await supa.from('subjects').select('id')
    .eq('subject_type', 'user_account').eq('user_id', userId).eq('status', 'active').maybeSingle();
  if (!subj?.id) return c.json({ machines: [] });
  const { data, error } = await supa.from('machine')
    .select('id, kind, device_id, display_name, fly_machine_id, status, last_seen_at')
    .eq('subject_id', subj.id).order('created_at', { ascending: true });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ machines: (data ?? []).map((m) => ({
    id: m.id, kind: m.kind, deviceId: m.device_id, displayName: m.display_name,
    flyMachineId: m.fly_machine_id, status: m.status, lastSeenAt: m.last_seen_at,
  })) });
});

const RegisterBody = z.object({
  deviceId: z.string().trim().min(1).max(200),
  displayName: z.string().trim().min(1).max(120),
});

// POST /v1/machines/register-self — 当前设备 upsert 自己为 computer 机器
machinesRoutes.post('/register-self', async (c) => {
  const userId = c.var.userId;
  const parsed = RegisterBody.safeParse(await c.req.json());
  if (!parsed.success) return jsonError(c, 400, 'invalid_body', { detail: parsed.error.flatten() });
  const supa = serviceClient(c.env);
  const { data: subj } = await supa.from('subjects').select('id')
    .eq('subject_type', 'user_account').eq('user_id', userId).eq('status', 'active').maybeSingle();
  if (!subj?.id) return jsonError(c, 404, 'not_found', { message: 'no user_account subject' });
  const { data, error } = await supa.rpc('upsert_self_machine', {
    p_subject_id: subj.id, p_device_id: parsed.data.deviceId, p_display_name: parsed.data.displayName,
  });
  if (error) return jsonError(c, 500, 'database_error', { detail: error.message });
  return c.json({ machineId: data as string });
});
```

> 实现期核对：`serviceClient`/`Env` 泛型/路由挂载方式以 `crews.ts` + `index.ts` 现有写法为准，照抄其 import 与 `new Hono<{Bindings: Env; Variables: ...}>()` 形态。`ApiErrorCode` 若无 `not_found` 用既有近义 code。

- [ ] **Step 2: vitest**（照 `apps/edge/tests/*.test.ts` 或 `src/lib/*.test.ts` 现有 mock 风格）：覆盖 GET 空列表、register-self 400（缺字段）、register-self 成功返回 machineId。
- [ ] **Step 3: run** `cd apps/edge && ./node_modules/.bin/vitest run src/routes/machines.test.ts` 预期 PASS。
- [ ] **Step 4: commit** `git add apps/edge/src/routes/machines.ts apps/edge/src/routes/machines.test.ts apps/edge/src/index.ts && git commit -m "edge: machine 注册/列表端点"`。

---

### Task 6: crews.ts 接 machineId、去 runtime 三件套 + tag

**Files:**
- Modify: `apps/edge/src/routes/crews.ts`（create handler 84-192、list 292、detail 352/434、relay 若有）

- [ ] **Step 1: 改 zod + 校验**（删 RuntimeLocation/peerDeviceId/flyMachineId/tag，加 machineId）

```ts
const CreateCrewBody = z.object({
  responsibleSubjectId: z.string().uuid(),
  title: z.string().trim().max(80).optional(),       // 可选/自动 → 允许空
  workingDirectory: z.string().trim().max(2048).optional(),
  machineId: z.string().uuid().optional(),           // null/缺省 = 本机
  captain: CaptainBody,
});
```
删除 lines 117-125 的 peer/fly 校验块。

- [ ] **Step 2: 改 RPC 调用**：删 `p_runtime_location`/`p_peer_device_id`/`p_fly_machine_id`/`p_tag`，加 `p_machine_id: parsed.machineId ?? undefined`；title 传 `parsed.title?.trim() || null`（空 → null，留给 captain 总结）。
- [ ] **Step 3: 改 select**：lines 292、352、434 的 select 去掉 `tag`；read-back/list/detail 的响应映射去掉 `tag` 字段（保留 `runtime_location` 映射不变）。
- [ ] **Step 4: typecheck** `bun --filter='@pendingbot/edge' run typecheck` 预期 PASS（crews.ts 不再引用已删列）。
- [ ] **Step 5: 跑相关 test** `cd apps/edge && ./node_modules/.bin/vitest run`（含 session-world-model.test.ts，确认 runtime_location 仍下发）。
- [ ] **Step 6: commit** `git add apps/edge/src/routes/crews.ts && git commit -m "edge: crew 创建接 machineId、去 runtime 三件套 + tag"`。

---

## Phase 2 — Mac / iPad（apps/pendingcrew）

### Task 7: Machine 模型 + 稳定 device_id

**Files:**
- Create: `apps/pendingcrew/Sources/Models/Machine.swift`
- Create: `apps/pendingcrew/Sources/Stores/DeviceIdentity.swift`

- [ ] **Step 1: Machine 模型**

```swift
import Foundation

struct Machine: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let kind: String              // "computer" | "fly"
    let deviceId: String?
    let displayName: String
    let flyMachineId: String?
    let status: String?
    let lastSeenAt: String?

    enum Kind: String { case computer, fly }
    var kindEnum: Kind? { Kind(rawValue: kind) }

    func displayIcon(isLocal: Bool) -> String {
        if kindEnum == .fly { return "cloud" }
        return isLocal ? "desktopcomputer" : "personalhotspot"
    }
}
```

- [ ] **Step 2: DeviceIdentity — 安装级稳定 UUID（UserDefaults 持久化）**

```swift
import Foundation

enum DeviceIdentity {
    private static let key = "pendingcrew.deviceId"
    static var current: String {
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString.lowercased()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
    static var displayName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "PendingCrew Device"
        #endif
    }
}
```

- [ ] **Step 3: build 验证留到 Task 13。**（独立文件，先不单独编译。）

---

### Task 8: 去 tag + 加 machineId（models + request）

**Files:**
- Modify: `apps/pendingcrew/Sources/Models/CrewSummary.swift`（去 tag）
- Modify: `apps/pendingcrew/Sources/Models/CrewDetail.swift`（CrewBody 去 tag）
- Modify: `apps/pendingcrew/Sources/Services/CrewModels.swift`（CreateCrewRequest 去 tag/runtime 三件套、加 machineId、改 `localHost` 工厂）
- Modify: `apps/pendingcrew/Sources/Stores/LocalCrewStore.swift`（LocalCrew 去 tag、createCrew 去 tag）

- [ ] **Step 1: CrewSummary** — 删 `let tag: String?` + memberwise init 参数 + decoder 的 `decodeIfPresent(tag)`。`RuntimeLocation` 枚举与 `runtimeLocation` 字段**保留**（edge 仍下发派生值）。
- [ ] **Step 2: CrewDetail.CrewBody** — 删 `let tag: String?` + decoder。
- [ ] **Step 3: CreateCrewRequest** — 改为：

```swift
struct CreateCrewRequest: Encodable {
    let responsibleSubjectId: String
    let title: String?            // nil/空 = 自动(留给 captain)
    let machineId: String?        // nil = 本机
    let captain: Captain
    // Captain 枚举原样保留

    static func make(
        responsibleSubjectId: String,
        title: String?,
        machineId: String?,
        captain: Captain
    ) -> CreateCrewRequest {
        CreateCrewRequest(responsibleSubjectId: responsibleSubjectId,
                          title: title, machineId: machineId, captain: captain)
    }
}
```
删 `runtimeLocation`/`workingDirectory`/`tag`/`peerDeviceId`/`flyMachineId` 字段与 `localHost` 工厂。

> **workingDirectory 去哪了？** 本地 crew 的工作目录是**纯本地**概念（edge 不需要它来跑——runner 在本机起）。工作目录只存进 `LocalCrewStore`（Task 11 由表单直接写本地，不再走 CreateCrewRequest 上送）。edge 端 crew 仍有 working_directory 列但本地 crew 不依赖它；若 EdgeBackend.createCrew 需要可后续补。**核对**：确认 LocalBackend.createCrew 才是 Mac 默认路径（BYOK/本地），workingDirectory 写本地 store 即可。

- [ ] **Step 4: LocalCrew + createCrew** — LocalCrew 删 `tag`；`createCrew` 不再读 `request.tag`/`request.runtimeLocation`/`request.workingDirectory`。改为：`createCrew(_ request:, workingDirectory: String?, machineId: String?)` —— 即给 LocalCrewStore.createCrew 增加 workingDirectory/machineId 形参（由表单传入），runtimeLocation 本地恒存 `"local_host"`（或按 machineId 派生）。LocalCrew 增 `machineId: String?` 字段（decoder 带 decodeIfPresent 兜底）。

> 这一步会改动 `createCrew` 签名 → 牵动 `PendingCrewBackend` 协议（Task 9）与所有调用点（CrewStore、relay）。在 Task 9 一并改齐再编译。

---

### Task 9: backend 协议 — listMachines / registerSelfMachine + createCrew 新签名

**Files:**
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift`（协议 + Local/Edge 两实现）
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewAPI.swift`（machine 端点客户端 + createCrew body）
- Modify: `apps/pendingcrew/Sources/Stores/CrewStore.swift`（machines 缓存 + createCrew 转发 + 登录 register）

- [ ] **Step 1: 协议加方法**

```swift
func listMachines() async throws -> [Machine]
func registerSelfMachine() async throws -> String   // 返回 machineId
// createCrew 签名调整：把工作目录/machineId 显式带上（本地路径需要 wd）
func createCrew(_ request: CreateCrewRequest, workingDirectory: String?) async throws -> CreateCrewResponse
```

- [ ] **Step 2: EdgeBackend 实现** — `listMachines` 调 `GET /v1/machines`；`registerSelfMachine` 调 `POST /v1/machines/register-self`（body: deviceId=DeviceIdentity.current, displayName=DeviceIdentity.displayName）；`createCrew` 透传（workingDirectory 对 edge 暂忽略或写 working_directory，本地路径为主）。

- [ ] **Step 3: LocalBackend 实现** — `listMachines` 返回单元素 `[本机]`（合成一个 Machine：id 用 device_id、kind=computer、isLocal）；`registerSelfMachine` no-op 返回本地 id；`createCrew` 调 `LocalCrewStore.createCrew(request, workingDirectory:, machineId:)`。

- [ ] **Step 4: PendingCrewAPI** — 加 `listMachines()`/`registerSelfMachine()`（照现有 `get`/`post` helper）：

```swift
func listMachines() async throws -> [Machine] {
    struct Resp: Decodable { let machines: [Machine] }
    let r: Resp = try await get(path: "v1/machines")
    return r.machines
}
func registerSelfMachine() async throws -> String {
    struct Body: Encodable { let deviceId: String; let displayName: String }
    struct Resp: Decodable { let machineId: String }
    let r: Resp = try await post(path: "v1/machines/register-self",
        body: Body(deviceId: DeviceIdentity.current, displayName: DeviceIdentity.displayName))
    return r.machineId
}
```
createCrew 的 body 编码：CreateCrewRequest 现已是 `{responsibleSubjectId, title?, machineId?, captain}`，原样 encode。

- [ ] **Step 5: CrewStore** — 加 `@Published var machines: [Machine] = []` + `func refreshMachines()`；`createCrew(request, workingDirectory:)` 转发 backend；登录成功后（找到注入点：saveDeviceGrantToken 之后 / 进入主界面时）调 `registerSelfMachine()` then `refreshMachines()`。

- [ ] **Step 6: 修所有 createCrew 调用点**：relay（CrewDetailInspector connectToPendingBot）、CreateCrewSheet.submit（Task 11 重写）。relay 处改 `.make(responsibleSubjectId:title:machineId:nil,captain:)` + `workingDirectory: nil`，去 tag。

- [ ] **Step 7: 编译留到 Task 13。**

---

### Task 10: 登录后注册本机

**Files:**
- Modify: 登录完成注入点（`apps/pendingcrew/Sources/Views/LoginView.swift` 的 approved 分支后，或 `AppModel` 进入已登录态处）

- [ ] **Step 1:** 在拿到 device-grant、确立已登录态后，`Task { try? await crewStore.registerSelfMachine(); await crewStore.refreshMachines() }`。幂等（RPC upsert），重复登录安全。
- [ ] **Step 2: 编译留到 Task 13。**

---

### Task 11: CreateCrewSheet 重构（核心）

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CreateCrewSheet.swift`（整体重写表单）

- [ ] **Step 1: @State 收敛**

```swift
@State private var titleMode: TitleMode = .auto         // .auto | .manual
@State private var title: String = ""
@State private var selectedMachineId: String?            // nil = 本机
@State private var workingDirMode: WorkingDirMode = .crewGround   // .manual | .lastUsed | .crewGround
@State private var manualWorkingDir: URL?
@State private var creating = false
@State private var localError: String?

enum TitleMode { case auto, manual }
enum WorkingDirMode { case manual, lastUsed, crewGround }
```
删 subject/runtime/tag/captain 相关 state。

- [ ] **Step 2: 表单字段**
  - 标题：Picker/Toggle 选 自动 vs 手动；手动时显 TextField。
  - machine：`if crewStore.machines.count > 1 { Picker(selection: $selectedMachineId) { 本机 + 其它机器 } }`（≤1 台不显示）。本机用 `displayName + 在线点`。
  - 工作目录：三选一 Picker（手动/用上次/CrewGround）；手动时显"选择…"按钮 + 已选路径；"用上次"显示 `lastWorkingDirectory`（无则禁用该选项）；CrewGround 显示一行说明"将在 ~/CrewGround/<随机地名> 新建"。
  - 删 tag、captain section。

- [ ] **Step 3: submit()**

```swift
private func submit() async {
    creating = true; defer { creating = false }; localError = nil
    do {
        let subjectId = try await resolveResponsibleSubjectId()   // 本人 user_account subject
        let resolvedDir = try resolveWorkingDirectory()            // 见 Task 12
        let titleValue: String? = (titleMode == .manual)
            ? { let t = title.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }()
            : nil
        let request = CreateCrewRequest.make(
            responsibleSubjectId: subjectId, title: titleValue,
            machineId: selectedMachineId, captain: .systemGenerated(templateName: nil))
        _ = try await crewStore.createCrew(request, workingDirectory: resolvedDir.path)
        UserDefaults.standard.set(resolvedDir.path, forKey: "pendingcrew.lastWorkingDirectory")
        dismiss()
    } catch { localError = error.localizedDescription }
}
```
`resolveResponsibleSubjectId`：登录态取 `crewStore.subjects.first`（或本人 user_account）；本地态用现有本地 subject 常量（核对 LocalBackend 当前怎么填 responsibleSubjectId，沿用）。

- [ ] **Step 4: canSubmit** — 仅当工作目录可解析（手动模式须已选目录；其余模式恒可）。标题自动允许空。

- [ ] **Step 5: 子 crew 预设父**（配合 Task 14）：CreateCrewSheet 加可选 `parentCrewId: String?` 入参；非空时建完调 `crewStore.attachParent(crewId: resp.crewId, parentCrewId:)`。

---

### Task 12: CrewGround 目录 + 上次目录 + 离线地名

**Files:**
- Create: `apps/pendingcrew/Sources/Resources/crewground_places.txt`（地名列表，每行一个）
- Modify: `apps/pendingcrew/project.yml`（确保 Resources 目录进 bundle；改后跑 `xcodegen`）
- Modify: `CreateCrewSheet.swift`（resolveWorkingDirectory + place-name 抽取）

> **决策注（需在 handoff 向用户确认）**：用户要"全世界的地名"，但现有 `place_names` corpus 是中文地名。本计划默认**新捆一份世界城市名**（英文/拼音，几百条足够去重）到 `crewground_places.txt`，不复用中文 corpus，也不依赖服务端（CrewGround 在未登录也要能用）。若用户更想复用现有中文 corpus，则改为：登录时调 `GET /v1/groups/random-name`，未登录回退本地列表。

- [ ] **Step 1: 捆地名列表** — `crewground_places.txt` 放一批世界地名（如 `Lisbon`/`Kyoto`/`Nairobi`/`Reykjavik`/...，200+ 条）。

- [ ] **Step 2: resolveWorkingDirectory()**

```swift
private func resolveWorkingDirectory() throws -> URL {
    switch workingDirMode {
    case .manual:
        guard let d = manualWorkingDir else { throw CreateCrewError.noDirectory }
        return d
    case .lastUsed:
        guard let p = UserDefaults.standard.string(forKey: "pendingcrew.lastWorkingDirectory")
        else { throw CreateCrewError.noLastDirectory }
        return URL(fileURLWithPath: p)
    case .crewGround:
        return try makeCrewGroundDirectory()
    }
}

private func makeCrewGroundDirectory() throws -> URL {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent("CrewGround", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
    let names = PlaceNames.all.shuffled()
    let pick = names.first { !existing.contains($0) } ?? "Crew-\(UUID().uuidString.prefix(8))"
    let dir = root.appendingPathComponent(pick, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

- [ ] **Step 3: PlaceNames loader**（照 iOS `NameCorpus` 风格，从 bundle 读 txt）

```swift
enum PlaceNames {
    static let all: [String] = {
        guard let url = Bundle.main.url(forResource: "crewground_places", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return ["Atlantis"] }
        return raw.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }()
}
```

- [ ] **Step 4: xcodegen + 编译留到 Task 13。**

---

### Task 13: 去 tag 展示 + 编译 Mac/iPad

**Files:**
- Modify: `apps/pendingcrew/Sources/Views/CrewListView.swift`（subtitleText 去 tag）
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewDetailInspector.swift`（去 tag Label + relay 去 tag）

- [ ] **Step 1: CrewListView.subtitleText** → 只 `Text(location)`（location = runtimeLocationKind?.shortLabel ?? runtimeLocation；可进一步用 machine displayName，本步先保留 location）。
- [ ] **Step 2: CrewDetailInspector** — 删 tag `Label`（56-65 区块的 tag 分支）；relay `connectToPendingBot` 去 `let tag` 与 `tag:` 实参，createCrew 改新工厂。
- [ ] **Step 3: xcodegen**（若改了 project.yml）：`cd apps/pendingcrew && xcodegen`。
- [ ] **Step 4: 编译 macOS** `cd apps/pendingcrew && xcodebuild -project PendingBot.xcodeproj -scheme PendingBot -destination 'platform=macOS' build` 预期 BUILD SUCCEEDED。
- [ ] **Step 5: 编译 iPad** `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` 预期 SUCCEEDED。
- [ ] **Step 6: commit** `git add apps/pendingcrew/Sources apps/pendingcrew/project.yml && git commit -m "pendingcrew: machine 选择 + 新建表单精简 + CrewGround + 去 tag"`（可按 Task 7-13 拆成多个小 commit，建议每个 Task 结束即 commit）。

---

### Task 14: crew 内"新建子 crew"入口

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewDetailInspector.swift`（或 CrewDAGTreeView）

> 父 crew 的 attach/detach UI（`parentDAGSection`）已存在 → "设置里指定父 crew" 已满足。本任务只补"进了 crew 后新建子 crew"。

- [ ] **Step 1:** 在 inspector 顶部/工具栏加 "＋ 新建子 crew" 按钮，`sheet { CreateCrewSheet(parentCrewId: detail.crew.id) }`。建完 CreateCrewSheet.submit 会 attachParent（Task 11 Step 5）。
- [ ] **Step 2: 编译验证** 同 Task 13 Step 4。
- [ ] **Step 3: commit** `git commit -m "pendingcrew: crew 内新建子 crew 入口"`。

---

## Phase 3 — 实测 + 账本

### Task 15: 模拟器/真机实测 + 账本

- [ ] **Step 1: 装进模拟器实测**（用户偏好：不止编译过）。装 Mac/iPad 构建产物，跑新建 crew：①标题自动 → crew 列表显示"未命名"占位；②工作目录默认 CrewGround → `~/CrewGround/<地名>` 真被创建；③切"手动"/"用上次"可用；④登录态机器>1 时 machine 选择出现，未登录不出现；⑤无 tag 字段；⑥crew 内"新建子 crew" → 新 crew 挂到当前 crew 之下（DAG 树体现）。截图留证。
- [ ] **Step 2: 全量验证** edge typecheck + vitest 全绿；Mac + iPad build 绿。
- [ ] **Step 3: 账本** — `docs/tech-debt.md` 记两条：①`runtime_location` 现为派生镜像列（machine_id 才是事实源），后续可评估彻底退役该列 + RuntimeLocation 枚举；②CrewGround 地名 corpus 与服务端 `place_names`（中文）分离，若要统一需对齐。`docs/progress.md` 顶部"最近对账"日期 + 本 feature 状态。更新对应 Task 系统条目。
- [ ] **Step 4: commit** `git commit -m "docs: machine/新建流程 账本对账 + tech-debt 两条"`。

---

## Self-Review（写完已自查）

- **Spec 覆盖**：machine 表(Task1)/RLS 限账号(Task1)/未登录不选(Task9 LocalBackend 返单机+Task11 count>1 才显)/crew machine_id 收口(Task2)/标题可选自动(Task6,11)/砍 subject(Task11 默认本人)/砍 runtime(Task2,6,11)/工作目录三选+CrewGround(Task11,12)/上次目录(Task11,12)/删 tag(Task3,6,8,13)/captain 免配置(Task11 写死 systemGenerated)/父 crew 指定(已存在)/建子 crew(Task14)/iPad 同步(Task9,10)/离线兜底(Task12) — 均有任务。
- **Placeholder**：无 TBD；几处"实现期核对"是有意核查点（subjects 列名、serviceClient 形态、LocalBackend subject 来源），非占位。
- **类型一致**：CreateCrewRequest 统一为 `{responsibleSubjectId,title?,machineId?,captain}`，工厂统一为 `.make(...)`；createCrew 统一新签名 `(request, workingDirectory:)`；Machine 模型字段贯穿 edge JSON ↔ Swift Decodable 一致。
