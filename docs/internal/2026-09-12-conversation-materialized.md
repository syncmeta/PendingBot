# #28：已创建会话及时进入列表

基线 main `90481cfd`。原开发目录混合改动保持原样，独立分支仅摘取创建通知与列表同步。

创建成功后，在等待实时订阅之前广播完整会话。列表收到当前账号的非空 ID 后立即去重插入；仅打开空草稿仍不创建会话。旧的 `onChange` 只刷新右栏实例，不能保证左栏立刻更新。

为防旧刷新快照覆盖新行，已确认创建的行在本地保留至服务端列表观察到它；未观察到的行在下一次刷新时按 60 秒期限清除。本地删除同时清除保留行。此保护是短暂 UI 合并，不是持久数据库或投影一致性修复。

验证：

- `node scripts/test-conversation-materialized.mjs`：红基线 `d817b9e7` 缺通知失败；实现后 5 项接线检查通过，仅源码层。
- `node scripts/test-materialized-merge.mjs`：抽取生产 Swift 处理语句，用值类型 fixture 执行，覆盖旧快照、重复、确认、删除、过期、空 ID、跨账号及排序。通过。
- `MUTATE_DROP_PENDING=1 node scripts/test-materialized-merge.mjs`：移除待确认行合并后，`older snapshot must retain creation` 断言失败；不是编译/环境失败。
- macOS / iOS Simulator 构建均 `BUILD SUCCEEDED`，日志 `/private/tmp/pendingbot-28-mac.log`、`/private/tmp/pendingbot-28-ios.log`。未启动 GUI。

待安装新版本后：Mac 从新建会话选择机器人并首次发送，左栏应立即出现一行；刷新期间重复这一动作不应闪退消失或重复；删除后刷新不应复活。尚未执行真实 UI/发送/跨设备验证，Todo 不销号。
