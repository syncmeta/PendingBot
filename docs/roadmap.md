> 路线账。阶段按文件顺序排先后；条目挂期望页 relpath；进度由驾驶舱从现状账实时派生，本文件不记进度。

当前主线：本地为家的声明式对账闭环收口 v1（crew / captain / session-and-world-model / human-in-the-loop 等核心机制已代码落地，多数卡在真机 GUI QA 尾巴），下一步往登录叠加层（fly 远端执行、跨设备遥控）与治理/规模化深水区看。细的产品愿景见 [PendingCrew 定位](handbook/pendingcrew/vision.md)，此处不复制。

## v1 收口
status: doing
target: 2026-08
目标: 本地闭环全链路真机可用，登录叠加与账本体系的尾巴清完。
- pendingcrew/concepts/cockpit — 路线段本身也算这阶段
- pendingcrew/concepts/reconciliation
- pendingcrew/concepts/local-first
- pendingcrew/concepts/crew
- pendingcrew/concepts/captain
- pendingcrew/concepts/session-and-world-model
- pendingcrew/concepts/human-in-the-loop
- pendingcrew/concepts/async-delegation
- pendingcrew/concepts/subprocess-safety
- pendingcrew/concepts/whiteboard
- pendingcrew/features/three-pane-ui
- pendingcrew/features/create-crew-and-session
- pendingcrew/features/runner-backends
- pendingcrew/features/session-crew-comms
- pendingcrew/features/session-health
- pendingcrew/features/session-quota-and-profile

## v1.1 远端与云
status: planned
目标: fly 远端执行开通 + 跨设备遥控真链路打通。
- pendingcrew/concepts/runtime-location-and-machine
- pendingcrew/features/cross-device-control

## v2 治理与规模
status: planned
目标: DAG 责任分账搬回本地、治理心智从指导思想落成机制。
- pendingcrew/concepts/dag-and-responsibility
- pendingcrew/concepts/governance
