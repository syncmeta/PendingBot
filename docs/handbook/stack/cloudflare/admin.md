# Admin(board 后台)

内部管理台:一个 Refine SPA,用来对"内容 / 预设 / 配置"做增删改。相关:[Edge](edge.md) · [Access](access.md) · [KV](kv.md) · [config-as-cms 概念](../../shared/concepts/config-as-cms.md)。

> 这块有一段"定位被纠偏 + 认证模型被换掉"的历史,务必按现状理解(见文末「注意」)。

**逻辑**
- **它是什么** — board 是给运营 / 决策者用的后台,定位是**内容 / 预设 / 配置管理台**:对现成的 `pendingbot.*` 内容与配置做 CRUD——预设机器人 / 预设会话 / 预设群 / 来信模板、工具管理、MCP 服务器、功能开关、模型角色 / 预设。**不是**运营仪表盘(看用户 / 看账单的活归别处,见边界)。
- **怎么搭** — 前端是 Refine SPA(Vite 构建成静态 dist),由 Edge Worker **同源**托管在 `/board`。所有写都经 Edge 的 `/v1/board/*`,在那里过门禁 + 落审计——board 前端**不直连 Postgres、浏览器里没有 service-role 密钥**,业务规则和审计都在 Edge。
- **身份唯一源 = Cloudflare Access** — board 自身**没有应用内登录**(没有 Supabase 登录页 / 验证码)。谁能进、第二因子怎么做,全归 Cloudflare Access 的 policy;Edge 侧再用一层"已验证邮箱 ∈ 管理员名单"做独立授权。详见 [Access](access.md)。
- **配置即内容** — 该可改的东西(模型 slug、功能开关、运营文案、预设)一律落进表 / KV,从 board 改、运行时生效,不写死在代码里(党纲红线)。board 就是这条红线的编辑面。

**为什么**
- **职责归位** — 早期这个 Refine 壳被建成 8 页运营仪表盘(用户 / bot / 会话浏览、计费台账、人工协助 / 权限审批…)。复核后发现绝大多数职责其实归别处:用户 / 会话洞察 → PostHog;计费 / 钱包 / 退款 → Polar / RevenueCat;人工协助 / 权限审批 → PendingCrew。真正"只能在中央后台做、其它工具接不住"的,恰是**内容 / 预设 / 配置**——也就是被废的旧 board 原来干的活。于是把那份编辑 UI 在 Refine 上重建,8 个运营页全部退役。
- **边缘 only,不直连库** — 每个写都要过 Edge 才能强制业务规则 + 审计;所以**不**用直连 Postgres 的数据层方案。
- **同源 + Access** — 见 [Edge](edge.md) / [Access](access.md):同源才能让 Access cookie 同时覆盖页面和 `/v1/board/*` 的 API。

**用在哪·长什么样**
- 管理员浏览器开 `bot.pendingname.com/board` → 先被 Cloudflare Access 拦下做身份认证 → 进入 Refine 后台,按资源(预设机器人 / 会话 / 群 / 来信 / 工具 / MCP / 功能开关)做列表 / 新建 / 编辑。
- 每次写都打到 `/v1/board/*`,服务端落一条带 before/after 的审计,审计的 actor 记的是 Access 验证过的邮箱。

**边界**
- **不做运营仪表盘**:不看用户列表 / 会话内容 / 计费台账 / 群池明细——那些去 PostHog / Polar / Langfuse / Sentry / PendingCrew。
- **不放 secret**:浏览器侧只用 Supabase publishable key(若用到也仅做只读 Auth 之类),`sb_secret_…` 绝不进前端。
- 这一篇只到"它是什么、什么角色";页面级字段 / 端点形状不在手册里。

**注意 — 已变更的旧方案(别写回)**
- ❌ **board 自带 Supabase 登录 / Turnstile 验证码** —— 已换成 **Cloudflare Access 唯一身份源**(BeyondCorp):`requireCfAccess`(校验 Access JWT,fail-closed)→ `requireBoardAdmin`(邮箱 ∈ 服务端名单)。审计 actor 改记 Access 邮箱。旧 spec(`2026-06-08-board-console-cms-design.md`)正文还写着 `requireSession + requireAdmin(Supabase)`,以其开头"实施进展更新"和现状为准。
- ❌ **`apps/admin/README.md` 里"Auth: Supabase Auth → JWT,逐请求带 Bearer"** —— 这段 README 已**过时**:现网 board 不在应用内登录,身份来自 Access。
- ❌ **旧自制 board(`apps/board` Next.js)/ 8 页运营仪表盘** —— 已删 / 已退役。

**现状** — 🟨 board CMS(预设机器人 / 会话 / 群 / 来信 + 工具 / MCP / 功能开关 7 页)代码已落、已合 main,Edge 侧端到端验过(无 token→401、CRUD 生效、审计精确)。**尾巴**:admin 这个 SPA 尚**未部署**到生产(本地 dev 验的);Refine 资源映射里仍有若干"端点未建"的页(渲染告警、不假成功),完整缺口见 `docs/tech-debt`。
