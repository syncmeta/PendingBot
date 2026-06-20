# Durable Objects(各自角色)

Cloudflare Durable Object(DO)= 一个全局可寻址、单实例、带强一致存储的对象。大绿豆用一组 DO 各管一块"必须强一致 / 必须单写者 / 必须挂住长连接"的状态。相关:[Edge](edge.md) · [Voice Container](voice-container.md) · [KV](kv.md) · [钱包概念](../../shared/concepts/wallet-pnc.md) · [边缘读路径概念](../../shared/concepts/read-path.md)。

**逻辑 — 为什么用 DO**
KV / Postgres 解决不了的三件事,正是 DO 的本职:
- **强一致 + 单写者** — 同一个键(同一个会话 / 用户 / 房间 / subject)永远落到同一个实例,天然串行化,不会有两个请求打架。
- **挂住长连接** — 可休眠的 WebSocket:idle 连接几乎不花钱,适合实时推送。
- **边缘就近状态** — 把热读 / 热门禁从单区 Postgres 挪到边缘,省跨洋往返。

每个 DO 类按"键"切实例(per 会话 / per 用户 / per 房间 / per subject),互不串扰。

**各 DO 的角色**

- **WalletDO**(per subject)— 计费的**边缘门禁闸 + 强一致缓存 + 用量 outbox**。它**不是账本**:只缓存一个余额 + 一段待 flush 的用量。门禁读本地(快、强一致),Polar 是余额事实源(最终一致,只做对账),周期性把用量 flush 给 Polar 并稀疏对账纠偏。详见 [钱包概念](../../shared/concepts/wallet-pnc.md)。

- **RealtimeHubDO**(per topic:`conv:<id>` / `user:<id>`)— **实时推送的扇出枢纽**,替代 Supabase Realtime 做投递管道。挂住每个客户端的可休眠 WebSocket,把 DB 变更(经 webhook 通知路径推入)扇出给所有订阅者。一个会话一个 topic、一个用户一个 topic。

- **RealtimeMeterDO**(per 语音会话)— 1:1 语音的**服务端防篡改计量**。从模型实时端的权威用量事件计费,客户端无法少报用量来逃费。

- **RoomVoiceDO**(per 群语音房间)— 群语音的**控制面**:权限、计费、在场 / 名单、编排。媒体不在这里——音频在 [Voice Container](voice-container.md) 里;DO 通过控制 socket 指挥容器。

- **RoomMediaContainerDO**(per 房间)— 群语音容器的**生命周期壳**:起 / 停容器、把入站 WebSocket 升级转发给容器。只管容器生命周期,音频 / 策略都不在它身上。

- **GroupRouterDO**(per 群会话)— 群聊的**防抖 + 小模型唤醒路由**。单写者维护一个滑动 60s 的消息时间戳窗口,据流量稀疏 / 繁忙决定立刻跑唤醒路由还是排到"下个安静时刻 + 8s",路由本身在 alarm 里跑(天然串行,同群不会两次路由打架)。

- **SessionProxyDO**(per crew 会话)— 跨设备**遥控面**。让同账号下任意客户端能观看并远程操控一个"agent 实际跑在另一台机器上"的 crew 会话。多个 viewer + 至多一个 runner 经 WebSocket 接入;runner 离线时把命令排队,(重)连时回放。位置无关(对端设备 / 云机共用同一条通道)。

- **ConvProjectionDO**(per 会话)/ **UserProjectionDO**(per 用户)— **边缘读投影**。把热读路径从单区 Supabase 挪到边缘:ConvProjection 存消息尾 + roster(授权门用)+ 单调 revision;UserProjection 存会话列表 + 未读 + revision。Supabase 退为最终一致的真源 / 事件源 / 重建源;webhook 写穿 + 冷启动回填。详见 [边缘读路径概念](../../shared/concepts/read-path.md)。

- **Sandbox**(per 会话,Cloudflare Sandbox SDK)— 容器化的**代码执行沙箱**,供聊天 agent 的 execute_code 工具用。短 idle 后自动休眠,不为废弃会话付内存 + 磁盘。

**为什么这么切**
- **按键串行**省掉一大类并发 bug:钱包扣费、群路由、投影写穿,都要"同一实体的操作排队",DO 的 per-key 单实例正好。
- **DO 管控制面 + 状态,重活外包**:媒体外包给容器([Voice Container](voice-container.md)),余额事实源外包给 Polar,prompt / config 走 KV——DO 只留那块"必须强一致 + 必须就近 + 必须长连"的核心。

**边界**
- DO **不是**通用数据库:存的是小而热的状态(余额、时间戳窗口、消息尾、连接表),不放大对象、不当账本。
- DO 命名空间**不可公网寻址**:都经 Worker 转发,且 Worker 已先校验身份 / 成员资格,DO 信任 Worker 设的内部头。

**注意**
- WalletDO 是**缓存 + 闸**,Polar 才是余额事实源——别把它当账本对账。
- 群语音里"控制 vs 媒体"严格分家:策略找 RoomVoiceDO,音频找容器,别混。

**现状** — 🟨 多数 DO 已落地并随各自 feature 验证:GroupRouter / RealtimeHub / 投影 DO(ConvProjection / UserProjection,已合 main 并端到端验过)✅ 偏成熟;WalletDO / RealtimeMeter / 语音相关 DO 代码 + 单测齐,但计费现网默认关、群语音多人实景 QA 仍待验,故整体记 🟨。
