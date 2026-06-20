# Access(board 的唯一身份门)

Cloudflare Access(Cloudflare One / BeyondCorp)= 在边缘对浏览器做身份认证的零信任门。大绿豆用它当 board 后台的**唯一身份源**。相关:[Admin(board)](admin.md) · [Edge](edge.md) · [配置即 CMS](../../shared/concepts/config-as-cms.md)。

> board 早期设想自带 Supabase 登录,现已换成 Access,务必按现状理解(见文末「注意」)。

**逻辑**
- **它是什么** — Access 在边缘拦下访问 board 的浏览器,先做身份认证(IdP / OTP 等),通过后给后续请求带上一个签过名的身份断言。board 自身**没有应用内登录页**。
- **同源覆盖** — board 页面和它的 `/v1/board/*` API 同源(都在 `bot.pendingname.com` 下,见 [Edge](edge.md) / [Admin](admin.md)),所以 Access 的会话能同时覆盖"打开页面"和"页面发的 API 请求"两件事——这正是 board 要同源托管的原因。
- **两层防御,各自独立** — 身份这件事有两道关,**互相独立**:
  1. **Access policy**(在 Cloudflare 侧配)决定谁能通过这道门、以及第二因子怎么做。
  2. **Edge 侧再验一次**:校验 Access 断言(对团队 JWKS + 应用 AUD,fail-closed)取出邮箱,再要求"邮箱 ∈ 服务端管理员名单"。即便哪天 Access policy 被误放宽,源站仍只认名单里的邮箱。
- **第二因子归 policy** — board 的多因子 / 设备态 / IdP 选择,全部归 Cloudflare Access 的 policy 管,**不在应用代码里实现**。

**为什么**
- **不重造登录** — board 是低频内部台,自建一套登录 + 多因子是重复造轮子且更易出错。把身份外包给 Access(BeyondCorp 模型),应用只管"已验证的这个邮箱是不是管理员"。
- **fail-closed,无后门** — Access 没配 / 断言缺失一律拒;Edge 侧没有 bypass 变量。配置缺失和"门被拆了"无法区分,所以一律按"关"处理。
- **独立第二权威** — 名单校验和 Access policy 是两个独立权威,任一被误配,另一道仍挡着;这是党纲"社交 / 后台建立在信任上、默认收紧"的具体落实。

**用在哪·长什么样**
- 管理员开 `bot.pendingname.com/board` → Cloudflare Access 先弹身份认证(按 policy 走 IdP / OTP + 第二因子)→ 通过后进 board;之后页面对 `/v1/board/*` 的每个请求都带着 Access 断言,Edge 逐请求复验 + 查管理员名单。
- 普通用户 / iOS 客户端**不经** Access——它只罩 board 这条路径;`/v1/*` 的业务接口走的是 Supabase JWT / 设备授权那套(见 [Edge](edge.md))。

**边界**
- Access **只罩 board**(`/board` + `/v1/board/*`),不管普通用户的登录;那是 Supabase Auth / 设备授权的事。
- 第二因子 / IdP 策略归 Access policy,**不写进应用代码**;这一篇也不展开 policy 怎么配。
- 不是授权的全部:Access 管"是不是合法身份",Edge 的管理员名单管"这个身份能不能动 board"。

**注意 — 已变更的旧方案(别写回)**
- ❌ **board 自带 Supabase 登录 / Turnstile 当身份源** —— 已换成 Cloudflare Access 唯一身份源。审计 actor 现在记 Access 验证过的邮箱,而非 Supabase 用户。
- ❌ **靠"应用内做第二因子"** —— 第二因子归 Access policy,应用不实现。
- 旧 spec(`2026-06-08-board-console-cms-design.md`)正文仍写 `requireSession + requireAdmin(Supabase)`,以其"实施进展更新(BeyondCorp)"和现状为准。

**现状** — ✅ Access 门 + Edge 侧双层校验(Access 断言 fail-closed + 管理员邮箱名单)已落地。board CMS 已在 Edge 侧端到端验过(无凭证→403、名单外→拒)。配套的 board SPA 本身尚未部署到生产(见 [Admin](admin.md))。
