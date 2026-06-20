# 本机子进程安全

> PendingCrew 在你的机器上拉起 claude / codex 子进程时,采取什么安全姿态。一句话:**完全信任(不沙盒)+ 最小 env 卫生(不把 PendingCrew 自己的 secret 泄给子进程)**;不设 timeout,但 Cancel 标配。相关:[本地为家](local-first.md) · [人在回路](human-in-the-loop.md) · [runner backends](../features/runner-backends.md)。

## 逻辑

### 完全信任,不沙盒

PendingCrew **不做沙盒**。本机起的 agent,跟用户自己开终端跑 `claude` / `codex` 完全一样——默认拥有用户登录账户的全部权限(能读 ssh key、能 git push、能调任何本机已登录的服务)。

**权限管理是 claude code / codex 自己关心的事**(它们各自有 auto / bypass 等模式开关)。PendingCrew 只是一个遥控器,不在系统层强加 seatbelt / sandbox-exec。对用户的承诺要讲明白:「本机 agent = 你的完整登录用户权限。」

### 最小 env 卫生

唯一的底线:子进程的环境变量**不继承 PendingCrew 自己的 secret**。这不是沙盒,只是「别多此一举地把自己的 token 泄给子进程」。

实现成一个**白名单**(比「黑名单几个 secret」更稳):

- **透传**:`PATH` / `HOME` / `SHELL` / `LANG` / `TERM` / `USER` / `LOGNAME` / `TMPDIR` 这组基础 shell var,加上 `LC_*`(locale)整段。PATH 缺省时给个保守 fallback(否则子进程 spawn 的 grandchild 如 git 找不到工具)。
- **不透传**(默认就不在 env 里,且对 `PENDINGBOT_` / `PENDINGCREW_` / `SUPABASE_` 三个前缀加防御性硬拒):PendingBot device-grant token、Keychain 凭据、任何 PendingCrew 自己的服务 secret。
- **codex 额外剥 `OPENAI_API_KEY`**:codex app-server 靠 `~/.codex/auth.json` 走 ChatGPT 订阅计费;若父进程导出了 `OPENAI_API_KEY`,子进程会翻到按量 API 计费。所以对 codex 一律剥掉这个 key。

### 不设 timeout,Cancel 标配

- **不设 timeout**:大任务可能跑几十分钟,超时是 claude code / codex 自己关心的事,PendingCrew 不强加上限。
- **Cancel 必做**:用户点「停止」→ 标准 `SIGTERM` + 几秒宽限 + `SIGKILL` 兜底(连进程组一起杀)。这是 coding agent UI 的标配,不算额外功能。

## 为什么

- **沙盒在这里是错的工具。** 用户装 PendingCrew 就是要它替自己跑 claude / codex——这两个工具本来就被设计成在用户完整权限下工作(改代码、跑测试、推分支)。给它套个沙盒,要么把正常工作流锁死,要么沦为聊胜于无的半拉子隔离。真正的高危分级早已由 CLI 自己的 auto mode 分类器做了(见 [人在回路](human-in-the-loop.md)),PendingCrew 再叠一层只会重复且更差。
- **env 卫生用白名单而非黑名单,是被一次差点漏掉的迁移教训逼出来的。** 按名枚举要拒的 secret,在 key 改名时会漏(`service_role` → `sb_secret` 那次迁移差点就漏了)。`SUPABASE_` 整个前缀封死、基础 shell var 走白名单,新增 secret 默认就进不去——sub-agent 也没有任何合法理由拿到 PendingCrew 的 supabase 凭据。这条卫生不是沙盒,只是把「自家钥匙别塞进别人口袋」做干净。
- **Cancel 比 timeout 重要。** 人在看着进度,卡了 / 跑偏了点一下停掉即可;预设一个 timeout 反而会在长任务正常跑时误杀。

## 用在哪 · 长什么样

- **用户侧**:右栏 session 窗口有「停止 / 取消」按钮,点了走 SIGTERM → SIGKILL。
- **告知**:产品要对用户明示「本机 agent 拥有你的完整登录权限」,这是知情同意,不是藏着掖着。

## 边界

- **不做进程隔离 / seatbelt / 容器**——本机完全信任。
- **不强加 session timeout 上限**。
- env 卫生**只是不泄 PendingCrew 自己的 secret**,不是限制 agent 能力——agent 该有的本机权限一个不少。

## 注意

- ⚠️ **Cancel 曾有个「停不掉」的真坑**:内嵌终端的 `terminate()` 会取消退出监听并关 IO,导致进程真退出后回调永不触发、状态永远停在「运行中」。修法是不依赖那个被吞的回调,直接走 SIGTERM + 宽限 + SIGKILL 杀进程组(pty 子进程是 setsid 独立进程组)。引用 Cancel 行为时以这个为准。
- ⚠️ **「完全信任」不等于「没有任何审批」**:computer-use 这类敏感操作仍走 PreToolUse hook 直达人类审批(见 [人在回路](human-in-the-loop.md))。完全信任说的是「不在 OS 层套沙盒」,不是「任何操作都不问」。
- **env 卫生是白名单实现**——比 spec 原本「黑名单几个 secret」的描述更严。新加要透传的 var 得显式进白名单,否则到不了子进程。

## 现状

🟨 **代码已落、本地逻辑通,真机 GUI 上的 Cancel / 长跑还需端到端验。**

- ✅ **env 白名单 + codex 剥 `OPENAI_API_KEY` + 三前缀硬拒**:代码就位、`LocalCodingAgentEnv` 收口为唯一 env 来源。
- ✅ **Cancel 的 SIGTERM → SIGKILL 进程组兜底**:「停不掉」根因已修(不依赖被吞回调),macOS build 绿。
- 🟨 **完全信任 + Cancel 的真机 GUI 端到端**(起真 agent → 跑长任务 → 点停止 → 进程组真被杀)并入 Mac GUI QA,未单独像素验。
