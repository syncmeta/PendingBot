# 创建 crew 与 session

> 用户从零起一个 crew(以及 crew 里的 session)时,面前的那张表单:给 crew 取名、选它跑在哪台机器、定工作目录、挑 captain 用哪个 runner。本篇讲这张表单的每个选项是什么、默认值怎么定、为什么这样默认。相关:[Crew](../concepts/crew.md) · [运行位置与 Machine](../concepts/runtime-location-and-machine.md) · [Session 与世界观](../concepts/session-and-world-model.md) · [Runner 后端](runner-backends.md) · [三栏布局](three-pane-ui.md)。

## 逻辑

新建 crew 是 PendingCrew 的入口动作。一张表单收齐四件事,其余全用合理默认顶上,让用户**最少能只填零项就建出一个能干活的 crew**:

1. **标题** —— 自动 / 手动两档。默认**自动**:不填,占位写「Captain 来取名」——意思是先建出来,让 captain 第一轮自己起个名。想手动就切到手动档直接输入。
2. **机器(machine)** —— 这个 crew 的 agent 跑在哪台机器上。**只有「已登录且机器数 > 1」才显示这一行**;单机(或未登录)时根本不出现,crew 默认挂本机。详见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md)。
3. **工作目录** —— crew 的默认 cwd。默认走 **CrewGround**:在 `~/CrewGround/<随机地名>/` 下开一个新目录,表单实时显示将要用的路径(`~/CrewGround/<地名>`);也可手动指定一个已有目录,或沿用上次用过的。
4. **机长 runner** —— captain session 用 Claude Code 还是 Codex。两个平铺药丸,**默认 Codex**。

建出来之后,crew 默认拉起一个 **captain session**(用上面选的 runner)。captain 是个常驻 session,负责把模糊意图拆给 worker、做群聊里的 triage(见 [Crew 与 Captain](../concepts/crew.md) / [人在回路](../concepts/human-in-the-loop.md))。后续 worker session 在群聊 / 右栏里另起,可以各自覆盖工作目录(开 git worktree 隔离或换分支),但都派生自 crew 的这套默认。

## 为什么

- **「能只填零项就建出来」是刻意压低门槛。** 给开发者的工具容易堆出一屏配置;PendingCrew 反过来——标题让 captain 取、目录用 CrewGround 随机名、机器单机时不问、runner 给个默认值。想精确控制的人每一项都能改,但默认路径一步到位。
- **标题默认让 captain 取名,是因为「这个 crew 在干嘛」往往建的时候还没想清。** 与其逼用户先憋一个名字,不如先建起来、让 captain 第一轮根据任务自己命名,更贴合「先开干、边干边清晰」的工作流。
- **工作目录默认 CrewGround 随机地名,是为了「随手建、不踩已有项目」。** 不给默认目录,用户每次都要想「放哪」;默认丢进一个隔离的随机命名目录,既不污染现有仓库、又天然每个 crew 一块独立地。要在真实项目里干活时再手动指目录。
- **机器选择只在「登录 + 多机」时出现,避免给单机用户制造不存在的选择。** 没登录就只有本机一台、没有机器清单;有清单但只有一台时,选了也只能选本机。把这一行藏到真有得选时才显示,是「配置随能力出现」。
- **机长默认 Codex,是当前的取舍(可随产品判断调整),不是铁律。** 两个 runner 都支持当 captain;哪个当默认是 UI 默认值层面的事,真正的能力差异见 [Runner 后端](runner-backends.md)。

## 用在哪 · 长什么样

- **入口**:左栏本机机器组的「+ 新建 crew」。其它机器组(peer / fly)暂时只能遥控查看,不带建 crew 入口(见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md))。
- **表单**:一张轻表单——标题(自动 / 手动切换,自动时占位「Captain 来取名」)、工作目录(CrewGround 默认 + 实时路径预览 + 手动 + 用上次)、机长 runner(Claude Code | Codex 两个平铺药丸,默认 Codex);机器行仅在登录 + 多机时出现。选项全平铺、框常驻、左对齐(密度优先的工作台风格)。
- **建子 crew**:在 crew 详情里有「新建子 crew」入口,自动把当前 crew 挂为父——分类 / 层级用**父 crew 承载**,不再用 tag(见「注意」)。

## 示例

你在 Mac 上打开 PendingCrew(没登录,纯本地)。左栏只有「本机」一组,点「+ 新建 crew」。表单弹出:标题留空(占位「Captain 来取名」),工作目录显示 `~/CrewGround/Reykjavik`(随机地名,你也可以改成 `~/code/myapp`),机长是 Codex(默认)——没有机器选择行(单机)。你什么都不改,直接建。crew 出现在本机组下,一个 Codex captain session 被拉起,第一轮它根据你随后给的任务把自己命名为「鉴权重构」。

## 边界

- **本篇只讲「建 crew / session 的那张表单」**:每个选项是什么、怎么默认。机器分组规则见 [运行位置与 Machine](../concepts/runtime-location-and-machine.md);两种 runner 的窗口形态见 [Runner 后端](runner-backends.md);session 启动时注入的世界观见 [Session 与世界观](../concepts/session-and-world-model.md)。
- **机器选择不是本篇主题**,只是表单里的一行;它的完整语义(本机 / peer / fly 派生自机器清单)在 machine 概念篇。
- **未登录时没有机器清单**——永远只有本机一台,不显示机器选择,crew 不挂任何机器(见 [本地为家](../concepts/local-first.md))。

## 注意 — 已改的旧建模(别写回)

- ❌ **用 `tag` 给 crew 分类** —— 已**连根拔除**(bot 工具 schema、客户端提案卡、edge select 全清)。crew 的层级 / 分类现在由**父子 crew 关系**承载;新建子 crew 时自动挂父,不再有 `proposed_tag` / tag 这一档。引用旧的「按 tag 归类 crew」一律作废。
- ❌ **bot 在群里「提案建 crew / 起 session」那套编排** —— `start_crew` / `start_session` / `create_child_crew` / `recruit_temp_bot` 等 edge bot 工具已随 stale-model 审计 R1 全退役(净删 ~1300 行)。建 crew 现在是**客户端动作**(PendingCrew 表单),不是 bot 在 bot-reply 里编排出来的。保留的 `create_crew_with_captain` / `POST /v1/crews` 是客户端建 crew 的活路径,不是 bot 残留。
- ⚠️ **建出来 ≠ 名字一定有** —— 自动档下 crew 初始可能没名字 / 占位名,要等 captain 第一轮命名;这是设计,不是 bug。

## 现状

🟨 **新建 crew 表单代码已落、本机 GUI 像素验过,真建 crew 的端到端是尾巴。**

- ✅ **表单与 spec 逐项吻合(本机 GUI 像素验,2026-06-16 / #342)**:标题自动·placeholder「Captain 来取名」/ 工作目录 CrewGround·实时 `~/CrewGround/<地名>` / 机长 Claude Code | Codex(默认 Codex)/ 单机隐藏机器行 / 选项平铺左对齐——全部对齐设计。验证时**刻意没真建 crew**(避免污染用户已有的真 crew),所以「点建 → captain 起来 → 命名」这条端到端没在 GUI 里走完。
- 🟨 **真建一个 crew、captain 启动并自命名、子 crew 挂父**:代码全落、双 build 绿,但完整端到端真账号验证是已知尾巴。
