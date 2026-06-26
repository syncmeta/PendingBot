> 现状 handbook · pendingbot 区。镜像 [期望 handbook](../handbook/README.md) 结构,每 session 强制刷。一条 = 一个概念/功能的实际状态。对齐 = 拿它和期望同路径并排看。

## vision
status: partial, pending-qa
现状: 方向定稿、三端壳就位;「知错」相关核心多数代码已落,「桥梁 / todolist / 富感知 / 破茧网络」整体仍在规划;端到端真机 QA 是最大未验区。
证据: 三端共享 UI 与社交地基已合 main 并端到端验过(bot 邀请 D1);复盘 / 网上冲浪等多数代码已落待逐项活验;端到端全链 QA 未跑。
task: —

## concepts/bot-persona
status: partial, pending-qa
现状: 模型池 + 预设解析 + 盲盒抽取 + config 旋钮 + KV 缓存失效都在代码里跑,model-roles 已收口进 board 可配并部署;盲盒/换模型的端到端真机冒烟未做。
证据: 代码已落;盲盒/换模型端到端真机冒烟需登录态 GUI 构建(progress #297)。
task: —

## concepts/bot-visibility
status: done
现状: private / public_invite 两档模型已落地并在跑,`public_open` 已整档删除,RLS / 单向公开触发器 / 两档分支均按现状实现。
证据: `public_open` 删除迁移 `20260527091508` 已 push live;配套邀请链路端到端验证见 bot 邀请(D1,2026-06-01)。
task: —

## concepts/bot-social-graph
status: partial, pending-qa
现状: 社交图快照注入每回合、`get_bot_friends` 三类访问门、`invited_by` 留痕、公有 bot `ask_friend`、进群自我介绍都在代码里;主动问询完整端到端未跑。
证据: 代码已落;ask_friend 回流的完整端到端需真账号 / 真消息触发,属 pre-launch 未跑尾巴(见 delegation)。
task: —

## concepts/proactivity
status: partial, pending-qa
现状: 主动姿态成立(复盘 / 来信两个出口的机制都在代码里),心智锚点已校正为次要特质(稳定);两个出口落地成熟度不一,完整端到端真机验证是共同尾巴。
证据: 各 feature 篇有机制代码;端到端真机验证为 pre-launch 共同尾巴。具体可用性以各 features/ 篇为准。
task: —

## concepts/delegation
status: partial, pending-qa
现状: `delegate_to_specialist`(模型 slug + fallback 路由 + 计费审计)、`ask_friend`(投递 + 开问询 + 推送)、`submit_inquiry_answer`(活跃融入 / 不活跃冒泡两路由)都在 edge 代码里、按可见性门控挂载;完整端到端未跑。
证据: edge 代码已落;公有 bot → 真好友 → 回答 → 回流的完整端到端需真账号 / 真消息触发,pre-launch 未跑尾巴。
task: —

## concepts/rich-perception
status: planned
现状: 富感知整套未建——模型已拍定(A 实时信号 / B 派生 stance / C 反思养素养),但「环境块注入 + stance 派生 + 素养回写」还没落;复盘、bot 画像、skill、钱包是现有零件。
证据: —
task: —

## concepts/todolist
status: planned
现状: 给人看的 per-crew repo todo markdown 文件,本地 + git 跟踪 + session 直接读;整套规划中,尚未实现。
证据: —(frontmatter status: planned,无现状段)
task: —

## features/information-architecture
status: partial, pending-qa
现状: 五个 tab(消息 / 好友 / Crew / 来信 / 我)代码全部落地、三端共享 `FeatureSurface` 渲染,Mac 首屏崩溃已修;iPad / iPhone 真机登录态可视回归未逐一留证。
证据: `feat/tri-platform-ui` 已合 main;本机 GUI 实测过消息 / 好友 / 来信三 tab 渲染真账号数据;iPad 三列 / 深链切 tab 并入三端真机 QA。
task: —

## features/proactive-lookback
status: partial, pending-qa
现状: 复盘 / 校正代码已落、已部署,自动节奏 + 手动触发 + 笔记实时推送 + 下一轮自动接话主路径在线上跑过;触发「点」仍是聊天轮次而非真定时。
证据: `runLookback` 在 prod worker;尾巴——`LOOKBACK_INSTRUCTION` prompt 早期漏迁 Langfuse(已记审计),端到端真机视觉验证未单独留证。
task: —

## features/web-surf
status: partial, pending-qa
现状: 聊天里现查(in-chat)代码已落、已部署、属常规可用;主动探索 + 写信走来信管线、代码已落已部署、主路径线上跑过,端到端真机视觉验证未单独留证。
证据: 已部署 prod worker;`surf_runs` / `scroll_runs` 为死表待清理(已记 tech-debt,低优先);`/surf` slash 命令未单独连出。
task: —

## features/envelope-inbox
status: partial, pending-qa
现状: 来信信道 + 真人写信端点代码已落、已部署,bot 来信主路径在线上跑过,属常规可用范围的成熟功能;无专门端到端验证留痕。
证据: 已部署 prod worker;真人来信 `/v1/envelope/letter`(互为好友门禁)代码在,端到端真机视觉验证未单独留证。
task: —

## features/add-friend
status: done
现状: 加人类好友全链(handle 查找 / 申请 / 同意 / 双向待定捷径 / 同群加好友 / 备注 / 删好友)已落地,是当前主路径。
证据: 实现在 `friend-requests.ts` + `contacts.ts`。
task: —

## features/bot-invites
status: done
现状: bot 纯邀请制(invite-token 模型,关联到签发者 + `invited_by` 留痕)已端到端验证,旧 slug / `public_open` 方案已彻底返工删除。
证据: D1,2026-06-01;DB + Edge(已部署 prod worker)+ iOS 全返工,收件人真机走通完整链(universal link → 预览 → 添加 → redeem → 进聊天,DB 确认留痕,无效 token 报错)。残留(低风险):签发侧管理页未单独像素验。
task: —

## features/group-invites
status: partial, pending-qa
现状: 群每人一码(per-inviter token + 成员/申请行 `invited_by`)后端已落 + push live + typecheck 绿,iOS 扫码 → 预览 → 加入核心已编译验证(BUILD SUCCEEDED)。
证据: 后端迁移 `20260601082502`(D2),`group-invites.ts`;残留——`/g/` universal-link 深链点击 presenter 未接线(扫码路径已通),模拟器视觉验证未单独做。
task: —

## features/voice
status: partial, pending-qa
现状: 代码全落——1:1 双传输(sideband WebRTC / proxy WebSocket)+ 群语音 v3(控制面 RoomVoiceDO + 媒体容器 + 重连容灾 + 群分摊计费),审计确认无 v2「DO 内混音」残留;多人多 bot 端到端真机 QA 未留证。
证据: stale-model 审计确认 v3 无 v2 残留;群语音抗断续 / 多 bot 同台 / call-admin 流转的真机通话验证属待办。
task: —

## features/model-blindbox
status: partial, pending-qa
现状: 代码全落(DB 迁移 + 揭示/猜/换模型端点 + bot 调的「猜一猜」工具 + 三端 UI),迁移已 db push prod、edge typecheck + vitest 全绿、三端 build 绿、已合 main;真机端到端冒烟未留痕。
证据: 已合 main + 迁移 push prod;尾巴——抽→猜→regen→换具体→disclose 全流程需登录态验证未单独留痕,持久猜测记录「重开回放」UI 未做(tech-debt)。
task: —

## features/create-bot-presets
status: partial, pending-qa
现状: 一页式建 bot + 规则驱动模型预设已合 main、DB 迁移 push prod + 部署,`latest_in_series` 旗舰策略 + 列表性能修复已上线、端点侧真验通过(返回真旗舰);app 内视觉确认待。
证据: 已部署 prod;尾巴——iOS 登录态拉端点确认 + 一页式流程真机/模拟器视觉验证需登录态 GUI 未留痕,部署中踩过「db push 不失效 KV 缓存」坑(已补 runbook)。
task: —

## features/tri-platform-ui
status: partial, pending-qa
现状: 三端共享地基 + 全 feature slice 跨平台 + iPad/Mac 三列壳已合 main,Mac 首屏本机 GUI 截图验过、iPhone 实装无回归;三端真机/模拟器完整验证仍待。
证据: `feat/tri-platform-ui`(71 commit)已实现并合 main(2026-06-09,`b4d0b131`),`Sources/Mac/` 删到只剩登录壳,双端 build 绿;已知降级尾巴各记 tech-debt(Mac composer 缺三横幅 / 相机缺失 / 二维码名片占位等),真机验时补。
task: —
