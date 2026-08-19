-- 短链服务 link.pendingname.com 的唯一真值源。
--
-- 运营者在 board 手动建链接;终端用户不参与创建,所以没有滥用/举报/黑名单层。
-- 现有邀请链接(/b/ /g/ /c/ /d/)不迁进来,见
-- docs/superpowers/specs/2026-08-08-short-links-design.md。

create table pendingbot.short_links (
  -- 小写短码。写入前由 edge 侧 normalizeSlug 转小写;这里的 check 与
  -- apps/edge/src/lib/short-link-slug.ts 的 SLUG_RE 必须保持一致。
  slug text primary key
    check (slug ~ '^[a-z0-9_-]{2,32}$'),

  -- 跳转目标。强制 https:// 前缀,挡住 javascript: / data: 之类的 scheme 注入。
  target_url text not null
    check (target_url ~ '^https://'),

  -- 运营备注,只在 board 显示。
  note text,

  -- 软开关:关掉即刻失效,但保留行与统计。
  enabled boolean not null default true,

  -- 可空 = 永不过期。
  expires_at timestamptz,

  -- 冗余计数,让 board 列表不查 PostHog 就能显示热度。
  click_count bigint not null default 0,
  last_clicked_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 保留短码。前一组是 worker 自己的路径段;后一组是给现有邀请链接体系留的门
-- (本期不迁,但一旦被占用就永远迁不了)。与 short-link-slug.ts 的
-- RESERVED_SLUGS 保持一致。
alter table pendingbot.short_links
  add constraint short_links_slug_not_reserved
  check (slug not in (
    'board', 'v1', 'health', 'api', 'admin', 'www', 'static', 'assets',
    'c', 'b', 'g', 'd', 's', 'u', 'r'
  ));

-- RLS 锁死:无 policy = 默认拒绝 anon/authenticated。跳转路径与 board 都走
-- service role(绕过 RLS),终端用户的 JWT 一律读不到这张表。
alter table pendingbot.short_links enable row level security;

-- updated_at 自动推进。
--
-- 为什么加触发器:board CRUD 工厂(lib/board-resource.ts)不给写入打
-- updated_at 戳,靠列默认值的话该列只在 insert 时正确、patch 后就开始说谎。
-- 与其要求每个写入方记得带上,不如在表这层钉死。
create or replace function pendingbot.tg_short_links_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

alter function pendingbot.tg_short_links_touch_updated_at() owner to postgres;

drop trigger if exists short_links_touch_updated_at_trg on pendingbot.short_links;
create trigger short_links_touch_updated_at_trg
  before update on pendingbot.short_links
  for each row execute function pendingbot.tg_short_links_touch_updated_at();

-- board 列表默认按创建时间倒序。
create index short_links_created_at_idx
  on pendingbot.short_links (created_at desc);
