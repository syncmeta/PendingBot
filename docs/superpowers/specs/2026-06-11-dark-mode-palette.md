# 深色模式调色板 spec(已与用户定稿 2026-06-11,实施待排期)

状态:**定色完成,未实施**。用户拍板"差不多就这样";v1 优先级让位于 #290 真机验证等,实施另起任务。

## 定色原则

1. **深色不是反相,是换光源**:浅色里深林绿当"墨"(按钮/强调压在米白上);深色里绿翻成"光"——提亮为玉绿,按钮底变亮绿、字用深绿反衬。
2. **色温不变,暖到底**:深色画布用暖近黑(微偏褐),不是 iOS 冷灰黑;墨色翻暖白不翻纯白。两个模式是"同一间屋子开灯关灯"。
3. **表面阶梯反转**:深色里越靠近用户的层越亮:canvas < surface < surfaceMuted。
4. **三对 tag 色(绿/琥珀/梅紫)保持配对**:fg 提亮、bg 深色水洗,三对同亮度寄存。

对比度余量:正文 ~15:1,inkMuted ~6:1,玉绿on画布 ~7:1(均过 WCAG AA)。

## Token 对照(浅色现状 → 深色定稿)

| token | 浅色 | 深色 | 备注 |
|---|---|---|---|
| canvas | `#FDFCFA` | `#161512` | 暖近黑 |
| surface | `#FFFFFF` | `#201E1A` | 比画布亮一档 |
| surfaceMuted | `#EFEEE9` | `#2A2823` | 再亮一档 |
| ink | `#1B1A14` | `#ECE9E0` | 暖白 |
| inkMuted | `#6E6A5C` | `#A8A294` | |
| hairline | `#E2E0D7` | `#383530` | |
| accent | `#044735` | `#57B690` | 品牌轴心:深林绿→玉绿 |
| accentHover | `#0A6049` | `#6CC6A1` | |
| accentBg / userBubble | `#E3EEEA` | `#1C3A2F` | 绿染深面 |
| userBubbleSending | `#F1F6F3` | `#182A23` | 向画布回洗 |
| amber / amberBg | `#6F5A0B` / `#FAEDC2` | `#E0BD55` / `#3B3110` | fg/bg 明暗互换 |
| plum / plumBg | `#5B3D8A` / `#ECE3F7` | `#B9A0E3` / `#322546` | 同上 |

## 实施要点(估算 ~1–1.5 周专注投入,详见 2026-06-10 会话摸底)

- 第一步:`Sources/Components/Theme.swift` 的 `Theme.Palette` 16 token 改自适应色(iOS `UIColor` dynamic provider / macOS `NSColor`,包一层跨平台 helper)。721 处引用自动翻转。
- 模式入口:做**三态**(跟随系统/浅/深,放「我 → 设置」),移除两个 `@main` 的 `.preferredColorScheme(.light)` 钉死,改绑设置值。
- 长尾清理:Palette 外裸 `Color(hex:)` 20 处、裸 `.white/.black` 54 处(逐个判断"跟随"还是"钉死",绿底白字类钉死)、`.opacity()` 水洗 147 处、阴影 31 处(深色下改描边/提亮)。
- 特殊面:MarkdownUI 主题 + 代码高亮(BubbleView/MarkdownText/MathRendering)出深色版;**二维码卡片钉浅色**(扫码对比度);Mac 登录窗透明手术、Turnstile webview 主题、启动屏。
- 大头是三端 × 40+ 屏的逐屏深色视觉验收。
