# 配置即 CMS(board)

该可改的东西——功能开关、平台用哪个模型、预设规则、工具开关、MCP 服务器、各种预设内容——都不硬编码在代码里,而是在一个叫 **board** 的管理台里编辑,经边缘 KV 下发,几秒到一分钟内全球生效。相关:[模型选择](models.md) · [工具系统](bot-tools-and-scopes.md) · [Prompt 与世界观](prompts.md) · [board 接入门(Access)](../../stack/cloudflare/access.md)。

**逻辑**

- **UI-first 配置** — 配置的旋钮放在前端(board),不写死在代码里。board 是一个 Refine + Ant Design 的 SPA,对一批"内容 / 预设 / 配置"表做增删改,经 edge 的 `/v1/board/*` 端点(带门禁 + 审计)落库。
- **board 管什么** — 七类:**预设机器人 / 预设会话 / 预设群 / 预设来信**(新用户 onboarding 时克隆 / 物化)、**工具管理**(tools 注册表开关 + 模型看到的说明)、**MCP 服务器**(纯配置 CRUD)、**功能开关**(billing / 各观测厂商的 kill-switch)。另有**模型预设**(规则驱动的模型池,见模型选择)和**系统模型角色**(平台任务用哪个模型,见下)两个配置页。
- **两种下发节奏**:
  - **直接读源表 + KV 读穿**(tools / mcp_servers 等)——edge 读这些配置走 KV 读穿:第一个冷 isolate 读一次 Supabase 并写 KV,之后所有冷 isolate 从边缘 KV 读(个位数毫秒),陈旧度 = 既有 TTL 窗口。board 改了源表,KV 在 TTL 内自动刷新。
  - **KV 配置 blob**(功能开关 / 模型角色)——board 直接写一个 KV blob(`cfg:feature-flags`、`cfg:model-roles`),edge 以 `override ?? code 默认值` 的形状读:KV 有覆盖就用覆盖,读不到 / 失败就静默回落 code 里的默认值(**永不抛**)。
- **数秒全球生效** — KV 是 Cloudflare 的全球边缘存储,改完传播是秒级到 ~60s。配合 isolate 本地的短 TTL 缓存,既不每轮打 KV、又能在一个窗口内追上变更。
- **每次写都留痕** — board 的每次写操作 = 读 before 快照 → 应用变更 → 写一条审计(谁、改了什么、前后值)。审计不可被某条路径绕过(封装成统一 helper)。回滚 = 人工把 before 值粘回(暂不做一键回滚)。

**为什么**

- **UI-first,无 legacy 包袱** — 配置旋钮归前端是定下的产品取向:运营 / 产品自己改,不求工程发版。这呼应党纲红线"模型 slug、功能开关、运营文案这类该可改的一律进 board / KV"。
- **board 的职责是"中央后台才接得住"的那部分** — 用户 / 会话浏览归 PostHog,计费 / 钱包归 Polar / RevenueCat,人工协助 / 审批归 PendingCrew。剩下"只能在中央后台做"的就是**内容 / 预设 / 配置管理**——这正好是 board 的本职。
- **KV 是对的下发媒介** — 配置是"读多写少、全局、小"的数据,KV(最终一致、全球边缘、秒级传播)正合适;不适合放高频写的热数据(那走 DO,见读路径)。

**用在哪·长什么样**

- **运营侧**:浏览器打开 `/board`(与 edge 同源),过 Cloudflare Access 的身份门后进到七 + 两个页,改完即下发。无应用内第二登录(身份唯一源是 Access,见 board 接入门)。
- **用户侧**:用户看不到 board,但处处受它影响——新用户进来自带的预设 bot / 预设会话 / 那封 readme 来信、bot 能用哪些工具、平台后台任务用哪个模型,都是 board 配的。

**示例** — 测试期不想让空钱包把测试者挡在门外。运营进 board 功能开关页,确认 billing 开关是关的(默认就是关)。edge 读 `cfg:feature-flags`,billing 为 false → 计费门从不拦、不发用量——测试者畅通无阻,也不烧表。要正式上线计费时把开关翻 true,数秒生效,不发版。

**边界**

- **board 不做运营仪表盘** — 用户 / 会话 / Bots 浏览(PostHog)、计费台账 / 钱包 / 退款(Polar / RevenueCat)、人工协助 / 权限审批(PendingCrew)都**不在 board 建**。早期那版 8 页运营仪表盘已全部退役。
- **不是所有"配置"都进 board** — 冷参考数据(地名语料、task-routing 这类极少改的)直读 / DB 直编即可,不值一个 board 页;模型目录是 OpenRouter 外部 API + CF 缓存,不是可板编辑的表。判据是"是否该被运营高频改 + 是否在热路径读"。
- **Sentry 是例外** — 错误上报的 kill-switch **不**走 board / KV(一个报错器的开关不能依赖 KV,否则一次边缘存储抖动会让本该捕获故障的报告器自己哑掉),它纯 env、改 wrangler 重部署,board 上只读显示。

**注意**

- 早期 spec 把 board 当"运营仪表盘"(还列了模型目录 / pricing / i18n / place_names 等一堆要进 board 的源表)——已**大幅作废**:实测真走 KV config 通道的只有 tools 和 mcp_servers,其余要么表不存在、要么是冷参考数据。别照老 spec 的清单理解 board 范围。
- 早期 spec 还说预设来信要"新建 preset_letters 表 + 改 signup 函数"——也作废:表和函数早就在,P2 实际零迁移、只补 CRUD 面。
- **直接改源表(迁移 / db push)不会自动失效 KV 缓存**——model_presets 上线时实际踩到:db push 改了表但 KV 还缓存旧解析结果,读端点返回旧值。board 自己的 CRUD 路径会主动 bust,但绕过 board 的直改要手动清 KV。这是一条已知缺陷,部署 runbook 已补 bust 步(见 tech-debt)。
