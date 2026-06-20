# Edge(Worker + Hono)

后端主体。一个跑在 Cloudflare Workers 上的 Hono 应用,是 iOS / iPad / Mac 客户端、board 后台、外部 webhook 唯一的服务端入口。相关:[Durable Objects](durable-objects.md) · [KV](kv.md) · [AI Gateway](ai-gateway.md) · [Access](access.md)。

**逻辑**
- **它是什么** — `apps/edge` 是整个后端的"中央枢纽":所有业务规则、鉴权、对 Supabase 的写、对模型/支付/推送/语音的编排,都收在这一个 Worker 里。客户端不直连数据库做写,一律走 `/v1/*`。
- **路由分层** — 路径前缀 `/v1/` 是大版本边界(为将来 `/v2` 留位);`/v1` 之内靠客户端版本头做兼容协商。每个业务域是一个子路由(消息、bot、群、邀请、联系人、crew、设备、模型、计费 webhook、语音、realtime、board…),挂在顶层应用上。
- **统一错误信封** — 所有非 2xx 走同一个结构化信封 `{ error: { code, message?, detail? } }`:`code` 是稳定的 snake_case 标识(客户端按它分支),`message` 是给人看的中文文案,`detail` 是结构化附加(如配额超限带 `{ quota_bytes, used_bytes }`)。新增一类错误 = 往那个枚举里加一项,不允许各路由自己拍一个 `{ error: 'foo' }`。
- **同源承载 board** — board 后台(`apps/admin` 的静态构建)由这个 Worker **同源**托管在 `/board`(Worker assets),不另起一个跨域站点。原因:Cloudflare Access 的会话 cookie 只覆盖同源,跨域站点对 `/v1/board/*` 的 API 请求带不上这张 cookie。
- **后台异步** — 一次 LLM 回合的审计 + 计费扣费不挂在响应路径上,而是丢进一个队列(at-least-once,消费幂等),由同一个 Worker 的队列消费回合处理,把 DB 写从用户等待路径上挪开。

**为什么**
- **单一后端、单一事实源** — 业务规则只写一处,iOS / Mac / board 共享同一套 `/v1`,避免"每端各写一份逻辑"漂移。
- **单 prod 环境** — v1 未发布,只有一个部署环境(`env.production`);本地迭代用 `wrangler dev` 打桩 R2/KV、读本地变量。**不搞 staging / 多环境基建**——等有真实用户、值得隔离 churn 时再分。这是党纲里的商业立场,不是省事。
- **错误信封统一** — 客户端要能稳定地"按 code 分支"出该弹什么、该重试还是该升级;一个全局枚举把这件事钉死,胜过满地散落的临时形状。

**用在哪·长什么样**
- 客户端看不到 Worker 本身;它表现为一组 `https://api.pendingname.com/v1/*` 的接口和 `https://bot.pendingname.com`(承载 Apple Universal Links 的 AASA、以及 `/board`)。
- 出错时用户看到的中文提示,通常就是信封里的 `message`;客户端拿 `code` 决定行为(如"余额不足"弹充值、"需要升级版本"挡住旧客户端)。

**边界**
- 不是"瘦代理":业务逻辑住在这里,不下推给客户端,也不让客户端直连库做写。
- 不在这一篇展开各业务域的产品逻辑——那些在 `features/` 与 `concepts/` 各篇;这里只讲"后端主体是什么、怎么组织"。
- 单环境是**当前刻意的取舍**,不是缺失;别把"加 staging"当待办。

**注意**
- **原生限流**:对"能枚举的资源"(handle 查找、群邀请码这类——一个 404-vs-200 就能确认存在性的端点)用 Cloudflare 原生限流闸,而不是自己数。键的解析默认是"登录用户按 user、未登录按 IP";实现见代码 `lib/rate-limit.ts`。⚠️ 限流的 429 响应目前**没走**统一错误信封(是个裸 `{ error, message }`),与 `/v1` 其余响应形状不一致——已知小瑕疵,按现状理解即可。
- **错误信封是硬约定**:加新错误码要进那个枚举,iOS 才认;不要在某条路由里图省事返回别的形状。

**现状** — ✅ Edge 是已部署的生产 Worker(`pendingbot-edge`,域 `api.pendingname.com` + `bot.pendingname.com`),日常作为所有客户端的后端在用。统一错误信封、原生限流、队列化审计/计费均已落地。
