# 富感知 · 落地设想(草案)

> **这是「大概怎么落」的草案,不是详细实现。** 概念(权威 WHAT/WHY)在 [富感知](../handbook/pendingbot/concepts/rich-perception.md);本篇只立**框架 + cheap-first 顺序 + 复用哪些现成件**,细节下一轮再填。drafts/ 下的东西都是这种"想法先存住、细节后补"的草案。

## 核心心智

富感知不是建新系统,是给已有零件接一条线:**感知 → 注入 → 反思 → 回写**。

## 复用的现成零件

- **prompt-builder**(已在注入 bot.tz / 社交圈 / skill / 画像)→ 加一个 ambient「环境块」
- **prompt 通道**(`prompts/<locale>/*.md` + loader)→ 一个 `ambient.md` 模板
- **lookback / 复盘**(周期跑、写画像)→ 扩成"养素养 + 产 stance"的环
- **长期画像** → 存 per-person 心得 + 当前 stance
- **WalletDO** → 读余额信号
- **web-surf pipeline** → 取贵信号(天气 / 热点)
- **Agent Skills** → 素养"课程"

## 三层大概怎么落

- **A 信号 = 环境块**:便宜的每回合(时间 / 余额 / 对方近况从对话推),贵的缓存(天气 / 热点走 web-surf)。
- **B stance = 派生一句塞进 prompt**,起步挂 lookback 周期产、存画像;不另起模型。
- **C 素养 = 扩 lookback 回写 + curate 几个方法 skill**。

## cheap-first 顺序

① 环境块 + 便宜信号 → ② lookback 扩素养 + 产 stance → ③ 贵信号缓存接 web-surf → ④ stance 升级成每回合轻派生(若证明值)。

## 纪律

- 别每回合全拉(成本 / 不帮倒忙):便宜的每回合、贵的缓存。
- **信号是输入不是真理**:对方状态是推的、可能错,bot 轻持,别当定论。
- **不拟人**:stance 是内部 guidance,不外显成"我觉得"。

## 下一轮要细化的(占位)

- **A**:信号确切清单 + 各自来源 + 注入格式 + 每回合 token 预算。
- **B**:stance 怎么派生(规则 vs 轻模型)、存哪、多久更新一次。
- **C**:lookback 回写具体抽什么、配哪几个素养 skill。
- **贵信号**:缓存周期 + 失败兜底。
