# 这个仓库是怎么来的

> 写给**下一个要重新生成这份快照的人**。它放在公开仓里，因为那个人手上
> 一定有公开仓，不一定有别的东西。

## 一句话，以及那句更顺口但是错的话

这是 PendingBot 私有开发仓的一份**内容快照**，不带任何历史。

顺口的说法是「**公开仓 = 私有 main 的干净快照**」。**这句话是错的**，
而且它错得很不容易发现，因为它**曾经**对过一次——第一份快照生成的那天，
它就已经不对了。三处偏差：

1. **快照并入了四条当时还没合进 main 的分支**（见下）。其中一条带着一个
   安全修复迁移。有一段时间，**公开仓在那一条上比私有 main 更安全**——
   这个方向反常到没人会想起来去查。
2. **有些文件是直接写在快照里的**，私有仓从来没有过：`CONTRIBUTING.md`、
   `SECURITY.md`、`.gitleaks.toml`、`.github/ISSUE_TEMPLATE/*`、
   `.github/pull_request_template.md`、
   `apps/edge/prompts/skills/anthropic/LICENSE.txt`，以及这份文件本身。
3. **有些内容是发布之后直接在公开仓改的**：现在的 README 和三张真运行
   截图（`docs/screenshots/{main,contacts,letter}.png`）。

**照着那句顺口话「从 main 重新打一份」，上面 2 和 3 会从一个全世界已经
拿到的仓库里消失。** 别那么干——下面有一道闸门专门拦这件事。

## 谱系

| | |
|---|---|
| 私有仓 | `syncmeta/PendingBot-dev`（本机 `~/Untitled/Pendingname/PendingBot/dev`） |
| 快照基点 | 私有 `main` @ `329792ac` |
| 快照提交 | `5d44ed2`（本仓 tag `v0.1.0`） |

生成快照时，在基点之上额外并入了四条**当时尚未合并**的分支：

| 分支 | 并入时的提交 | 带进来的东西 |
|---|---|---|
| `chore/self-host-docs` | `26aa174e` | `docs/self-hosting.md` + `.env.example` |
| `chore/fail-loud-config` | `add73c2d` | 配置缺失按需报错、`HostedConfig.isConfigured` |
| `fix/definer-execute-revoke` | `6e67cdd9` | 未鉴权写入修复 + CI 闸门（含 `20260820073931_revoke_public_execute_upsert_self_machine.sql`） |
| `chore/macos-release-pipeline` | `f718859a` | macOS 出包脚本 + entitlements 分平台 + CI |

⚠️ 这四条分支**之后还在动**，私有仓里它们现在指向的提交跟上表不同；
`fix/definer-execute-revoke` 已经合进私有 main。上表记的是**这份快照实际
拿到的那个状态**，不是它们今天的状态。

`v0.1.0` 之后，本仓有三个**直接在这里做的**提交（不来自私有仓）：README
重写与三张真截图。重新生成快照时它们不会自动回来。

## 快照里做过什么改动

- **所有指向作者线上服务的坐标换成了占位值**：Supabase project ref 与
  publishable key、Cloudflare account id / AI Gateway 名 / KV / R2 / Queue、
  Cloudflare Access team domain 与 AUD、后台管理员邮箱、路由域名、
  两份 `Info.plist` 里的 Google 登录 client id、Sentry DSN、PostHog key、
  RevenueCat key（后三个是空串 = 关闭）。判据是
  `apps/pendingbot/Sources/Networking/HostedConfig.swift` 里的 `Placeholder`
  与 `isConfigured`——**改占位值之前先读那段**，两边对不上就等于把那套
  fail-loud 判定废掉了。
- **一条 migration 参数化**：`20260516073714_realtime_webhooks.sql` 原来
  写死了作者的 worker 地址，改成从 Supabase Vault 读 `realtime_webhook_url`，
  没配就不发。否则任何人 `db reset` 之后，本地库都会去打那台机器。
- **内部账本不进**：`docs/` 下只保留登记过的几项，内部协作约定
  （`CLAUDE.md` / `.claude/` 等）一概不进。规则和逐条判词在私有仓的
  `scripts/snapshot-exclusions.tsv`。

## 重新生成时必须跑的两道闸门

两道都在私有仓的 `scripts/` 下，**都是 fail-closed**——读不到参照物也算
不通过。

```bash
# 1. 不许弄丢任何已经发布出去的东西。参照物是「此刻线上公开仓的 main」，
#    从 remote 现读，不是任何人维护的清单（清单会漂，而且漂了没人知道）。
scripts/check-public-snapshot-superset.sh --candidate <新快照目录>

# 2. 不许把不该公开的带进来。docs/ 是 allow list（没登记就不进），
#    其余是 block list。逐条判词和「为什么两套规则不一样」写在清单头部。
scripts/check-snapshot-exclusions.sh --candidate <新快照目录>
```

第 1 道会把上面「2 和 3 会消失」这件事直接打出来：已发布的迁移少一条就
硬红、豁免不掉；其它已发布文件少了也红，除非你用 `--allow-drop` 明确说
出口——那时它会把你删掉的东西打印出来，不会悄悄发生。

## 怎么自己核，而不是相信这份文件

这份文件是人写的，会过时。下面这些是现读的：

```bash
# 本仓相对私有 main 多了/少了什么
git -C <公开仓> ls-files | sort > /tmp/pub.txt
git -C <私有仓> ls-files | sort > /tmp/priv.txt
comm -23 /tmp/pub.txt /tmp/priv.txt   # 公开有、私有没有
comm -13 /tmp/pub.txt /tmp/priv.txt   # 私有有、公开没有

# 两边的迁移账本
git -C <公开仓> ls-files supabase/migrations | wc -l
git -C <私有仓> ls-files supabase/migrations | wc -l
```

**已知缺口，说在前面**：快照目前是人工步骤，这份文件也得靠人更新。上面
那两道闸门拦得住「弄丢」和「多带」，拦不住「这份文件写得不对了」。改了
生成方式，记得回来改它。
