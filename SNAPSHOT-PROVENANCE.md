# 这个仓库是怎么来的

> 写给**下一个要重新生成这份快照的人**。它放在公开仓里，因为那个人手上
> 一定有公开仓，不一定有别的东西。

## 一句话

这是 PendingBot 私有开发仓里**客户端那一棵子树**的内容快照，不带历史。

**不是整个仓库的快照。** 后端（Cloudflare Worker、Supabase 数据库与迁移、
后台控制台、群语音媒体容器、鉴权中间件）不开源，不在这里，也不打算进来。

顺口的说法是「公开仓 = 私有 main 的干净快照」。**这句话现在是错的**，
而且错得比以前更远：以前它只是漏说了几处偏差，现在它连范围都不对。

## 谱系

| | |
|---|---|
| 私有仓 | `syncmeta/PendingBot-dev`（本机 `~/Untitled/Pendingname/PendingBot/dev`） |
| 上一份快照 | `5d44ed2`（本仓 tag `v0.1.0`），私有 main @ `329792ac` + 四条未合分支，798 个文件 |
| 本次基点 | 私有分支 `pendingcrew/session-a0307d` @ `50e3d7df`（待合入 main —— **发布前把这里换成 main 上的实际提交** ） |

## v0.1.0 → 现在，发生了什么

**一次范围变化，不是一次内容更新。** 798 个文件 → 237 个。

删掉的 570 个文件**逐条**记在
[`docs/snapshot-drops/2026-08-23-client-only.txt`](docs/snapshot-drops/2026-08-23-client-only.txt) —— 精确路径，一条一行，没有通配符。
将来问「当初到底删了哪些」，答案在那儿，不在任何人的记忆里。

⚠️ **删掉 ≠ 取消发布。** 那 570 个文件仍然留在这个仓库的历史里、留在
`v0.1.0` 那个 tag 上，任何人还能拿到 —— 包括那 213 个数据库迁移。
下面那道超集闸门敢放行它们，靠的正是这一条。

跟着范围一起换掉的文档：

- `docs/self-hosting.md` **整篇作废**（不是被删，是那条路不存在了）。
  取而代之的是 [`docs/building.md`](docs/building.md)，只讲怎么从源码编出这个 app。
- README / README_EN / SECURITY / CONTRIBUTING / issue 与 PR 模板，
  全部收缩到客户端口径。原来它们在教人做一批瘦身之后做不到的事。

## 快照里做过什么改动

**比以前少得多，因为不该出去的东西现在整棵不出去。**

- **后端坐标是占位值**：`apps/pendingbot/Sources/Networking/HostedConfig.swift`
  的 `Environment.remote` 分支，加两份 `Info.plist` 里的 Google 登录 client id，
  以及 Sentry / PostHog / RevenueCat 三个空串（= 关闭）。
  判据是同一个文件里的 `Placeholder` 与 `isConfigured` —— **改占位值之前先读那段**，
  两边对不上就等于把那套 fail-loud 判定废掉了。
- **迁移参数化那一条不再需要**（`20260516073714_realtime_webhooks.sql` 曾经写死过
  作者的 worker 地址）：整个 `supabase/` 都不出去了。
- **内部账本一概不进**，规则和逐条判词在私有仓的 `scripts/snapshot-exclusions.tsv`。
  那份清单**现在是整棵树的 allow list**：没登记就不进，默认「不发」。

## 怎么生成

快照内容 = 私有仓某个提交上，准入清单里 ALLOW 的那些路径。用 `git archive`
从提交里取，不从工作区拷 —— 工作区可能是脏的，而脏的部分不会有人注意到：

```bash
CAND=/tmp/pendingbot-snapshot
rm -rf "$CAND" && mkdir -p "$CAND"
git archive <私有仓的提交> \
  apps/pendingbot scripts/release/stamp-build-info.sh \
  LICENSE README.md README_EN.md CONTRIBUTING.md SECURITY.md SNAPSHOT-PROVENANCE.md \
  .gitignore .gitleaks.toml icon.svg \
  docs/building.md docs/app-icon.png docs/snapshot-drops \
  docs/screenshots/main.png docs/screenshots/contacts.png docs/screenshots/letter.png \
  .github/ISSUE_TEMPLATE .github/pull_request_template.md .github/workflows/client-build.yml \
  | tar -x -C "$CAND"
```

⚠️ **上面这串路径是准入清单的一份手抄，两处会漂 —— 这是已知缺口。** 两个方向
分别由不同的闸门兜着，所以两道都得跑：

- 这串**多抄**了一个清单上没有的路径 → 快照里多一个文件 → **闸门 2 红**（未登记）。
- 这串**少抄**了一个路径 → 快照里少一个文件 → 闸门 2 看不出来（少东西不违反
  allow list），但**闸门 1 红**（已发布的文件不见了）。

只有对一个从来没发布过、清单上又有的新文件，两道才会都不红 —— 那种情况下漏掉它，
后果只是「该公开的没公开」，下次补上。这正是 allow list 那条判词说的：
在不可逆和丢人之间选丢人。

## 重新生成时必须跑的三道闸门

三道都在私有仓的 `scripts/` 下，**都是 fail-closed** —— 读不到参照物也算不通过。

```bash
# 1. 不许弄丢任何已经发布出去的东西。参照物是「此刻线上公开仓的 main」，
#    从 remote 现读，不是任何人维护的清单（清单会漂，而且漂了没人知道）。
scripts/check-public-snapshot-superset.sh --candidate "$CAND"

# 2. 不许把不该公开的带进来。整棵树 allow list：没登记就不进。
scripts/check-snapshot-exclusions.sh --candidate "$CAND"

# 3. 读者会点的每一条链接都得是活的。默认解析目标仓是 syncmeta/PendingBot。
bun run docs:links   # 在私有仓根目录跑
```

**闸门 1 这次是怎么过的**（照抄下来，因为下次多半还得这么跑）：

```bash
scripts/check-public-snapshot-superset.sh --candidate "$CAND" \
  --allow-drop-file docs/snapshot-drops/2026-08-23-client-only.txt \
  --scope-change '后端不再开源：apps/edge · supabase · apps/admin ·
                  apps/voice-container · packages/identity 整体离开本仓库范围'
```

`--scope-change` 是给「这个仓库不再包含数据库了」这一种情形留的口子，
**不是**给「这条迁移碍事」留的。它必须跟 `--allow-drop-file` 同时给，
缺一个直接 exit 2 —— 两把钥匙，因为一把太容易顺手转。

如果你只是在**同一个范围内**重出一份快照（没有整棵树离开），
那两个参数一个都不该出现，闸门 1 应该直接绿。**一旦你发现自己想加它们，
先停下来问一句：这次真的是范围变了吗？**

## 怎么自己核，而不是相信这份文件

这份文件是人写的，会过时。下面这些是现读的：

```bash
# 本仓相对私有仓的客户端子树差了什么
git -C <公开仓> ls-files | sort > /tmp/pub.txt
git -C <私有仓> ls-files | sort > /tmp/priv.txt
comm -23 /tmp/pub.txt /tmp/priv.txt   # 公开有、私有没有  ← 这一列应该是空的
comm -13 /tmp/pub.txt /tmp/priv.txt   # 私有有、公开没有  ← 这一列应该很长，那是后端

# 客户端子树两边是否一致（应该逐字节相同）
diff <(git -C <公开仓> ls-files apps/pendingbot) \
     <(git -C <私有仓> ls-files apps/pendingbot)
```

**第一列不空 = 反向漂移又发生了。** 那是这个项目已经犯过四次的错：
有人直接在公开仓上改东西，改完没回到私有仓，下次重出快照就把它弄丢。
（前三次分别是一条安全迁移、这份文件本身、`README_EN.md`；第四次是
`README.md` —— 两边一度是两份不同的文档，而超集闸门看不见这种事，
它只比对路径在不在，不比对内容。）

**已知缺口，说在前面**：快照仍然是人工步骤，这份文件也得靠人更新。
三道闸门拦得住「弄丢」「多带」「死链」，拦不住「这份文件写得不对了」。
改了生成方式，记得回来改它。
