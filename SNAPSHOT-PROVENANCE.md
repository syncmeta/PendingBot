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
| 本次基点 | 私有 `main`（本次改造已合入，含 `chore/snapshot-and-link-gates` 与 `chore/fail-loud-config`）—— **发布前把这里换成实际出快照的那个提交** |

## ⚠️ 「折进了四条未合分支」的代价，不是一句无害的话

上面那行「+ 四条未合分支」听起来只是谱系上的一个脚注。它已经造成过一次**源码与
二进制在安全机制上的分歧，而且持续了两个版本**。逐条查得到（2026-08-24 实测）：

```
公开仓 5d44ed2（= v0.1.0）  有  Sources/Networking/SupabaseAnonWriteGuard.swift
                            有  Tests/SupabaseAnonWriteGuardTests.swift
私有 769f89f7（0.1.1 dmg 的基准）  没有
私有 d99e0c46（后一个 dmg 的基准）  没有
```

`SupabaseAnonWriteGuard` 是把「supabase-swift 拿不到 session 时会把写请求以 anon
发出去」这件事**从约定变成机制**的那道闸（这个形状误诊过两次，都当成后端 bug）。
**公开仓的源码从第一份快照起就带着它，而每一个发出去的二进制都没有它** ——
读者读源码会以为这个 app 有这道防护，他装的包里没有。

成因就是那四条未合分支：这三笔（`isConfigured` / 登录入口的提示 / 这道闸）
author date 全是 2026-08-20，比两个包的基准都早，但一直躺在没合的
`chore/fail-loud-config` 上；它们进 main 是 2026-08-23 做「仅客户端」改造时
（`e13d8f2b`）的副作用，不是发版之后又干的新活。

**现状要同时容得下两件事，别写成「已修复」**：那三笔现在在 `main` 上，
**下一个包会带上**；而**已经发出去的那两个包永远不会有** —— 二进制发出去就不改了
（见下面 `v0.1.0` 那一节）。

**可信度的损失只能靠发一版真正带着它的包来还。** 把这句留在这儿，是因为它是
「要不要为这个不一致单独发一版」那个决定的理由 —— 决定还没做，但理由不该只活在
某次讨论里。

### 现在是什么状态（2026-08-24 实测，别照抄，自己重量一遍）

**那个缺口关上了。** 拿公开仓客户端子树的 214 个文件逐个查内容在私有仓对象库里
存不存在，**只剩 8 个**，全是替换步骤的产物：

```
换坐标产物   apps/pendingbot/Info.plist
             apps/pendingbot/Resources/Info.plist
             apps/pendingbot/Sources/Networking/HostedConfig.swift
换邮箱产物   apps/pendingbot/Sources/Features/Onboarding/WelcomeView.swift
             apps/pendingbot/Sources/Mac/MacWelcomeView.swift
             apps/pendingbot/Resources/Localizable.xcstrings
生成物       apps/pendingbot/PendingBot.xcodeproj/project.pbxproj
本次重写     apps/pendingbot/README.md
```

**一条「公开仓有而 `main` 上没有的行为」都不剩了** —— 那三笔已合进 `main`，
`LICENSE` 署名对齐，`.gitignore` 取了并集。
（唯一一个「公开仓有、私有仓没有」的文件是
`GoogleG.imageset/g-logo.png`，那是 main 上换成官方 SVG 之后的旧资源，
**登记在丢弃清单里**，不是缺口。）

⚠️ **这不是自动保持的，是靠两道闸门**：超集闸门防丢（已发布的东西不许悄悄消失），
坐标闸门防带真值（也防 `MATCH` 那条对齐被改掉）。**拆掉任何一道，这段话第二天就
可能不成立。**

### 有几个文件永远不会一致，那是设计

上面那 8 个里前 7 个**永远**不会和私有仓逐字节相同：后端坐标和邮箱被换成占位值的
那几份，以及 `xcodegen` 生成的 `.xcodeproj`。**那是替换步骤的产物，不是隐藏的实现。**
看到它们不一致，不要去「修」。

## v0.1.0 → 现在，发生了什么

**一次范围变化，不是一次内容更新。** 798 个文件 → 241 个。

删掉的 568 个文件**逐条**记在
[`docs/snapshot-drops/2026-08-23-client-only.txt`](docs/snapshot-drops/2026-08-23-client-only.txt) —— 精确路径，一条一行，没有通配符。
将来问「当初到底删了哪些」，答案在那儿，不在任何人的记忆里。

⚠️ **那份清单不能只靠算。** 第一版是从「已发布 − 候选」机械算出来的，
里面混进了三个 `apps/pendingbot/` 下的文件 —— 一道**已经发布出去的安全机制**
（`SupabaseAnonWriteGuard`，拦 supabase-swift 静默降级成 anon 的写请求），
只活在未合并的 `chore/fail-loud-config` 和公开仓里，私有 main 上没有。
超集闸门做了它该做的事：红了、把这三条逐条打印了。**能不能接住，取决于有没有
人真的读那几百行。** 一份自动生成的丢弃清单会让这道闸门失效。

⚠️ **删掉 ≠ 取消发布。** 那 570 个文件仍然留在这个仓库的历史里、留在
`v0.1.0` 那个 tag 上，任何人还能拿到 —— 包括那 213 个数据库迁移。
下面那道超集闸门敢放行它们，靠的正是这一条。

跟着范围一起换掉的文档：

- `docs/self-hosting.md` **整篇作废**（不是被删，是那条路不存在了）。
  取而代之的是 [`docs/building.md`](docs/building.md)，只讲怎么从源码编出这个 app。
- README / README_EN / SECURITY / CONTRIBUTING / issue 与 PR 模板，
  全部收缩到客户端口径。原来它们在教人做一批瘦身之后做不到的事。

## ⚠️ `v0.1.0` 这个 tag 从现在起是承重的

**不许删，不许换它的产物。**

上面那句「删掉 ≠ 取消发布」是整件事的支点。它成立的唯一前提是 `v0.1.0`
一直在：被丢弃的 567 个文件 —— **包括那 213 条数据库迁移** ——
只能从那个 tag 和它之前的历史里拿到。

谁哪天把它删了、或者换掉它挂的产物，就把一次**有据可查的范围收缩**，
追溯性地变成一次**真正的数据丢失**。而做这件事的人多半不知道自己在拆什么：
从他的角度看，那只是一个旧版本的 tag。

这条纯靠纪律，没有任何机器闸门保护。同一条约束也写在私有仓的
`docs/deploy.md`（发版 runbook —— 将来真要动手删 tag 的人读的是那份，不是这份）
和 `docs/tech-debt.md`。两边各存一份不是冗余：**读者和操作者不是同一批人。**

更一般的那条：**任何已经公开发布过的 Release，产物都不再替换 —— 要改就发新版本号。**

## 快照里做过什么改动

**比以前少得多，因为不该出去的东西现在整棵不出去。**

- **后端坐标是占位值**：`apps/pendingbot/Sources/Networking/HostedConfig.swift`
  的 `Environment.remote` 分支，加两份 `Info.plist` 里的 Google 登录 client id，
  以及 Sentry / PostHog / RevenueCat 三个空串（= 关闭）。
  判据是同一个文件里的 `Placeholder` 与 `isConfigured` —— **改占位值之前先读那段**，
  两边对不上就等于把那套 fail-loud 判定废掉了。
- **迁移参数化那一条不再需要**（`20260516073714_realtime_webhooks.sql` 曾经写死过
  作者的 worker 地址）：整个 `supabase/` 都不出去了。
- **换坐标这一步现在是脚本，不是人手。** 见下面「怎么生成」第 2 步。
  以前它只是 provenance 里的一句话，背后没有任何东西执行或检查它。
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

# 2. 换坐标。**这一步不能省，也不要用手做。**
#    私有仓里 HostedConfig / 两份 Info.plist / Localizable / 两个登录页带着作者的
#    真坐标，其中一条是他的私人邮箱。占位值同时是 isConfigured 的参照物 ——
#    不换，那套 fail-loud 判定整个失效。
#
#    ⚠️ 清单里还有一种 HOLD 行：**有分歧、而且不该由工具挑边**的东西
#    （现在挂着一条：已发布的 MIT 许可里版权人写谁）。碰到 HOLD 这个脚本
#    **不动那个文件、直接非零退出**，闸门也会红 —— 生成到此为止。
#    那不是故障，是设计：一件要人拍板的事，不该只活在「记得」里。
scripts/apply-snapshot-coordinates.sh --candidate "$CAND"
```

⚠️ **上面这串路径是准入清单的一份手抄，两处会漂 —— 这是已知缺口。** 两个方向
分别由不同的闸门兜着，所以两道都得跑：

- 这串**多抄**了一个清单上没有的路径 → 快照里多一个文件 → **闸门 2 红**（未登记）。
- 这串**少抄**了一个路径 → 快照里少一个文件 → 闸门 2 看不出来（少东西不违反
  allow list），但**闸门 1 红**（已发布的文件不见了）。

只有对一个从来没发布过、清单上又有的新文件，两道才会都不红 —— 那种情况下漏掉它，
后果只是「该公开的没公开」，下次补上。这正是 allow list 那条判词说的：
在不可逆和丢人之间选丢人。

## 重新生成时必须跑的四道闸门

四道都在私有仓的 `scripts/` 下，**都是 fail-closed** —— 读不到参照物也算不通过。

**闸门红了，先别急着给它加例外。** 它只报事实，不猜动机 —— 判断「这次是不是有正当
理由」是你的活。一次完全正当的改动照样会让它红（真实例子：`g-logo.png` 换成官方
SVG，作者拍过板、资源没丢，超集闸门照红，而且红得对）。事实对而结论刺眼时，
该做的是把理由写进档，不是让闸门闭嘴。理由和推论写在
`scripts/check-public-snapshot-superset.sh` 的文件头 —— 就在你准备打开它加例外的
那个位置。

⚠️ **先跑闸门，再编。** 候选目录不是 git 仓库，闸门只能扫磁盘上的文件；而编一次
客户端会在里面留下被 `.gitignore` 忽略的产物（`Package.resolved` 就是一个），
磁盘扫描分不出来，排除闸门会把它报成「未登记」。要么闸门跑在构建之前，
要么在候选目录里先 `git init -q && git add -A` —— 那样 `.gitignore` 生效，
闸门会自动走「tracked files」那条路。

```bash
# 1. 不许弄丢任何已经发布出去的东西。参照物是「此刻线上公开仓的 main」，
#    从 remote 现读，不是任何人维护的清单（清单会漂，而且漂了没人知道）。
scripts/check-public-snapshot-superset.sh --candidate "$CAND"

# 2. 不许把不该公开的带进来。整棵树 allow list：没登记就不进。
scripts/check-snapshot-exclusions.sh --candidate "$CAND"

# 3. 一条真坐标都不许留下。跟第 2 步读同一份清单，所以「换了什么」和
#    「查什么」不会对不上 —— 替换脚本自己说没问题不算数。
scripts/check-snapshot-coordinates.sh --candidate "$CAND"

# 4. 读者会点的每一条链接都得是活的。默认解析目标仓是 syncmeta/PendingBot。
#    **在候选目录里也跑一遍**才有意义：在私有树里跑，指向 apps/edge/… 的链接
#    照样解析得到（文件还在树上），瘦身之后才死。把检查器临时拷进候选目录跑，
#    跑完删掉。
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
**不是**给「这条迁移碍事」留的。三道机器约束，不是三句提醒：

- 它必须跟 `--allow-drop-file` 同时给，缺一个直接 exit 2 —— 两把钥匙，
  因为一把太容易顺手转。
- `--allow-drop-file` 指的必须是**已提交进仓库**的路径（闸门用
  `git ls-files --error-unmatch` 查）。临时文件和管道被挡在外面：一份只活了
  一条命令那么久的清单，回答不了「当初到底删了哪些」。
- **带 `--scope-change` 时，无人值守环境直接拒跑**（stdin 不是 tty，或 `CI` /
  `GITHUB_ACTIONS` 之类的变量在）。这个开关能让已经发布出去的迁移消失 ——
  那不是自动化该自己决定的事。接进流水线它会当场炸，而不是安静地做那件不可逆的事。
  所以这一条**得你在终端里现敲**。

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

### 但文件名对齐远远不够 —— 要做的是**内容对齐 + 逐段判断**

上面那两列比的是**路径**。已经咬过一次的是另一种：**路径一样，内容被换掉。**
超集闸门对此一声不吭（它只比路径集合），`docs/tech-debt.md` 里有一条 🔴 记着
这个盲区。在补上机器闸之前，重出快照的人**必须自己跑这一步**：

```bash
git -C <公开仓> ls-tree -r HEAD | awk '{print $3"\t"$4}' | sort -k2 > /tmp/pub.blobs
git -C <私有仓> ls-tree -r HEAD | awk '{print $3"\t"$4}' | sort -k2 > /tmp/pri.blobs
join -1 2 -2 2 -o 0,1.1,2.1 /tmp/pub.blobs /tmp/pri.blobs \
  | awk '$2!=$3{print $1, $2}' \
  | while read -r path blob; do
      git -C <私有仓> cat-file -e "$blob" 2>/dev/null || echo "只活在公开仓: $path"
    done
```

最后那一列每一行，都是一段**只活在公开仓、重出快照就会消失**的内容。
逐条查清楚它该往哪边走。

⚠️ **别整个文件挑边。** 2026-08-23 那次实测到的形状是：同一个文件**一半比私有仓新、
一半比它旧**。`MacWelcomeView.swift` 里，公开仓有 fail-loud 提示块（私有 main 没有），
同时缺「直发包里 Apple 按钮不显示」那个修复（私有 main 有）。
「以公开仓为准」和「以 main 为准」在这个文件上**都会丢东西**。
正确做法是把两边都要的合进来，然后逐 hunk 核一遍公开仓那侧还剩什么没进来。

**第一列不空 = 反向漂移又发生了。** 那是这个项目已经犯过四次的错：
有人直接在公开仓上改东西，改完没回到私有仓，下次重出快照就把它弄丢。
（前三次分别是一条安全迁移、这份文件本身、`README_EN.md`；第四次是
`README.md` —— 两边一度是两份不同的文档，而超集闸门看不见这种事，
它只比对路径在不在，不比对内容。）

**已知缺口，说在前面**：快照仍然是人工步骤，这份文件也得靠人更新。
三道闸门拦得住「弄丢」「多带」「死链」，拦不住「这份文件写得不对了」。
改了生成方式，记得回来改它。
