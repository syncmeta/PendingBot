-- 遥控 Step 2「crew 目录上报」（spec docs/superpowers/specs/2026-08-11-machine-remote-control-design.md §2.1 L1 / §2.2 / §2.3）
--
-- 两块：
--   1. pendingbot.machine_crew_index —— L1「crew 目录」的服务端投影。手机上第一次
--      能看见「那台 Mac 上有哪些 crew」，看的就是这张表。
--   2. pendingbot.machine 上四列退避账 —— 让 machine-resync.ts 那套指数退避真的
--      有地方存状态。**这是 Step 1 留下的接线缺口**：退避策略当时写好了、单测绿了，
--      但没有调用点也没有持久化位置，等于「装了放大器没装刹车」。
--
-- ── 投影里放什么、不放什么（§2.1 的边界，不是随手取舍）─────────────────────
-- 放：crew id / 标题 / 父边 / 有没有工作目录 / session 计数 / 成员计数 / attention 黄点。
-- **不放**：工作目录**绝对路径**（只留一个布尔位 has_working_directory）、白板正文、
-- 终端字节流、本机 agent 配置。这些是「永远不出门」的那一档，连进投影都不该进。
--
-- ── 为什么有 revoked_at 而不是 delete ────────────────────────────────────
-- §2.2：关掉某个 crew 的遥控开关 = 停止上报 + **在 edge 打墓碑**。遥控器上要显示
-- 「已停止共享」，不是让它静默消失 —— 用户看到东西凭空不见会以为数据丢了。
-- 所以关闸走 revoked_at 打时间戳，行还在，读端点照常返回并标出来。
--
-- ── exposure 为什么只有 directory / full 两个值 ─────────────────────────
-- 三档是 off | directory | full，但 **off 的 crew 根本不上报**（连存在都不出门，
-- §2.1 末尾那条）。所以能落到这张表里的只有另外两档，check 约束就照这个写死 ——
-- 哪天有 off 行进来，那是上报端漏了过滤，应该当场红而不是静静躺在库里。

set search_path = pendingbot, public;

-- ─────────────────────────────────────────────────────────────
-- 1. L1 投影表
-- ─────────────────────────────────────────────────────────────

create table if not exists pendingbot.machine_crew_index (
  id                    uuid primary key default gen_random_uuid(),
  machine_id            uuid not null references pendingbot.machine(id) on delete cascade,
  -- 冗余存一份 subject_id：读端点按账号过滤时不必每次 join machine，
  -- RLS 策略也能只看本表一行就判完。
  subject_id            uuid not null references pendingbot.subjects(id) on delete cascade,
  -- 本机 LocalCrew.id。**不是** edge 的 crew conversation id —— 本地 crew 的家在
  -- 那台机器上，edge 这边只是投影，不给它另发一个 id（发了就要维护映射）。
  local_crew_id         text not null,
  title                 text not null,
  exposure              text not null check (exposure in ('directory','full')),
  parent_local_crew_ids text[] not null default '{}',
  -- 只报「有没有」，绝不报路径本身。
  has_working_directory boolean not null default false,
  session_count         int not null default 0,
  member_count          int not null default 0,
  attention             boolean not null default false,
  -- 通讯录号（`7`）。终身不变，遥控器上直接显示，不必再查一次。
  crew_number           int,
  -- 墓碑：非 null = 这个 crew 的遥控开关被关掉了，遥控器显示「已停止共享」。
  revoked_at            timestamptz,
  -- 机器侧时钟的最后更新时刻（LocalCrew.updatedAt）。只作展示与排障，
  -- **不**拿它做冲突比较 —— 本机是唯一真源，edge 这边没有第二个写者。
  local_updated_at      timestamptz,
  synced_at             timestamptz not null default now(),
  unique (machine_id, local_crew_id)
);

-- 读端点的主查询：某台机器当前还在共享的 crew。
create index if not exists machine_crew_index_machine_idx
  on pendingbot.machine_crew_index (machine_id, revoked_at, title);

-- 「这个账号所有机器的 crew」跨机器视图（遥控器首屏）。
create index if not exists machine_crew_index_subject_idx
  on pendingbot.machine_crew_index (subject_id, synced_at desc);

alter table pendingbot.machine_crew_index enable row level security;

create policy machine_crew_index_self_read on pendingbot.machine_crew_index for select
  using (exists (select 1 from pendingbot.subjects s
    where s.id = machine_crew_index.subject_id and s.kind = 'user_account' and s.user_id = auth.uid()));

create policy machine_crew_index_self_insert on pendingbot.machine_crew_index for insert
  with check (exists (select 1 from pendingbot.subjects s
    where s.id = machine_crew_index.subject_id and s.kind = 'user_account' and s.user_id = auth.uid()));

create policy machine_crew_index_self_update on pendingbot.machine_crew_index for update
  using (exists (select 1 from pendingbot.subjects s
    where s.id = machine_crew_index.subject_id and s.kind = 'user_account' and s.user_id = auth.uid()))
  with check (exists (select 1 from pendingbot.subjects s
    where s.id = machine_crew_index.subject_id and s.kind = 'user_account' and s.user_id = auth.uid()));

create policy machine_crew_index_self_delete on pendingbot.machine_crew_index for delete
  using (exists (select 1 from pendingbot.subjects s
    where s.id = machine_crew_index.subject_id and s.kind = 'user_account' and s.user_id = auth.uid()));

grant select, insert, update, delete on table pendingbot.machine_crew_index to authenticated;

grant select, insert, update, delete on table pendingbot.machine_crew_index to service_role;

comment on table pendingbot.machine_crew_index is
  '遥控 L1：某台机器上「哪些 crew 允许出门」的目录投影。本机是唯一真源，这里只是投影；revoked_at 是关闸墓碑（遥控器显示「已停止共享」而不是让它消失）。';

comment on column pendingbot.machine_crew_index.has_working_directory is
  '只报有没有工作目录，绝不报绝对路径（spec §2.1「永远不出门」）。';

-- ─────────────────────────────────────────────────────────────
-- 2. machine 上的退避账（Step 1 留下的接线缺口）
-- ─────────────────────────────────────────────────────────────
--
-- **为什么退避账挂在 machine 上而不是每个 viewer 各存一份**：三台遥控器同时看
-- 同一台机器，退避账要是各存各的，三份账各退各的，实际重报频率还是三倍 ——
-- 退避形同虚设。它必须是机器级的，这一列就是那个「机器级」。

alter table pendingbot.machine
  -- 机器最后一次**整份上报**时，它自己算出来的摘要。心跳带上来的 state_digest 是
  -- 「机器此刻的真实状态」，这一列是「投影对应的状态」。两者不一致 = 投影过期了。
  --
  -- 这样比对的好处：服务端**不必用 TypeScript 再实现一遍 Swift 那个 hash**。
  -- 重实现一遍就会有两套算法慢慢漂开，而漂开的表现恰好是「永远不一致 → 永远重报」，
  -- 正是退避要防的那件事。让机器自己跟自己比，算法只有一份。
  add column if not exists crew_index_digest text,
  add column if not exists resync_attempts int not null default 0,
  add column if not exists resync_last_at timestamptz,
  -- 退避到顶（连发 RESYNC_MAX_ATTEMPTS 次仍不一致）的时刻。非 null =
  -- **已停止自动 resync**，改由人来看。读端点把它下发，UI 上给这台机器挂个警告。
  add column if not exists resync_alarmed_at timestamptz;

comment on column pendingbot.machine.crew_index_digest is
  '最后一次 crew-index 整份上报所对应的状态摘要。与心跳带的 state_digest 比对，不一致说明投影过期，走 machine-resync.ts 的退避决策。';

comment on column pendingbot.machine.resync_alarmed_at is
  '退避到顶的时刻。非 null = 已停止自动 resync，等人处理（持续漂移的 bug，再重报也只是烧流量）。';
