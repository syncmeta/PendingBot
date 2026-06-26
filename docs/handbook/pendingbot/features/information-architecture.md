# 信息架构(五个 tab)

PendingBot 是一个三端(iPhone / iPad / Mac)IM。主导航固定**五个 tab**:**消息 · 好友 · Crew · 来信 · 我**。这五个的分工是整个 app 的骨架——每个 tab 答一个明确的问题,不互相吞功能。相关:[三端 UI](tri-platform-ui.md) · [来信](envelope-inbox.md) · [主动复盘](proactive-lookback.md)。

**逻辑** — 五个 tab 各管一件事:

- **消息** —— IM 主流。你和 bot、和真人、和群的所有**会话**都在这里,倒序按最近活跃排。这是日常入口,打开 app 默认落点。
- **好友** —— 你的**联系人**:bot 好友 + 真人好友。从这里发起新会话、管理 bot、扫码加好友 / 加 bot、看自己的名片二维码。是"找人 / 找 bot"的地方,不是"看对话"的地方(看对话在消息)。
- **Crew** —— PendingCrew 编排的**查看 + 遥控窗口**。crew 列表(扁平、按最近活跃)+ 进 crew 看群聊 + @session 发指令 / 批 permission / 看 session 状态卡。**它是个查看入口,不是编排台**(详见边界)。
- **来信** —— bot **主动写给你的信**的收件箱。倒序 feed,每封信一行(标题 + 摘要),点进去看正文 + 思考链。真人之间手写的信也落这里。详见 [来信](envelope-inbox.md)。
- **我** —— 个人中心:资料、钱包 / 余额、设置(外观 / 通知 / 注销)等账号级的东西。

**为什么**

- **五个而不是更少**:消息 / 好友 / 我 是任何 IM 的标配三件套。多出来的 **来信** 和 **Crew** 正好对应大绿豆区别于普通 IM 的两块:来信是 bot 替你探索、把有价值的东西写回来的收件箱(bot 不催自动写信给你),Crew 是与 PendingCrew 这条辅产品线的连接点。tab 的取舍直接反映产品定位——bot 替你探索 + crew 桥梁,是这俩让大绿豆不只是又一个聊天软件。
- **好友与消息分开**:联系人(静态的"有谁")和会话(动态的"聊了什么")是两种心智,合在一个 tab 会互相挤占。加好友 / 管 bot 这类低频但重要的动作放好友 tab,不污染高频的消息流。
- **Crew 在 PendingBot 只做轻量查看**:深度编排(完整 DAG、runner 配置、session 全日志、工作目录、machine 管理)是 PendingCrew 的事。两个产品"主 + 辅",PendingBot 看见 crew、PendingCrew 操作 crew,**互不吞功能**(党纲)。把完整编排塞进 PendingBot 的 tab 会越界。

**用在哪·长什么样**

- **iPhone**:底部 `TabView`,五个 tab 单栏切换。
- **iPad / Mac**:同一份代码收敛到**三列宽屏壳**(`WideRootView`),tab 变成左侧导航,选中后中列出列表、右列出详情。五个 tab 共享同一套 `FeatureSurface` 契约渲染,不再有 Mac / iPad 专属的平行 UI。
- 每个 tab 的具体形态各自有文件:[来信](envelope-inbox.md) / [加好友](add-friend.md) / [bot 邀请](bot-invites.md) 等。

**示例** — 你想跟一个新认识的人聊天:去 **好友** tab 扫他的名片二维码加上 → 点他进会话(跳到 **消息**)。聊了几天,bot 到点自动写了封信 → 红点出现在 **来信** tab。同时你在 PendingCrew 里起的开发 crew 有个 session 要你批权限 → 在 **Crew** tab 看到状态卡、直接批。想换个头像 → 去 **我** tab 改资料。五件事,五个 tab,各就各位。

**边界**

- **Crew tab ≠ 编排台**。它**不展示**:完整 DAG 折叠索引、runner host 配置、完整 session 日志、工作目录文件树、machine 管理——这些全在 PendingCrew(Mac / iPad)里。PendingBot 的 Crew tab 只做"群聊 grammar"的查看 + 遥控(@session 发指令、批 permission、看状态卡、"在 PendingCrew 中打开"按钮)。
- **来信 tab ≠ 聊天**。来信是一篇篇文章,有自己的 tab 和详情页,不混进消息流。
- **tab 集合是固定的五个**,不做用户自定义增删 / 排序。

**注意**

- **Crew tab 的定位易被旧 spec 带偏**。早期产品设计里 Crew tab 一度被想成更重的面板;现状是**纯查看 + 遥控入口**,编排能力一律归 PendingCrew。写任何 Crew tab 相关的东西,先认准这条边界。
- **iPad/Mac 三列壳曾长期跑不通**(`FeatureSurface` 列在视图图外求值导致首启崩溃 / @State 不灌注),已修复(2026-06-10)。所以"五 tab 全部共享 surface"这件事是**最近才真正成立**的,别参照更早的 Mac 平行 UI 描述。
