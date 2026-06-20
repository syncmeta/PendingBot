# App Store Connect / TestFlight

把 Apple 端的 app(PendingBot / PendingCrew)分发出去的那条通道。系统里它的角色:**预发布期的真机分发面**——v1 未上架,所有真机测试 / 真机验证都靠 TestFlight 装一版。相关:[PendingBot app](pendingbot-app.md) · [PendingCrew app](pendingcrew-app.md) · [登录](sign-in.md)。

**逻辑 — 它是什么、什么角色**

- **TestFlight = 预发布的真机分发**:app 编出来后,归档 → 上传到 App Store Connect → 经 TestFlight 发到真机。这是 launch 前唯一能把构建装到真手机 / 真 iPad 的正路(模拟器装不出真签名环境,很多坑只在真机现形)。
- **上传走 ASC API key(App Store Connect API key)**:自动化上传用一枚 `.p8` 密钥 + Issuer ID / Key ID 认证,不靠交互式 Apple ID 登录——这样上传能在脚本里一气呵成,不卡人工登录。这枚 key 是上传通道的凭据,妥善保管。
- **签名走 automatic signing + 固定 team**:归档 / 导出走 Xcode 的自动签名,绑一个固定开发者 team。本机配好的 App Store Connect / Xcode 账号就够,不需要往仓库里塞额外 secret。

**为什么 — 关键取舍**

- **预发布只需要 TestFlight,不需要 App Store 审核循环**:v1 没发布,验证对象只有自己的真机,TestFlight 内测足够;不为还没到的上架阶段提前搭审核 / 多 track 基建。
- **上传用 API key 而非账号密码**:可自动化、可无人值守、不把 Apple ID 凭据散落进脚本——和"运维动作授权自动跑"的姿态一致(上传是 operator 发起、agent 端到端做完,不停在"给你指令让你自己传")。
- **真机验证是验收的一部分,不是可选**:党纲"已落地 = 已验证"。很多签名 / keychain / 登录态的坑(见登录、app 篇)只在真签名的真机上暴露,所以"装一版 TestFlight 真机验"常是把一个 feature 从 🟨 翻到 ✅ 的最后一步。

**用在哪·长什么样**

- 触发方式:用户说"上传一版到 TestFlight"时,从一条短命分支端到端做完(改构建号 → 归档 → 上传),不停在给指令。
- 用户侧:测试者在 TestFlight app 里收到新构建、点安装。

**边界**

- **不做 App Store 公开上架(pre-launch)**,不搞多环境 / 多 track 的发布基建。
- **不在中国大陆上架**——中文只是开发语言,不把中国 App Store 限制当约束。
- **TestFlight 不是部署 edge / DB 的通道**:后端部署是另一套(worker deploy / db push),app 上传只管 Apple 客户端那一端。

**注意**

- **具体 runbook 在别处,不在手册重抄**:归档 / 导出 / 上传的逐条 `xcodebuild` 命令、构建号怎么 bump、ExportOptions 怎么改,都在 [`docs/deploy.md` #ios](../../../deploy.md) 的 "Fast TestFlight recipe"。手册只立"这条通道是什么、什么角色",实现细节向下指那里。
- **改构建号走 XcodeGen spec 再生成**:bump 构建号改在 spec(`project.yml`)里再重生成工程,别手改生成出来的工程文件(会被覆盖)。
- **已知无害告警**:PendingBot 上传可能打印 WebRTC framework 缺 dSYM 的 `Upload Symbols Failed`——不挡 TestFlight 安装 / 处理,只是该 framework 的崩溃日志符号可能不全。
- **scaffold 期的签名 flag**:工程里可能还留着 scaffold 期的 `CODE_SIGNING_ALLOWED=NO`;正式归档需先去掉再生成,或用 `-allowProvisioningUpdates` 让自动签名临时盖过(细节见 deploy.md)。

**现状** — ✅ PendingBot 的 TestFlight 上传链路按 deploy.md 跑得通(归档 → 上传 → ASC 处理),ASC API key 配置就绪。证据见 [`docs/deploy.md` #ios](../../../deploy.md)。
