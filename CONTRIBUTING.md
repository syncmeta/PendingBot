# 参与 PendingBot

先把期望摆平：**这是一个人的实验项目。** 没有维护团队，没有 SLA，
作者可能几周不看 issue。欢迎你来，但别把它当成一个有承诺的开源项目。

还有一件事得先说：**这个仓库只有 Swift 客户端。** 后端（Cloudflare Worker、
Supabase、后台控制台）不开源，也不在这里。所以你能改的、能验的，都在客户端这一侧；
一个「顺手把后端那边也改了」的 PR 是提不出来的。

## 在动手之前

- **改动大一点的，先开个 issue 聊。** 直接甩一个大 PR 过来，很可能撞上作者
  没写进仓库的想法，然后白做。小修（打字错误、明显的 bug、文档不准）随手 PR 就行。
- **不接"重构成 X 风格"类的 PR。** 代码怎么组织是作者的口味问题，不是对错问题。
- **安全问题不要开公开 issue**，走 [`SECURITY.md`](SECURITY.md)。

## 开发环境

完整步骤在 [`docs/building.md`](docs/building.md)。最短路径：

```bash
cd apps/pendingbot
xcodegen        # 只在改过 project.yml 之后需要
open PendingBot.xcodeproj
```

只需要 macOS + Xcode。**不需要** Node / Bun / Docker / Supabase CLI —— 那些是后端的
工具链，不在这个仓库里。SPM 依赖全是远程 GitHub URL，Xcode 会自己拉。

`PendingBot.xcodeproj` 是提交在仓库里的，clone 下来直接能开；只有改过 `project.yml`
才需要重新跑 `xcodegen`。**改了 `project.yml` 就必须把重新生成的 `.xcodeproj` 一起
提交**，否则别人 clone 下来编到的是旧工程。

装到真机要在 Xcode 里换成**你自己的 Signing Team**（仓库里那个是作者的）。
编模拟器不需要签名。

## 提交前请自己跑一遍

```bash
cd apps/pendingbot
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
  -destination 'generic/platform=iOS Simulator' build

xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
  -destination 'platform=macOS' build
```

**CI 只跑上面第一条**（`.github/workflows/client-build.yml`，macOS runner 上的
iOS Simulator 构建，不签名）。它只证明「编得出来」—— **Swift 侧没有单元测试**，
所以 CI 绿不代表你的改动是对的，只代表它没把编译弄坏。

macOS 目标 CI 不跑，改了 `Sources/Mac/**` 或任何带 `#if os(macOS)` 的地方，
请自己在本机编一遍 Mac 目标。

**不要提交红的分支。** 如果某项检查你在本机跑不了（比如没有 Apple 开发者账号、
只能编模拟器不能装真机），在 PR 里如实说一句你跑了哪些、没跑哪些 ——
这比假装全绿有用得多。

## 需要人工验的

自动化在这个仓库里盖不住的东西不少：真机签名、Apple / Google 登录授权页、
推送、扫码、深链、以及任何视觉判断。这些只能人自己在设备上过一遍。
PR 模板里有一栏专门写这个，别留空。

## 提交信息

用仓库现有的前缀风格：`ios:`（客户端改动，三端都用这个前缀）、`ci:`、`docs:`、
`chore(...)`。历史提交里还能看到 `edge:` / `db:` 这类前缀 —— 那是后端还在这个仓库里
时留下的，新提交用不到了。
一个提交一件事，别把无关改动塞进同一个提交。

## 语言

代码注释和文档以中文为主，英文也收。变量名、类型名、提交前缀用英文。

## 许可

提交 PR 即表示你同意你的贡献按本仓库的 [MIT 许可](LICENSE) 分发。
