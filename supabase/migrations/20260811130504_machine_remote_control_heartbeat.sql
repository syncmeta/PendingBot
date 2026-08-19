-- 遥控 Step 1「机器在线」（spec docs/superpowers/specs/2026-08-11-machine-remote-control-design.md §2.2 / §2.3）
--
-- 两列，都挂在既有的 pendingbot.machine 上：
--   remote_control_enabled —— 机器总闸。默认 false，且**只能在那台机器自己的设置里预先开**
--       （§2.2 已定：不做「第一次被遥控时弹确认」，因为人不在那台机器跟前正是遥控要解决的场景）。
--   state_digest           —— 心跳带上来的 L1+L2+L3 状态摘要。遥控器拉列表时比对，
--       不一致就发 resync（§2.3）。总闸关着时机器不上报摘要，此列保持 null。
--
-- 在线判定（§2.4 的 online/stale/offline 三档）**不落库**：它是 last_seen_at 的纯函数，
-- 由 edge 在读端点上现算（apps/edge/src/lib/machine-presence.ts）。存一个会过期的
-- 状态列就得跑定时任务去刷它，那是给自己造第二个真源。
--
-- upsert_self_machine 的 on-conflict 分支没碰这两列，所以重复登录 / 重新注册
-- 不会把已经打开的总闸悄悄关回去。
set search_path = pendingbot, public;

alter table pendingbot.machine
  add column if not exists remote_control_enabled boolean not null default false,
  add column if not exists state_digest text;

comment on column pendingbot.machine.remote_control_enabled is
  '机器总闸：这台机器允不允许被本账号的其它设备遥控。默认 false，在那台机器的设置里预先开一次，随时可关。';

comment on column pendingbot.machine.state_digest is
  '机器最近一次心跳上报的状态摘要（crew 目录 + session 状态 + 待办的稳定 hash）。总闸关时为 null。';
