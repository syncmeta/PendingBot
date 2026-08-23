# 从源码编出这个 app

这份仓库只有**客户端**。后端不开源，也不在这里 —— 所以这份文档能带你走到
「app 编出来了、装上了、能启动」，走不到「能聊天」。那一步需要一个你自己的
后端，而它的源码不在这个仓库里。

先把这件事说清楚，免得你编到一半才发现：**你 clone 下来，开箱什么也做不了。**

## 你需要什么

| 工具 | 用途 |
|---|---|
| macOS + Xcode | 编译。上一次实跑核对是在 Xcode 26.5 上 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 只在你改过 `project.yml` 之后才需要 |
| 一个 Apple 开发者账号 | 只有装到真机 / 出包才需要；编模拟器不需要 |

不需要 Node / Bun / Docker / Supabase CLI —— 那些是后端的工具链，跟这个仓库无关。
SPM 依赖全部是远程 GitHub URL，Xcode 会自己拉。

## 编

```sh
git clone <this-repo> PendingBot
cd PendingBot/apps/pendingbot

# 只有改过 project.yml 才需要这一步。
# PendingBot.xcodeproj 是提交在仓库里的，clone 下来直接能开。
xcodegen

xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
  -destination 'generic/platform=iOS Simulator' build
```

macOS 端把 destination 换成 `-destination 'platform=macOS'`。

要在 Xcode 里跑（装模拟器、调试、看界面）就直接打开 `PendingBot.xcodeproj`。
装到**你自己的真机**上要在 target 的 Signing & Capabilities 里换成**你自己的
Signing Team** —— 仓库里那个是作者的，你签不了。

构建末尾有一道 `Stamp build info` 的脚本，把「这个产物是从哪个 commit 出的」
写进产物的 Info.plist。从 tarball 或者没装 git 的机器上编，它会如实写
`unknown` 然后照常编过；这是预期行为，不是错误。

## 后端坐标

`Sources/Networking/HostedConfig.swift` 的 `.remote` 分支里全是占位值
（`https://api.example.com`、`https://YOUR-PROJECT.supabase.co` 之类），
遥测三件套（PostHog / Sentry / RevenueCat）是空串 = 关闭。

同一个文件里的 `isConfigured` / `isEmailSignInConfigured` 两个判据，就是拿这些
常量跟 `HostedConfig.Placeholder` 里的字面量比对 —— **它们是「哪条线通」的唯一
真值**，这份文档不另写一份能力清单，因为两份一定会漂。没填坐标时它们返回
`false`。

**这时候点登录会怎样：不会静默失败。** 三个入口（Apple / Google / 邮箱验证码）
都会原地显示同一句提示，不转圈也不崩：

> 本仓库只带占位后端坐标，登录走不通。要接自己的 Cloudflare Worker + Supabase，见 README 的「配置」一节。

这是在一份未填坐标的构建上真点过三个入口测出来的，不是设计意图。顺带一件
反直觉的事：因为这道判据挡在最前面，**Google 的 `GIDClientID` 占位和 Turnstile
的占位都走不到** —— 你不会看到 `missingClientID`，也不会看到关于 Turnstile 的
提示，只会看到上面那一句。

要指向你自己的后端，改 `Environment.remote` 分支下那几个常量：Worker URL、
Supabase URL 与 publishable key、Turnstile site key / host，以及你需要的遥测 key。

⚠️ **不要动 `Placeholder` 里的字面量。** 那是上面两个判据的参照物；改了判据就
永远为真，app 会从「明说没配」退回**静默失败** —— 那比没配还难查。

还有两处零散的：

- **Google 登录** —— `Info.plist` 和 `Resources/Info.plist` 里的 `GIDClientID`
  与反转 URL scheme 也是占位（`YOUR_GOOGLE_CLIENT_ID`）。填了后端坐标之后这一处
  才轮得到，见上面那条实测说明。
- **Universal Links / 分享链接** —— AASA 域名、Associated Domains entitlement 和
  代码里的分享链接域名仍然是作者的。换成你自己的域名时这三处要一起改。

切换环境目前只能改 `HostedConfig.environment` 的默认值这一行，没有 xcconfig
或运行时开关。这是已知缺口。

## 后端呢

不在这里，而且没有计划开源。**这个仓库没有「自建一套后端」这条路** ——
以前有一份 `docs/self-hosting.md` 写过怎么起 Supabase + Cloudflare Worker，
那是公开仓还带着后端源码时的事，现在整篇作废了，所以直接删掉，没有留着改。

所以你能拿这份仓库做的事，实际上是这些：

- 读客户端怎么写的 —— 这是它公开的主要理由
- 编出来、装到自己设备上看界面
- 改客户端，指向**你自己实现的**后端（接口形状得你自己从 `Sources/Networking/`
  里那些注释和类型反推，那里面还留着当初对着 Worker 路由写的注释）

想直接用这个 app 的话，看 README 顶上的 TestFlight / macOS 下载。

## 编不过的时候

- **`xcodebuild: error: scheme not found`** —— 先跑 `xcodegen`。仓库里不带
  committed 的 scheme。
- **SPM 拉不下来** —— 依赖全是 GitHub 上的公开仓库，通常是网络问题，不是配置问题。
- **签名报错** —— 编模拟器不需要签名。装真机 / 出包才需要，那时换成你自己的
  Signing Team。
