-- 防 welcome-bonus 薅羊毛(#252):邮箱规范化 + 按规范化邮箱去重的赠送台账。
--
-- 病根:welcome bonus(35 PNC)的幂等键是 pnc_ledger(source='signup',
-- external_ref='signup:'+userId)—— **按 userId 去重**。一个人用
--   foo+1@gmail.com / foo+2@gmail.com / f.o.o@gmail.com
-- 注册出多个 auth.users(各自 userId),每个都领一份赠送。Gmail 把本地部分的
-- '+tag' 与 '.' 全部忽略路由到同一个真实信箱,所以这些其实是同一身份。
--
-- 修法:把"是否已发过 welcome"的判断从 per-userId 抬到 **per 规范化邮箱**。
--   1) normalize_email(text):lowercase;gmail/googlemail 去掉 local 部分
--      '+' 之后的全部 + 去掉所有 '.'。其它域只 lowercase + 去 plus-tag(各家
--      点号规则不一,只对 Gmail 这个最大的薅口做点号折叠,避免误伤正常多账号)。
--   2) welcome_bonus_grants(normalized_email PK):一封规范化邮箱只能占一次。
--      grantSignupBonus 发额度前先原子认领这张台账;认领冲突=已发过 → 跳过。
--
-- 为什么放 DB 而非纯 edge:与 reject_disposable_email 同理——Apple SIWA /
-- Google 登录首次注册不经过我们的 app 代码,直接落 auth.users。把规范化函数
-- 放 DB 既能给 edge 调,也能给未来的 DB 级钩子用,口径只有一处。
-- 注意:本迁移只建函数+台账;实际认领逻辑在 edge 的 grantSignupBonus 里(那是
-- 赠送唯一入口),不在 auth.users 触发器里发钱。

BEGIN;

-- ── 1) 规范化函数 ────────────────────────────────────────────────────
-- 纯函数,无数据访问;IMMUTABLE 便于将来建表达式索引。
CREATE OR REPLACE FUNCTION pendingbot.normalize_email(p_email text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
declare
  v_email  text;
  v_local  text;
  v_domain text;
begin
  if p_email is null then
    return null;
  end if;

  v_email := lower(btrim(p_email));
  if position('@' in v_email) = 0 then
    -- 不是合法邮箱形态,原样返回 lowercase(调用方自行决定怎么用)。
    return v_email;
  end if;

  -- 取最后一个 '@' 之后为域(Gmail 这类不允许 local 含 '@';split_part 取域足够)。
  v_domain := split_part(v_email, '@', 2);
  v_local  := left(v_email, length(v_email) - length(v_domain) - 1);

  -- '+tag' 子地址:对所有域都去掉(plus-addressing 是通用约定,RFC 5233)。
  -- 这是最常见、几乎无误伤的折叠口。
  if position('+' in v_local) > 0 then
    v_local := split_part(v_local, '+', 1);
  end if;

  -- 点号折叠只对 Gmail 系做:Gmail/Googlemail 忽略 local 部分的所有 '.';
  -- 其它提供商点号是有意义的,不能动。
  if v_domain in ('gmail.com', 'googlemail.com') then
    v_local  := replace(v_local, '.', '');
    -- googlemail.com 与 gmail.com 同信箱,统一到 gmail.com 收口。
    v_domain := 'gmail.com';
  end if;

  return v_local || '@' || v_domain;
end;
$$;

COMMENT ON FUNCTION pendingbot.normalize_email(text) IS
  '把邮箱折叠成规范身份:lowercase + 去 plus-tag;Gmail/Googlemail 另去点号并统一域。'
  '用于 welcome-bonus 按真实身份去重(见 #252)。';

-- ── 2) welcome-bonus 去重台账 ───────────────────────────────────────
-- 一封规范化邮箱占一行;占住即视为已发过赠送。grantSignupBonus 先 insert
-- 认领(冲突=已发过),再发额度。subject_id 仅留审计(谁先占的)。
CREATE TABLE IF NOT EXISTS pendingbot.welcome_bonus_grants (
  normalized_email text PRIMARY KEY,
  subject_id       uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  granted_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE pendingbot.welcome_bonus_grants IS
  'welcome bonus 按规范化邮箱去重:一封 normalized_email 只发一次。'
  '防 email +别名/点号薅羊毛(#252)。';

-- 服务端(edge service-role)写;不需要给 anon/authenticated 直接读写。
-- RLS 开启但不加策略 = 默认拒绝;service_role 绕过 RLS,edge 用它认领。
ALTER TABLE pendingbot.welcome_bonus_grants ENABLE ROW LEVEL SECURITY;

COMMIT;
