# Deploy recipe

Pointed at by `CLAUDE.md`'s short Deploys section. Read this only when
the session is actually about deploying — it's not in the auto-loaded
project doc to keep every session's context lean.

Three deployable surfaces. **Each one is operator-initiated** — never
auto-deploy on merge.

---

## Edge worker (`apps/edge/`)

Cloudflare Workers, lives at `api.pendingname.com` via custom domain.
Single deployed env (`env.production` in `wrangler.jsonc`); local
iteration uses `wrangler dev`.

```sh
bun --filter='@pendingbot/edge' run deploy
```

The `--filter='...'` form (with `=`) matters — bun ≥ 1.3 silently
mis-parses `--filter @pendingbot/edge` (space-separated) as no-match.

### Secrets

Bound per-env via `wrangler secret put`. **Always pass
`--env production`** — without that flag the secret goes to a
default/dev env the deployed prod worker can't see, and
`resolveRoute()` throws `NoRouteError` because the env var lookup
misses.

```sh
cd apps/edge
bunx wrangler secret put CF_AIG_RUN_TOKEN --env production
```

Verify what's bound:

```sh
bunx wrangler secret list --env production
```

We hit this once already (added `WORLDROUTER_API_KEY` without
`--env production`; iOS messages went to `bot-reply`, route resolved
to WR alias, env lookup missed, NoRouteError, fallback to OR — fix
was re-putting with the flag).

### Kill-switches (计费 + 观测) — 默认全 OFF

四个 deploy-time **var**(`wrangler.jsonc` → `env.production.vars`,**不是 secret**),
见 `apps/edge/src/lib/feature-flags.ts`。只有精确字符串 `"true"` 才启用;改完**重部署**
才生效(env var 是部署期定值)。容器没改时可加 `--containers-rollout=none` 跳过 Docker。

| var | 管什么 | 关时(默认) | 备注 |
|---|---|---|---|
| `BILLING_ENABLED` | 计费 gate + 扣费 + 送/兑换入 Polar | 不挡人、不扣、`/redeem` 返 503、signup 不发额度 | 开前先种好 Polar 余额逻辑已就绪 |
| `SENTRY_ENABLED` | Sentry 错误上报 | 不初始化 SDK | 错误突发会烧 event 配额 |
| `POSTHOG_ENABLED` | PostHog 产品事件 | capture no-op | 随用户行为,量中等 |
| `LANGFUSE_ENABLED` | Langfuse LLM trace | trace no-op | **每次 LLM 调用 1 条,烧最快**,最后开 |

- **双重门**:观测三家除开关 `"true"` 外,还各需 `SENTRY_DSN`/`POSTHOG_KEY`/`LANGFUSE_*` secret 才真正发数据。
- **为何用 env var 不用 DB 开关**:观测开关必须零运行时依赖——DB 挂了正是最需要 Sentry 的时候。
- **启用某个**:改 `wrangler.jsonc` 对应行为 `"true"` → `bun --filter='@pendingbot/edge' run deploy`(或 Docker 没起时 `cd apps/edge && bunx wrangler deploy --env production --containers-rollout=none`)。
- **启用计费前**:用 sandbox token 跑 `cd apps/edge && POLAR_ACCESS_TOKEN=<t> POLAR_SERVER=sandbox bun run polar:spike` 确认 ensureCustomer 的 409 分支(见 tech-debt)。

---

## iOS / iPad / macOS apps (`apps/pendingbot/`)

> 工程在 T0.1 合并成单 `apps/pendingbot/` 三 destination multiplatform。老的
> `apps/ios/` 已经不存在；iPad scheme 用同一个 `PendingBot` target
> （`TARGETED_DEVICE_FAMILY=1,2`）。

TestFlight uploads are operator-initiated. When the user asks
"上传一版到 TestFlight" / "upload to TestFlight", do the upload end to end
from a short-lived branch. Do not stop with instructions for the user.

The project uses automatic signing with team `M42BKJN82S` and Xcode's
archive/export flow. The configured App Store Connect/Xcode account on
this machine is enough; no repo-secret is needed.

xcodeproj 由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从
`apps/pendingbot/project.yml` 生成，已 commit 到 repo。**改 build
settings 改 `project.yml` 然后 `xcodegen` 重新生成，别手动改
`project.pbxproj`**。

### Fast TestFlight recipe

1. **Check location and branch first**:
   ```sh
   pwd
   git branch --show-current
   git status --short --branch
   ```
   If in the main worktree on `main`, create a short-lived branch or
   worktree first. Do not edit the build number directly on `main`.

2. **Set the iOS build number — 用脚本，别手工填**：
   ```sh
   scripts/release/ios-build-number.sh --apply
   ```
   它算出纪元日时间戳、跟 App Store Connect 上已有的最高 build 号核对（不倒退
   才放行）、写进 `apps/pendingbot/project.yml` 并跑 `xcodegen`。规则和背景见
   下面的 [iOS build 号](#ios-build-号--纪元日时间戳--防倒退闸)。

   Keep `MARKETING_VERSION` unchanged unless the user explicitly asks
   for a version bump. **Scaffold 阶段** `CODE_SIGNING_ALLOWED=NO` 仍在
   project.yml 里；正式 archive 需要先把这两行删掉再 regen，或者用
   `-allowProvisioningUpdates` 走 xcodebuild override（automatic signing
   会临时盖掉这两个 flag）。

3. **Resolve SwiftPM packages**. This usually needs network/Xcode cache
   access; if sandboxed DNS/cache writes fail, rerun with escalation.
   ```sh
   xcodebuild -resolvePackageDependencies \
     -project apps/pendingbot/PendingBot.xcodeproj \
     -scheme PendingBot \
     -clonedSourcePackagesDirPath /private/tmp/pendingbot-xcode-packages \
     -derivedDataPath /private/tmp/pendingbot-xcode-derived
   ```

4. **Create a temporary upload export plist**. Keep the repo
   `ExportOptions.plist` as `destination=export`; use `/private/tmp` for
   upload.
   ```sh
   cp apps/pendingbot/ExportOptions.plist /private/tmp/PendingBot-ExportUpload.plist
   /usr/libexec/PlistBuddy -c 'Set :destination upload' /private/tmp/PendingBot-ExportUpload.plist
   ```

5. **Archive Release for iPhoneOS**. 先跑一句断言，别白跑一次 archive：
   ```sh
   scripts/release/ios-build-number.sh --check
   ```
   写进 project.yml 的 build 号是**一次性快照**，绕过第 2 步直接 archive 时它
   不会自己更新（占位符 `"1"` 会被 ASC 拒收）。`--check` 把这个失败提前到
   archive 之前。

   ```sh
   xcodebuild archive \
     -project apps/pendingbot/PendingBot.xcodeproj \
     -scheme PendingBot \
     -configuration Release \
     -sdk iphoneos \
     -destination generic/platform=iOS \
     -archivePath /private/tmp/PendingBot-0.1.0-<build>.xcarchive \
     -derivedDataPath /private/tmp/pendingbot-xcode-derived \
     -clonedSourcePackagesDirPath /private/tmp/pendingbot-xcode-packages \
     -allowProvisioningUpdates
   ```
   Success marker: `** ARCHIVE SUCCEEDED **`.

6. **Upload to TestFlight**:
   ```sh
   xcodebuild -exportArchive \
     -archivePath /private/tmp/PendingBot-0.1.0-<build>.xcarchive \
     -exportOptionsPlist /private/tmp/PendingBot-ExportUpload.plist \
     -exportPath /private/tmp/PendingBot-0.1.0-<build>-export \
     -allowProvisioningUpdates
   ```
   Success markers: `Uploaded PendingBot` and `** EXPORT SUCCEEDED **`.
   If App Store Connect says the uploaded package is processing, the
   TestFlight upload is complete.

7. **Commit and merge the build number**:
   ```sh
   git add apps/pendingbot/project.yml apps/pendingbot/PendingBot.xcodeproj/project.pbxproj
   git commit -m "ios: bump TestFlight build to <build>"
   git rebase main
   ```
   Then fast-forward local `main` if conflict-free and leave unrelated
   dirty files untouched. Do not push `main` unless the user asks.

Known warning: uploads may print
`exportArchive Upload Symbols Failed` for `WebRTC.framework` missing a
matching dSYM. This does not block TestFlight install or processing; it
only means WebRTC framework crash logs may lack readable symbols.

### iOS build 号 — 纪元日时间戳 + 防倒退闸

**规则：`CFBundleVersion` = `<自 1970-01-01 起的天数>.<当天已过的秒数，补零到 5 位>`
（如 `20683.07431`）。不从 git 历史算，不手工填。**

#### 为什么不是 commit 数

曾经是。2026-08-11 上传的 `0.1.0 (3571)` 就是 `git rev-list --count HEAD`。
后来本地 monorepo 丢失、从落后一个月的 origin 重新拉回来，提交数掉到
**3178** —— build 号**倒退 393**。App Store Connect 要求同一
`MARKETING_VERSION` 下 build 号严格递增，所以照旧做法**从新仓库一版都发不
出去**。

根因不是「数字太小」，是 **build 号从 git 历史算，而历史正是会丢的那样东西**
（那次事故文件全活着，死的只有历史）。从时钟派生的时间戳天生单调、不依赖仓库
状态，从 tarball / 浅克隆 / 重建过的仓库构建都对。

PendingCrew（macOS/Sparkle）同期同病、同期同改，两个产品用同一编码。

#### 为什么是纪元日，为什么第二段是「当天第几秒」

**这三条理由必须留在文档里**，否则以后一定有人嫌 `20683.07431` 看不懂就改掉。

**可读性是有意放弃的。** 这是个机器用的单调标识，不是给人看的日期；要人看
的日期在别处（脚本输出的可读时间、TestFlight 的 What to Test）。

**① 为什么不是可读的 `YYYYMMDDHHMM`（`202608180940`）—— 32 位整数**

| 编码 | 例 | 数量级 | 2^31 = 2147483647 |
|---|---|---|---|
| `YYYYMMDDHHMM` | `202608180940` | 2.03×10¹¹ | **超了** |
| `date -u +%s` | `1787018157` | 1.79×10⁹ | 以内，但见 ② |
| **纪元日** | **`20683`** | **2.07×10⁴** | **小五个数量级 ✓** |

下面引的两份 Apple 文档只约束「≤3 段、≤18 字符、纯数字」，**从不提每段的
数值宽度上限**。所以 12 位那个方案里，「ASC 内部 parser 吃不吃得下超 2^31 的
单段」只能靠真上传去赌。不赌。

**② 为什么不是 Unix 秒（`1787018157`）—— 2038，以及它会把门焊死**

Unix 秒数值本身安全，但 **2038-01-19 03:14:07 UTC 之后越过 2^31**，同一类
风险只是推迟了十二年。纪元日要到公元 590 万年才够得着。

更硬的一条是**不关门**：纪元日是所有候选里最小的，以后真想改主意，
`20683` → `20260818`（`YYYYMMDD`）→ `1787018157`（Unix 秒）**逐级都是增**，
防倒退闸都放行；反过来任何一步都是减，**永远切不回去**。先上最小的那个，
等于把以后改主意的余地留着。（先上 Unix 秒就把门焊死了。）

**③ 为什么第二段是秒数，不是「今天第几版」—— 外部状态**

第二段（`0..86399`）只为一件事：同一天要发第二版。用序号就需要外部状态 ——
要么人记着填（忘了就撞号，而撞号的后果是发版被拒或更新静默推不出去），要么
每次构建去线上问一遍（把能不能构建绑死在网络上）。秒数纯从时钟算，零外部
状态，同日天生递增。**发版号依赖外部状态**正是这轮要拆掉的东西。

**第二段固定补零到 5 位，别去掉。** 补零之后「按整数解」和「按字符串解」
得出的先后**一致**：`07431 < 10000` 整数成立，字符串比 `"0…" < "1…"` 也成立。
不补零就只剩整数解一条路能对（`"7431"` 字符串比 `"700"` 反而小）。我们无法
确知每个消费方怎么解析这一段，补零让两种解法都不会把同日先后弄反。

#### 怎么把 build 号换回时间

脚本每次都会把可读时间打到 stderr：

```
20683.07431
build 20683.07431 = 2026-08-18 02:03:51Z（ASC 当前最高: 3571）
```

**发版时把这行抄进 TestFlight 的 What to Test。** 事后反查任意一个
`<天>.<秒>`：

```sh
date -u -r $(( 20683 * 86400 + 7431 ))   # → Tue Aug 18 02:03:51 UTC 2026
```

#### 格式合法性（Apple 官方，不是印象）

- [TN2420](https://developer.apple.com/library/archive/technotes/tn2420/_index.html)：
  > "The value for a version number or build number must consist only of '.'s
  > and numbers and must begin and end with a number. ... Version numbers and
  > build numbers may have up to three components separated by periods. The
  > total number of characters in your version number or in your build number
  > cannot exceed eighteen characters."
- 现行 [`CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion) 文档：
  > "a machine-readable string composed of one to three period-separated
  > integers ... can only contain numeric characters (0-9) and periods."

`20683.07431`：11 字符（限 18）✓、2 段（限 3）✓、纯数字 ✓、首尾是数字 ✓。

TN2420 还有一条值得记住：**iOS 允许换 `MARKETING_VERSION` 后重用 build 号，
macOS 不允许（必须跨版本单调递增）**。PendingBot 的 iOS 和 macOS 是同一个
target、同一个 bundle id、共用同一个 `CURRENT_PROJECT_VERSION`，所以防倒退闸
取的是**跨版本的全局最高 build 号**，直接满足更严的那条。

#### 没有「备用格式」，这是有意的

曾经留过一个（`BUILD_NUMBER_FORMAT=dotted`），实测后删了。原因是一个结构性
的坑：**备用格式想接在主格式后面用，就得比主格式大**，而任何「更安全所以
数值更小」的编码天生做不到 —— 第一个主格式 build 一旦落地 ASC，那个备用就
永远切不过去，留着只会让人在真出事时白试一轮。环境变量还认，但会 fail loud
报废弃，不会静默给你默认格式。

真正一直可用的 escape hatch 是上面提过的那条：**iOS 允许换
`MARKETING_VERSION` 后重用 build 号**。万一哪天 ASC 对当前编码有意见，正解是
升 `MARKETING_VERSION` 另起一条 release train，不是在 build 号编码上找花样。

#### 防倒退闸

`scripts/release/asc_highest_build.py` 直接问 App Store Connect 要当前最高
build 号，`ios-build-number.sh` 拿它跟这次算出的值逐段比，不严格递增就拒绝
发版。

**这道闸 fail closed：取不到数据就停，绝不当成「没有历史版本」放行。** 这是
照着 PendingCrew 那边踩的坑反过来设计的 —— 他们的 Sparkle 脚本用
`curl -fsS ... || true` 拉 appcast，「拉取失败」和「首发、feed 里还没有版本」
长得一模一样，网络抖一下防倒退就静默失效。

但 fail closed 也不能做成「Apple 抖一下就发不了版」，所以分了两类：

| 情形 | 行为 |
|---|---|
| 4xx（鉴权失败、请求写错、app 记录不存在），429 除外 | 立刻停，重试无用 |
| 网络不通 / 超时 / 5xx / 429 | 退避重试 3 次（2s/5s/15s），仍不行才停 |
| API 通、app 记录存在、确实一个 build 都没有 | 视为真·首发，返回 `0` |

闸报错**不是绕过它的信号**，是「现在没法核实」：等 ASC 恢复再发，或先手工在
App Store Connect 网页上确认最高 build 号。

#### 凭据

`asc_highest_build.py` 按 `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`
取凭据，环境变量优先，否则读 `~/.appstoreconnect/pendingbot.env`（一行一个
`KEY=value`，本机已配好，600 权限）。`.p8` 本身不进仓库、不进日志。
签 JWT 需要 PyJWT（`/usr/bin/python3 -m pip install --user pyjwt`）。

---

## Admin / BI surface — dashboard stack (board retired)

The old self-made `apps/board` Next.js admin UI is **deleted**. The
admin + BI surface is now the zero-VPS dashboard stack: Grafana Cloud
(financial BI over Supabase), Supabase Studio, PostHog, Langfuse,
Sentry, and the Refine admin console (`apps/admin`). See
`docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`.

---

## After-merge checklist

When `feat/*` lands on `main`, decide which deploys are needed:

| Files changed | Action |
|---|---|
| `apps/edge/src/**`, `apps/edge/wrangler.jsonc`, `apps/edge/src/types.ts` | Run edge deploy |
| New `supabase/migrations/00NN_*.sql` | `supabase db push --linked` against prod, then regen `apps/edge/src/db/schema.ts` and re-typecheck |
| `apps/admin/**` source (Refine console) | Deploy to CF Pages when wired; not deployed pre-launch |
| Pure prod data (direct SQL like flipping `model_id` / `is_admin`) | No deploy. Ephemeral state, won't survive a `supabase db reset` if anyone ever runs that on prod (we don't, single-env). |

---

## Supabase CLI gotcha across worktrees

`supabase link` writes `supabase/.temp/project-ref` +
`linked-project.json` in the cwd's worktree. **Other worktrees don't
inherit the link.** When operating from a feat worktree, copy from
the main worktree if `supabase db query --linked` complains
"Cannot find project ref":

```sh
cp /path/to/main/supabase/.temp/{project-ref,linked-project.json,pooler-url,*-version} \
   ./supabase/.temp/
```

---

## LLM seed (model + alias catalog)

> ⚠️ 2026-06-04:原脚本 `apps/board/scripts/seed-llm-dev.sql` 随 `apps/board`
> 一并删除(board 废除)。生产库已 seed 过该目录,数据在线;如需重建 dev,
> 从生产导出当前 `llm_providers`/模型目录,或在新位置(如 `apps/edge/scripts/`)
> 重建一份。下面的旧步骤仅作历史参考。

Not a migration — applies the canonical model + alias catalog
separately because pricing changes more often than schema and
shouldn't pollute migration history.

Apply to local DB:

```sh
docker exec -i supabase_db_pendingbot psql -U postgres -d postgres \
  < apps/board/scripts/seed-llm-dev.sql
```

Apply to prod DB:

```sh
supabase db query --linked -f apps/board/scripts/seed-llm-dev.sql
```

Idempotent (`ON CONFLICT DO NOTHING`); rerun freely. Editing the
file's UPDATEs is the cleaner way to bump prices vs writing a
migration.

---

## Realtime cutover (Supabase Realtime → CF hub)

Realtime delivery runs over Cloudflare: clients hold WebSockets to the
`RealtimeHubDO` (`apps/edge/src/durable-objects/hub.ts`); the database
fans row changes in via pg_net webhooks → `POST /v1/realtime-internal/
notify` → the DO. Supabase Realtime is no longer used by the iOS app.

The pieces span three deploys that **must go together** — the webhook
migration POSTs into the Worker, so the Worker must carry the notify
route before the triggers exist.

1. **Pick a shared secret** (any long random string), then:
   - Worker: `wrangler secret put REALTIME_WEBHOOK_SECRET --env production`
   - Supabase Vault (so the pg_net trigger can read it):
     ```sh
     supabase db query --linked \
       "select vault.create_secret('<value>', 'realtime_webhook_secret');"
     ```
     The names must match: trigger looks up `realtime_webhook_secret`,
     Worker compares against `REALTIME_WEBHOOK_SECRET`.
2. **Deploy the Worker** — `bun --filter='@pendingbot/edge' run deploy`.
   This publishes the `REALTIME_HUB` DO (migration tag `v3`), the
   `/v1/realtime-hub/*` WebSocket routes, and the notify route.
3. **Push the migrations** — `supabase db push --linked` applies, in
   order:
   - `..._realtime_webhooks.sql` — installs the pg_net triggers on the
     six realtime tables. From here row changes fan out to the hub.
   - `..._drop_supabase_realtime.sql` — drops every pendingbot table
     from the `supabase_realtime` publication and drops the dead
     `messages.content_partial` column. (The iOS client no longer uses
     Supabase Realtime, so this is a clean teardown, not a staged one.)
4. **iOS** already cuts over on the next build — `RealtimeManager` /
   `EnvelopeFeedChannel` connect to the hub, no flag.

Verify on-device: messages, unread badges, envelope-feed and group
continue-requests all update live; check `net._http_response` in
Postgres for failed webhook POSTs.

Rollback is `git revert` of the realtime commits + redeploy the Worker;
re-add the publication membership by hand if needed (the teardown
migration removed it). There is no shadow-run — the cutover replaces
Supabase Realtime outright.

---

## AI Gateway cutover (BYOK-on-gateway + voice metering)

Branch `feat/ai-gateway-cutover`. Moves LLM provider auth onto the
Cloudflare AI Gateway (BYOK — provider keys live in the gateway
dashboard, not worker env) and replaces client-reported voice billing
with server-side metering.

### Dashboard prereqs (one-time, outside code — already done)

- A CF API token with **AI Gateway Read + Edit** is set as the worker
  secret `CF_AIG_RUN_TOKEN`. The worker sends it as `cf-aig-authorization`
  on every LLM request and on the voice sideband.
- **OpenRouter** key stored in the AI Gateway dashboard (BYOK / Store
  Keys, `default` alias). The worker no longer holds `OPENROUTER_API_KEY`
  for inference — that secret was deleted.
- **OpenAI** left OUT of BYOK Store Keys, so OpenAI inference falls to
  Unified Billing (CF credits). Voice realtime still uses the worker's
  `OPENAI_API_KEY` — that path is OpenAI-direct, not Unified Billing.

### Deploy order — Worker BEFORE the migration

The migration drops `llm_providers.secret_ref` / `auth_type`. The new
worker doesn't select those columns so it runs fine against the old
schema; the *old* worker breaks once they're gone. So:

1. **Deploy the Worker** — `bun --filter='@pendingbot/edge' run deploy`.
   Publishes BYOK `buildClient`, the new `RealtimeMeterDO` (DO migration
   tag `v4`), and the reworked `/v1/realtime/*` routes (`/usage` removed,
   `/attach` + `/ws` added).
2. **Apply the migration** — `supabase db push --linked` applies
   `20260516142651_byok_on_gateway.sql` (drops `secret_ref`/`auth_type`,
   removes the never-wired worldrouter provider + its aliases).
   `apps/edge/src/db/schema.ts` was already hand-edited to the
   post-migration shape (committed) — no regen needed; just re-typecheck.
3. **Board** — not deployed (local dev only); the local server picks up
   the provider-form changes after the branch merges.

### iOS — must ship a matching build

The worker removed `/v1/realtime/usage`; an old iOS build calling it
gets a 404 and voice turns stop being billed. The iOS build must:
- send `transport` (`webrtc` | `websocket`) on `POST /v1/realtime/session`;
- webrtc: after the WebRTC SDP exchange, `POST /v1/realtime/attach` with
  the `call_id`;
- websocket: open `wss://api.pendingname.com/v1/realtime/ws?session_id=…`
  and speak the realtime JSON protocol (audio as base64-in-JSON);
- stop calling `/v1/realtime/usage`.

### After cutover

Retune `billing_config.markup` from the Board — the old value was set
for WorldRouter (~0.7× OpenRouter) pricing, which no longer applies.

### Verify

- Text chat still routes (BYOK OpenRouter + Unified Billing OpenAI);
  `audit_log.cost_credits` is non-zero.
- A voice call on each transport writes per-turn `audit_log` rows with
  `task_type='voice_call'` and audio token counts.
- **Open question** — whether the AI Gateway forwards the `?call_id=`
  query param on the sideband WS. If webrtc voice turns aren't metered,
  the gateway isn't passing it through: in `realtime-meter.ts`
  `realtimeUrl()`, drop the gateway branch so the sideband connects
  straight to `api.openai.com` (billing still works direct).

### Rollback

`git revert` the branch + redeploy the worker. The migration's DROP
COLUMN is not cleanly reversible — re-add `secret_ref`/`auth_type` by
hand if a real rollback is needed (pre-launch, low stakes).

---

## Common gotchas

- **Port 4000 EADDRINUSE on `bun run dev:board`** → an old `next dev`
  is still running. `lsof -i :4000` finds the PID; `kill <pid>` frees
  it.
- **Worktree missing `node_modules`** → fresh worktree (or after a
  `bun install` run elsewhere) doesn't share with siblings. Run
  `bun install` from the worktree root.
- **`.env.local` doesn't follow git renames** → if `apps/admin/`
  becomes `apps/board/` via `git mv`, the gitignored `.env.local`
  stays in the OS-level rename target only if the parent `mv`
  succeeded. Verify after merging into another worktree:
  `mv apps/admin/.env.local apps/board/.env.local && rm -rf apps/admin`.
