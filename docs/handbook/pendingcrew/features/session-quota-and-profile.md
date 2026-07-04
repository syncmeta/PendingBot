# Session 额度与模型/effort 配置

> 订阅额度是 crew 真正的燃料：所有本机 session 共享同一个池，烧穿了全员停摆。本篇讲三件事怎么成为**可规划的资源**：模型/thinking-effort 按任务难度调配（人与 session 都能调）、剩余额度对人与 agent 都可见、额度将尽时 session 能自己「收尾 + 约在重置后唤醒」。相关：[Runner 后端](runner-backends.md) · [创建 crew 与 session](create-crew-and-session.md) · [Session 健康感知](session-health.md) · [Session 与世界观](../concepts/session-and-world-model.md)。

## 逻辑

**1. 模型 / effort 是 per-session 的调配旋钮，三个入口一套语义：**

- **人起 session**：composer 里 runner 旁两个 picker（模型别名 + effort 档），默认「默认」= 交给 CLI 自定。
- **机长派 worker**（`start_session`）：可带 `model` / `effort` —— 简单机械活给轻模型/低 effort 省额度，难活给高档。
- **session 自己**（`set_session_profile`）：按任务阶段自调 —— 收尾降档、攻坚升档。claude 立即生效（等价 `/model`、`/effort` 斜杠命令）；codex 没有中途切换通道（model 绑 thread、effort 绑启动参数），只能另起 session 换配置。

模型用**稳定别名**（opus/sonnet/haiku 这类由 CLI 解析到当代最新），不锁带日期的 slug —— 换代不用改配置。有效值归 CLI 校验：起不来的错误照 fail-loud 浮出，平台不维护第二份模型清单。

**2. 额度对人与 agent 都可见。** 两家 CLI 的额度事实是「窗口已用百分比 + 重置时刻」（5 小时滚动窗 + 周窗；**没有剩余 token 绝对值**）。系统定期汇总成一份快照：人看侧栏额度行（将尽染橙、hover 看重置时刻），session 调 `get_quota` 拿同一份数据。

**3. 额度将尽 → 收尾 + 约醒，而不是跑到被强停。** session 的标准动作：`get_quota` 看重置时刻 → 把手头活收尾成可交接状态（该提交的提交、进展发白板）→ `schedule_wakeup` 约在重置后几分钟、`note` 写清醒来继续什么 → 停手。到点系统把 note 注入回该 session 叫醒它；session 已退出则白板留痕，机长可见并决定是否重派。唤醒**跨 app 重启存活**（持久化、启动重挂）。

## 为什么

- **额度是共享池，必须全员可感知。** 一个 session 闷头把周窗烧穿，其它 session 与人全部陪停 —— 这正是「感知不到额度」的实际代价。把百分比+重置时刻摆到侧栏和 `get_quota` 里，人和 agent 用同一份事实做规划。
- **「收尾 + 约醒」把额度中断从事故变成计划。** 没有这个机制时，额度耗尽 = 活卡死在半截、人半夜来救；有了它，session 自己把中断点选在干净的边界上，重置后自动续跑 —— 长活跨额度窗口成为常态操作而非例外。
- **模型/effort 调配是省额度的第一杠杆。** 同一个 session 的活往往难易混杂：全程旗舰+高 effort 是浪费，全程轻模型做不动难题。把旋钮交给最知道当前难度的一方（派活的机长、干活的 session 自己）。
- **只用百分比+重置时刻、不编造余量**：CLI 就给这些（实测核定），显示层不推算「还能跑几小时」这类会骗人的数字。

## 用在哪 · 长什么样

- **侧栏底部额度行**：`Claude session 80% · 周(全模型) 23% · Codex …`，任一窗 ≥90% 整行染橙；hover 显示完整窗名与重置时刻。本机模式与登录态都显示（额度属于本机 runner，与 edge 登录无关）。
- **composer**：runner picker 旁「默认模型」「默认 effort」两个下拉。
- **工具面**：`get_quota()` / `schedule_wakeup(after_minutes|at, note)` / `set_session_profile(model?, effort?)` 对所有 session 开放；`start_session` 的 `model`/`effort` 参数仅机长。世界观 §11 教用法与纪律。

## 示例

机长把「批量改 200 处调用点」派给 worker 时带 `model: "haiku", effort: "low"`。worker 跑到一半 `get_quota` 发现 session 窗已用 92%、40 分钟后重置：它把已改完的部分提交、往白板发「改到 src/foo 前半，剩余清单在 PR 描述」，然后 `schedule_wakeup(after_minutes: 45, note: "继续批量改调用点，从 src/bar 开始，清单见 PR #12 描述")`，停手。45 分钟后系统注入唤醒消息，它读 note 和白板接着干 —— 全程没有人介入。

## 边界

- **本篇管额度的可见与规划，不管计费**——订阅额度是两家 CLI 的自带资源，与大绿豆的钱包/计费体系无关。
- **不做「事前预算/配额分配」**（给某 session 划拨 N%）——两家 CLI 无此原语，池就是共享的；v1 靠可见性+纪律。
- **额度数据是快照不是实时流**（约 10 分钟刷新）——够规划用；到顶瞬间的实时信号归 [Session 健康感知](session-health.md) 的 usageLimit 检测。
- **codex 的中途切换缺位是上游协议边界**，不在本篇修——变通是 `start_session` 另起。

## 注意

- ⚠️ **claude 额度取自 `claude -p "/usage"` 文本**（实测为本地 control-request、不烧额度、CLI 自理 OAuth）——文案随 CLI 版本变可能解析不出（表现为额度行消失，不是错数据）。升级 claude 后失灵先重核输出格式。结构化的 `/api/oauth/usage` 端点存在但未文档化且要自管 Keychain/token refresh，留作后续升级路径。
- ⚠️ **codex 额度读最新 rollout jsonl**（每轮落盘）——codex 长时间没跑过任何 turn 时数据会陈旧；快照带 `fetchedAt`，消费方自己看新鲜度。app-server 的 `account/rateLimits/read` 更实时，是后续增量。
- **`schedule_wakeup` 的 note 必须自足** —— 醒来的 session 只有 note 和白板，没有你此刻的上下文。
