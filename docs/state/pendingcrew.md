> 现状 handbook · pendingcrew 区。镜像 [期望 handbook](../handbook/README.md) 结构,每 session 强制刷。一条 = 一个概念/功能的实际状态。对齐 = 拿它和期望同路径并排看。

## vision
status: partial
现状: 本地核心可用——`BackendMode` 删除、Mac 后端恒本地、不开屏选模式、登录降为可选入口,本地工作流逻辑通双 build 绿;登录叠加层(scoped grant SSO / 遥控 / 信箱 / 毕业)多数代码已落、真机有尾巴;DAG / 责任分账仍有 edge-first 残留待收口。
证据: 双 build 绿;本地 crew 闭环(claude 终端 / codex app-server)已合 main 真机验过;scoped grant 单测绿、Apple/Google 直登 + 共享 keychain 跨 app 真读待 Xcode GUI 签名验
task: —

## concepts/crew
status: partial, pending-qa
现状: 代码已落、本地逻辑通;edge bot-当-captain 编排面已全退役(已验证删除),侧栏按机器分组 + 新建 crew 表单本机 GUI 像素验过,captain 报到链路 GUI E2E 过;"建 crew → 改名 → 派 worker"完整编排真机 QA 是尾巴。
证据: 审计处置 6 commit 全绿(edge typecheck 0 + 623 vitest)已合 main 已部署 prod;GUI 像素验 2026-06-16;captain 报到 GUI E2E 2026-06-17
task: 20260626-qa(Mac/真机 GUI QA 批次;像素验 #369/#342 已 completed)

## concepts/captain
status: partial, pending-qa
现状: captain = 被打机长标记的本地 session,edge bot-当-captain 整套已实删;本地工具 `answer_decision` / `rename_crew` + **`start_session` / `create_child_crew`**（2026-07-03 `feat/captain-spawn` 落地：机长可自主起 worker session、以当前 crew 为父建子 crew，子 crew 自动起子机长；命令走 `LocalCrewControlStore` 离线文件队列、depth cap=3）+ worker triage 单测跑通,报到链路 GUI E2E 过;真机改名 E2E + "拆 worker → ask → answer_decision"完整编排 + 机长自主 spawn 真机 E2E 是尾巴（归 #443）。start_session prompt/实装漂移已消除（tech-debt:61 收口）。
证据: 编排面退役已验证删除;MCP dispatch / 控制通道 round-trip 单测（含 spawn 命令队列 + depth cap，xcodebuild test 绿）;codex 机长报到 GUI E2E 2026-06-17(computer-use 驱动、截图存档)
task: 20260626-qa(Mac/真机 GUI QA 批次)

## concepts/governance
status: planned
现状: 设计哲学,几乎零落地——只有「永远有拍板方」一条落在 DAG·责任比例的规则里;党内民主有 captain persona + 「不谄媚」价值雏形;特区档 / 专才装备 / 长上下文暗访 / 信访 + 仲裁层 / leader override / 「担责与评估」整节(原理 7–11 + 使命三件套)全是指导思想,无对应 schema / 代码。
证据: 「永远有拍板方」见 DAG 篇规则;其余无证据 —
task: —

## concepts/dag-and-responsibility
status: partial, pending-qa
现状: 后端代码已落 + 单测验证——DAG + 环检测(递归 CTE 触发器)、责任比例 5 规则、tiebreaker 全有;但仍是 edge(Supabase RPC)实现、未随 captain 编排搬回本地(审计记的 🔴 结构债);跨主体确认走群权限矩阵后端有、iOS/Mac 客户端尚未消费;多主体认父 → 跨主体批准 → 份额生效完整链路未真机走。
证据: `crew_attach_as_child` + 内联单测(T2.3);`crew_recompute_shares` / `propose_split_distinct` + 单测(T2.4);客户端消费缺口 T1.2
task: T2.3 / T2.4 / T1.2(roadmap 编号)

## concepts/runtime-location-and-machine
status: partial
现状: machine 概念已落、本机可用——machine 清单 + 本机识别 + 侧栏按机器分组迁移上 prod、本机 GUI 像素验过;peer 清单 + 在线状态就位但真遥控执行链路未做(runner Phase 2);fly 仅表结构 + 选择 UI 占位,开通/计费/冷启动全未做(v1.1)。
证据: 迁移已上 prod;侧栏分组本机 GUI 像素验(单机隐藏机器选择、本机组带「+」)
task: —

## concepts/local-first
status: partial, pending-qa
现状: 本地为家心智落地——`BackendMode` 删除、Mac 后端恒本地、不开屏选模式、登录降为可选入口,双 build 绿、本地工作流逻辑通;scoped grant SSO 代码全落单测绿但 Apple/Google 直登需注册 capability、共享 keychain 跨 app 真读需 Xcode GUI 签名验(headless ad-hoc 签名 keychain -34018);登录叠加的「毕业」+ 远端 runner 唤醒仍是尾巴(worker 待部署 + 真账号 E2E)。
证据: 双 build 绿;邮箱 OTP + 扫码已是可用登录路径
task: 20260626-qa(Mac/真机 GUI QA 批次:Apple/Google 直登 + 共享 keychain 跨 app 真读)

## concepts/session-and-world-model
status: partial, pending-qa
现状: 世界观注入代码已落、机制 spike 实测验过——claude(`--append-system-prompt-file`)+ codex(`developerInstructions`)两路接线、本地 prompt bundled、单测 + 双 build 绿、真二进制实跑过 post/read/hook 闭环;"captain 拆 worker → worker 在世界观指引下正确用 ask/post_to_crew"完整编排 E2E 需真机走一遍(并入 Mac GUI QA)。
证据: claude 机制 spike 全验(append-system-prompt-file 遵守、hook 中途到达模型、auto mode 放行、statusLine 额度可读)
task: 20260626-qa(Mac/真机 GUI QA 批次)

## concepts/human-in-the-loop
status: partial, pending-qa
现状: 机制 spike 实测验过、本地代码全落——`ask` 工具 + 权限 PreToolUse hook + 待决策/待审批本地 store + 「🔔」通知 + 右栏内联答复卡片,swiftc driver/单测验过 macOS build 绿,codex 侧"crew 工具被自动拒"修通后报到 GUI E2E 过;captain-first triage 完整 E2E(ask → captain answer_decision 解阻塞 → 答不了 @人类)是尾巴,当前 captain 缺位时退化成「直达人类」已可用。
证据: `ask` 阻塞走 MCP + 权限走 PreToolUse hook deny/ask 实机 claude 验过
task: 20260626-qa(Mac/真机 GUI QA 批次)

## concepts/async-delegation
status: partial
现状: 部分机制已落——session 后台异步跑不阻塞、`ask` 异步、推送无轮询代码全落(本地单机真跑通);「驾驶舱看差生 session 补差」看板 MVP + 控制半边已落（cockpit-v2 合 main），机长自主 `start_session`/`create_child_crew`（2026-07-03 `feat/captain-spawn`）也让「机长判断→异步派活/拆组」端到端可跑;「人始终在高层、执行全异步」作为贯穿全局的统一原则已拍为北极星但尚未整体成形。
证据: session 后台跑 / `ask` 异步 / 去轮询改推送 均代码全落(远端活体推送真机是尾巴)
task: 20260626-cp(驾驶舱看差生 session 那部分)

## concepts/subprocess-safety
status: partial, pending-qa
现状: 代码已落、本地逻辑通——env 白名单 + codex 剥 `OPENAI_API_KEY` + 三前缀(`PENDINGBOT_`/`PENDINGCREW_`/`SUPABASE_`)硬拒,`LocalCodingAgentEnv` 收口为唯一 env 来源;Cancel「停不掉」根因已修(SIGTERM → 宽限 → SIGKILL 杀进程组,不依赖被吞回调)macOS build 绿;完全信任 + Cancel/长跑真机 GUI E2E 是尾巴。
证据: `LocalCodingAgentEnv` 收口;Cancel 根因修复(pty 子进程 setsid 独立进程组);macOS build 绿
task: 20260626-qa(Mac/真机 GUI QA 批次)

## concepts/whiteboard
status: partial, pending-qa
现状: 白板通信重做已落——本地白板 store + post/read + 每轮注入、双向 @ + 发送者身份 + reply 引用 + 去轮询(推送),edge 600+ vitest 覆盖、双 build 绿、本地 @ 直接注入唤醒 idle session 单机真跑通;远端活体 hub 推送真机 E2E 是尾巴(待真账号 + 部署)。
证据: 真二进制实跑闭环验过;edge 600+ vitest;双端 build/test 绿
task: —

## concepts/reconciliation
status: partial
现状: 三本账已立——期望(docs/handbook,纯意图)+ 现状(docs/state 三区镜像)+ task(docs/tasks 第三本账)可并排对照、互链(链只为导航)。期望页 sweep 三区(pendingcrew/pendingbot/shared)已收口纯意图;stack 区(24 篇)待定(无 docs/state/stack.md 镜像)。引擎其余 = 驾驶舱渲染 + 看差生 session,随驾驶舱未落。**对齐靠人读两本、不自动检测 drift / 不做一致性断言(见边界)**——曾建的 reconcile-check 自动断言已按此定调撤回。
证据: docs/state/ 三区已建(705694cd);三区 sweep 已落(pendingcrew d10ae8a2 + pendingbot/shared);task 账本 docs/tasks/ 已立;递归自指——大绿豆 handbook 自身即首个对账对象
task: 20260626-tl(task 账本已落) / 20260626-cp(驾驶舱待建)

## concepts/cockpit
status: planned
现状: 规划——驾驶舱(对账的呈现 + 控制面、看板半边渲染两本 + task、控制半边 captain 看差生 session、per-crew 沿 DAG 子树过滤视图)模型已拍定;dashboard / 渲染 / per-crew 过滤切片 / 控制半边生 session 编排均未实现;crew 父子 DAG 已有但「沿子树聚合成驾驶舱」整个未做。
证据: 无落地证据(模型已拍定,MVP 设想成文) —
task: 20260626-cp

## features/three-pane-ui
status: partial, pending-qa
现状: 三栏结构 + 中栏群聊 + 右栏多 session 切换代码已落——左栏按机器分组本机 GUI 像素验过、中栏 vendor PendingBot 聊天视图 + adapter 深/浅色对齐;右栏多 run 并存 + 切换条 + 两种 runner 窗口双 build 绿(codex transcript 真机渲染随 Mac GUI QA);iPad 两栏壳双 build 绿、真账号 E2E 是真机尾巴(模拟器无登录态进不到壳)。
证据: 左栏分组 GUI 像素验 2026-06-16 / #369;中栏深浅色群聊全要素对齐看过
task: 20260626-qa(Mac/真机 GUI QA 批次)

## features/create-crew-and-session
status: partial, pending-qa
现状: 新建 crew 表单代码已落、本机 GUI 像素验过——表单逐项与 spec 吻合(标题自动占位「Captain 来取名」/ CrewGround 实时路径 / 机长默认 Codex / 单机隐藏机器行 / 选项平铺左对齐);验证时刻意没真建 crew(避免污染用户真 crew),「点建 → captain 起来 → 命名」端到端 + 子 crew 挂父是尾巴。
证据: 本机 GUI 像素验 2026-06-16 / #342;双 build 绿
task: 20260626-qa(Mac/真机 GUI QA 批次)

## features/runner-backends
status: partial, pending-qa
现状: 两种 runner 后端代码全落——claude 终端(SwiftTerm 字节级)flag 本机实测、本机闭环 build + 单测绿;codex app-server 协议对真 schema 逐字段校准(修 4 个 inbound 解码 bug)、真跑一轮 turn 逐字段吻合 + 真计费 token tick、认证自动继承 `~/.codex/auth.json`;codex 机长两个真 bug(crew 工具被拒 / session 卡死)已根治 GUI E2E 验;codex transcript 活体像素渲染 + 额外权限审批回包形状(潜伏 bug 记 tech-debt)是尾巴,v1 不做逐字流式。
证据: codex schema 校准 2026-06-16(codex-cli 0.137.0);codex 机长修复 GUI E2E 2026-06-17(截图存档)
task: 20260626-qa(Mac/真机 GUI QA 批次)

## features/session-crew-comms
status: partial, pending-qa
现状: 群聊通信重做代码全落——edge 600+ vitest 覆盖(入站/出站 @ + reply + 发送者身份 + reply 引用)、双端 build/test 绿(去轮询、事件驱动唤醒、composer @ picker + reply 手势)、本地 @ 直接注入唤醒 idle session 单机真跑通、实时推送客户端跨平台化 iPad 也接;远端 runner 唤醒 + session→@ edge 上行 + 活体 hub 推送真机 E2E 卡在「本地 ↔ edge 绑定」尾巴(`CrewRelayAgent.push` 未透传 mentions/reply_to),记 tech-debt。
证据: edge 600+ vitest;双端 build/test 绿;本地单机真跑通
task: —(尾巴记 tech-debt)

## features/session-health
status: partial, pending-qa
现状: v1 代码全落（2026-07-05 `feat/session-health`）——claude PTY 去 ANSI 文案扫描（`SessionHealthScanner`,短语表从本机 claude CLI 2.1.201 二进制 strings 实测核出,每 Kind 只报一次）+ codex `account/*` server-request 单列翻健康位（原 unsupported 静默丢）;浮出三处:成员状态点红(error 档)、成员列表副行显故障详情、白板 fail-loud 一条(category=error)。SessionBackend 协议加 health/healthPublisher,CrewSessionRun 镜像+去重播报。活体验证（真把 claude 登出/额度打满看三处浮出）需真机 GUI,归 #443。
证据: SessionHealth.swift + SessionHealthTests 9 项(去 ANSI/跨 chunk/去重/codex 分类)绿;PendingCrewTests 276 全绿;macOS test + iOS Sim build 绿
task: 20260626-qa(Mac/真机 GUI QA 批次)

## features/session-quota-and-profile
status: partial, pending-qa
现状: v1 代码全落（2026-07-05 `feat/model-effort-quota`）——①模型/effort 三入口：composer 双 picker（稳定别名,清单收 `SessionLaunchOptions`）、机长 `start_session` 带 model/effort（全链透传到 SessionConfig argv）、session `set_session_profile` 自切（claude 注入 /model /effort 斜杠命令分两笔隔 700ms;codex 无通道→白板说明）;②额度可见：`QuotaCenter` 10 分钟双源刷新（claude `-p "/usage"` 文本解析 + codex rollout jsonl rate_limits,均 2026-07-05 实测定档）→侧栏额度行（≥90% 染橙）+ quota.json 快照 → session `get_quota`;③额度重置自唤醒：`schedule_wakeup(after_minutes|at, note)` → wakeups.json 持久化 + 定时器（app 重启 rearm）→ 到点注入回原 session/已退白板留痕;世界观 §11（中英）教「查额度→收尾→约醒」纪律。活体验证（真起 session 调三工具、真跨额度窗唤醒、侧栏额度行渲染）归 #443。
证据: AgentQuotaTests 5 + McpServerQuotaToolsTests 9 + spawn model/effort 3 项全绿;全量 293 绿;macOS test + iOS Sim build 绿;额度数据源实测记录见 progress 2026-07-05 条
task: 20260626-qa(Mac/真机 GUI QA 批次)

## features/cross-device-control
status: partial, pending-qa
现状: 遥控地基 + PendingCrew 侧 viewer 实时层已落——按 session 绑定中转点 SessionProxyDO(viewer/runner 角色 + 离线队列 500 上限 + 持久信箱权威源 + 路由侧角色鉴权)+ WS 协议 + 单测;runner 边跑边推 `session.state`「WS 替轮询」= DONE。注意(2026-06-26 refresh 校正):原 iOS PendingBot 那套 crew/viewer 已于 095dfc2b(2026-06-15)整体删除(待重做),当前 viewer 链只在 PendingCrew(Mac/iPad)端;真机只验过早期 3s HTTP 轮询只读 viewer(2026-06-02),带真 device-grant 的完整 WS 往返(runner 连上→DO 推 state→viewer 实时看到→viewer 发命令)尚未真机验(T5.3 两设备 E2E 尾巴),仅验过 prod 路由活性(wss 401)。远端"下指令真注入运行中 session"卡在本地↔edge 绑定尾巴(worker 部署被权限层拦待用户手动部署);fly 云遥控 + 终端字节级跨端隧道未做(v1.1 / 另一条线)。
证据: SessionProxyDO apps/edge/src/durable-objects/session-proxy.ts + protocol + 单测 apps/edge/tests/session-proxy.test.ts(c7b2cd2d);PendingCrew viewer apps/pendingcrew/Sources/Mac/LocalRunner/SessionProxyClient.swift + Services/CrewRealtimeClient.swift;iOS PendingBot viewer 已删(095dfc2b);完整 WS E2E 未真机验(tech-debt T4.5 / progress T5.3)
task: —(T5.3 两设备 E2E + 远端注入尾巴记 tech-debt)
