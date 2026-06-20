# Supabase

大绿豆的**真源数据库 + 身份源**。Postgres(行级安全)+ Auth(发 JWT、管登录)+ Storage,一站托管,零自管 VPS。系统里它的角色由 [客户端读路径](../../shared/concepts/read-path.md) 定调:**真源、写入终点、身份源、喂边缘投影的事件源**——重要但不在同步热路径上。相关:[数据可见性即 RLS](../../shared/concepts/data-visibility-rls.md) · [设备授权](../../shared/concepts/device-grant.md) · [Cloudflare(edge 是它前面的那层 worker)]。

**逻辑 — 它在系统里扮演什么**

- **唯一的真源库**:所有业务数据落在这里;worker 写回它、读它(冷路径)或读它喂出来的边缘投影(热路径)。客户端**不直连**它做高频读(见读路径),只在登录 / 注册 / 刷新会话、以及边缘没命中的冷回落时才直连。
- **身份源**:Supabase Auth 负责账号身份和 session,签发非对称 JWT(JWKS 可验)。worker 和 `@pendingbot/identity` 包验这枚 JWT 来认人;[设备授权](../../shared/concepts/device-grant.md) 的 `pfa_`/`pdg_` 票最终也回溯到这里的 user。
- **行级安全(RLS)是可见性的事实源**:谁能看见哪条数据由数据库的行级安全策略定义、强制执行——这是冷路径上"免费的第二道防线"。热路径把数据搬到边缘后这层自动保护就没了,所以 worker 必须**显式复刻**同一套可见性判断(见读路径的 🔴 隐患)。可见性的产品语义见 [数据可见性即 RLS](../../shared/concepts/data-visibility-rls.md)。
- **业务表挂在自有 schema(`pendingbot.*`),不挤 `public`**:这样未来同发布者的别的产品能共用同一个 Supabase 项目的 `auth.users`(账号体系打通),各自的业务数据互不串。同发布者 SSO 能成立,根子就在这里。

**为什么 — 关键取舍**

- **托管换零运维**:Postgres + Auth + Storage + Realtime 一家给齐,省掉自建鉴权 / 自管库的人力,契合党纲"关键基础设施外包、零 VPS"。代价是被托管平台框住(配额、区域、CAPTCHA 等都走它的后台)。
- **EU 区(法兰克福)是有意为之**:数据驻留在欧盟(GDPR),不在美区。这也正是 [读路径](../../shared/concepts/read-path.md) 存在的根因——库只有一个区,US/Asia 用户每次首屏都要吃一趟跨洋往返,所以热读必须靠边缘投影把延迟藏掉。区域是产品级决策,不是随手选的。
- **行级安全当可见性事实源,而不是在应用层手判**:把"谁能看什么"沉到数据库,应用层少一类越权 bug;边缘热路径是这个原则的**例外**(为了延迟),且这个例外是显式的、记了债的,不是默认姿态。

**用在哪·长什么样**

- 用户看不到 Supabase 本身——它是后端基座。用户能感知到的,是登录(Auth)、首屏数据(经读路径)、以及数据驻留在欧盟这件事。
- 运营 / 开发侧:Supabase Studio 兼作只读 BI / 数据巡查面板之一(见 dashboard 栈)。

**边界 — 明确不做什么**

- **单环境,不分 staging / prod**:v1 未发布,只有**一个**部署的 Supabase 项目(EU)。launch 后再谈拆分,现在不搞多环境基建(党纲"未发布、单环境")。
- **客户端不直连库做高频读**:热读一律走边缘投影,直连只用于身份 / 写 / 冷回落(见读路径边界)。
- **不做端到端加密**:边缘投影需要明文做授权 / 服务,数据在边缘是明文的。
- **不把可见性逻辑只放应用层**:行级安全是冷路径的强制底线,不能因为有了边缘授权门就把它当可选。

**注意 — 坑 / 已变更的决策**

- **API key 已从老的 `anon` / `service_role` JWT 切到新体系 `sb_publishable_…` / `sb_secret_…`**(2026-06-10 全端切换并部署)。`publishable` 是可公开的客户端 key(明文嵌 iOS / admin / worker var),`secret` 是服务端密钥(走 secret 管道,不落屏)。**老的 anon/service_role JWT key 在 Supabase 后台仍处启用态**——这是迁移期的预期并存,不是事故;全端确认无引用后会在后台 disable(可随时恢复,官方截止 2026 年底)。**写新代码别再用 anon/service_role 这套老名字。**
- **写新迁移用 UTC 时间戳前缀,别手挑序号**:并行 worktree session 无法可靠协调四位序号,所以新迁移一律 `YYYYMMDDHHMMSS_<name>.sql`(用 `supabase migration new <name>` 生成,天然防撞)。早期 `0001`–`00xx` 的四位旧块原样保留——按字典序 `00xx` < `20xx`,旧块永远先跑,别批量改名。机械细节见根 [`CLAUDE.md`](../../../../CLAUDE.md) "Before writing a new migration"。
- **schema-regen 是迁移的另一半,不是可选步**:任何落新迁移后,必须重生成 TypeScript schema(`bun --filter='@pendingbot/edge' run types:db`,脚本带 `2>/dev/null` 防 CLI 通知污染 schema.ts),否则引用新表 / 列的 edge 代码 typecheck 不过。仓库有 pre-commit 钩子(`schema-regen-check`)守这条:暂存了 `migrations/*.sql` 却没暂存 `schema.ts` 会被拒。这是"迁移落了、schema 忘了"反复发生后立的纪律。
- **EU 项目的 Auth 开了 CAPTCHA(Turnstile)**:客户端的密码登录 / OTP 会被 CAPTCHA 挡,登录页必须带 Turnstile token;只有 service_role 的 admin API 能绕过。这影响所有走客户端 Supabase Auth 的入口(app 登录、admin 后台登录)。
- **库迁过区**:主库原在 US(us-west-2),pre-launch 无真实数据 → 2026-06-04 在 EU 新建项目、全套迁移重跑、**不迁数据**,旧 US 库留作回退、**待端到端全验后删除(尚未下线)**。所以"美区库"是历史路径,现状是 EU 单库。

**现状** — ✅ EU 单库在产、Auth + RLS + Storage 在用、新 API key 体系已部署验证。🟨 尾巴:老 legacy key 仍在后台启用(待无引用后 disable,见 tech-debt)。证据见 [`docs/progress.md`](../../../progress.md) 2026-06-04 迁 EU 行 + 2026-06-10 API key 行。
