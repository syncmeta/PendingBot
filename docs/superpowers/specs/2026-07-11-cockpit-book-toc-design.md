# 驾驶舱期望段:书本目录树(cockpit book TOC)

日期:2026-07-11 · 范围:PendingCrew Mac `CockpitView` 期望段 + `CockpitLoader`/UI 读取约定 · 关联:#447(驾驶舱看板 MVP)、[cockpit.md](../../handbook/pendingcrew/concepts/cockpit.md)

## 问题

期望段目录树现状(`CockpitExpectation`):

- 目录用 `folder.fill`、页用 `doc.text` 图标 —— 文件管理器味,不是"书目录"味;
- `.sidebar` List 默认行高松,不紧凑;
- 目录节点点了没有内容(`isPage` 才渲详情),而书的"章"应有章的正文;
- 构树时 `README.md` 被整个跳过,目录正文无处安放。

## 设计

**目录(章)内容 = 该目录下的 `README.md`,只认这一个约定**(用户拍板,不做合成目录页兜底):

- 点目录 → 右栏渲染 `docs/handbook/<dir>/README.md`;不存在则显示一行占位:「本章还没有引言(docs/handbook/\<dir\>/README.md)」。
- 根目录 `README.md` 当"全书序":进入期望段、尚未选中任何节点时,右栏默认渲染它(替代原"从左边目录树选一篇"占位)。
- 构树仍不把 `README.md` 列为子页节点(它是章正文,不是节)。

**树 UI = 书本目录**:

- 去掉全部图标,只留展开 chevron + 文字;
- 紧凑:行高压到 ~22pt、~12.5pt 字号,层级靠缩进;
- 章(目录)semibold、节(页)regular;
- 节行尾:若有同 relpath 的现状条,缀一个小状态色点(对账一眼读,像页码位的状态标记);
- 目录可选中(选中与展开互不干扰),点目录渲章正文。

**不动**:右栏页面渲染(页头现状条 + MarkdownText)、跨账跳转(`CockpitNav`)、`CockpitSplit` 布局、其他分段。

## 边界

- 不自动生成/补写各章 README —— 章引言是期望账内容,归人写;UI 只渲染存在的。
- 不判 drift、不重解析文档(cockpit.md 边界不变);状态点只是现状 frontmatter 的纯展示。
