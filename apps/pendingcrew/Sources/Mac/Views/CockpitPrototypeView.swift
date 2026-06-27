#if os(macOS)
import SwiftUI

/// 驾驶舱「布局原型」—— 真 SwiftUI、自带样例内容,每块区域顶上钉一条**标注**
/// (什么地方有什么 / 接什么)。零数据依赖,纯展示结构。
///
/// `CockpitView` 读不到真三本账(没选带 docs/handbook|state|tasks 的本地 crew)时
/// 落到这,所以点开驾驶舱总能看到完整布局,不至于空屏。共用 `CockpitView` 头部的
/// 分段选择器(传 `segment` 进来),这里只渲染每段的舞台。
struct CockpitPrototypeView: View {
    let segment: CockpitView.Segment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                banner
                switch segment {
                case .dashboard:   dashboard
                case .expectation: expectation
                case .state:       state
                case .tasks:       tasks
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(Theme.Palette.accent)
            Text("布局原型 · 样例内容 —— 真 crew 选中带三本账的目录后这里换成真数据")
                .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 总览

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            anno("统计卡 — 三本账计数 + status 分布条 · 数据=CockpitStats.from(三本账)")
            HStack(spacing: 12) {
                metric("现状", "19", "条", [(4, "done"), (3, "partial"), (2, "pending-qa"), (1, "planned")])
                metric("任务", "7", "个", [(3, "done"), (1, "doing"), (1, "pending-qa")])
                metric("期望", "62", "篇", [])
            }
            box("最近任务", "数据=docs/tasks 按 updated 倒序 · 点一条→跳「任务」") {
                ForEach(sampleTasks.prefix(3)) { t in
                    HStack(spacing: 9) {
                        StatusBadge(raw: t.status)
                        Text(t.title).font(.callout)
                        Spacer(minLength: 0)
                        Text(t.updated).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                    }
                    .padding(.vertical, 3)
                }
            }
            box("模块（按 area）", "现状条按 pendingcrew/pendingbot/shared rollup") {
                moduleRow("pendingcrew", [(5, "done"), (3, "partial"), (2, "pending-qa")])
                moduleRow("pendingbot", [(6, "done"), (2, "partial")])
                moduleRow("shared", [(4, "done"), (4, "planned")])
            }
            box("DAG 责任地图", "CrewDetail.parents/children · 「跟着 crew 层级那套」") {
                Text("↑ 上游：v1.0 roadmap crew").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                HStack(spacing: 8) {
                    Image(systemName: "person.3.fill").foregroundStyle(Theme.Palette.accent)
                    Text("鉴权重构（本 crew）").font(.callout.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.Palette.accentBg, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 6) {
                    Text("└ 子 crew").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                    chip("edge 侧"); chip("iOS 侧")
                }
            }
        }
    }

    // MARK: 期望（目录树）

    private var expectation: some View {
        VStack(alignment: .leading, spacing: 10) {
            anno("handbook 以目录树浏览 · 数据=docs/handbook 递归 · 「看自己 crew 以下层级」")
            HStack(alignment: .top, spacing: 12) {
                box("目录树（左）", "OutlineGroup · 文件夹/页") {
                    treeRow("folder", "pendingcrew", 0, false)
                    treeRow("folder", "concepts", 1, false)
                    treeRow("doc.text", "cockpit", 2, true)
                    treeRow("doc.text", "reconciliation", 2, false)
                    treeRow("folder", "features", 1, false)
                    treeRow("folder", "pendingbot", 0, false)
                }
                .frame(width: 220)
                box("选中页 markdown（右）", "页头并排同 relpath 现状 · 点→跳「现状」") {
                    HStack(spacing: 8) {
                        Text("现状").font(.caption2.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                        StatusBadge(raw: "partial")
                        Text("看板 v2 已落，控制半边待建").font(.caption).foregroundStyle(Theme.Palette.ink).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                    }
                    .padding(8)
                    .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 7))
                    Text("驾驶舱（cockpit）").font(.headline).padding(.top, 4)
                    Text("声明式对账的呈现 + 控制面。看板半边渲染期望 / 现状两本 + task，把差摆给人看；控制半边让 captain 看着差直接生 session 去补……")
                        .font(.callout).foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
    }

    // MARK: 现状

    private var state: some View {
        VStack(alignment: .leading, spacing: 10) {
            anno("现状条按 area 分组 + status 色块 · 数据=docs/state frontmatter（只读 status，不解析正文）")
            HStack(alignment: .top, spacing: 12) {
                box("现状条（左）", "色块=frontmatter status") {
                    ForEach(sampleTopics) { t in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2).fill(CockpitUI.color(t.status)).frame(width: 4, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.key).font(.system(.caption, design: .monospaced))
                                Text(t.summary).font(.caption2).foregroundStyle(Theme.Palette.inkMuted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(width: 250)
                VStack(alignment: .leading, spacing: 12) {
                    box("详情（右）", "现状 + 证据 + 关联 task + 期望页 · chip/链接跨账跳转") {
                        HStack(spacing: 8) {
                            Text("concepts/cockpit").font(.system(.body, design: .monospaced))
                            StatusBadge(raw: "partial")
                        }
                        Text("看板 v2 已落（主窗口+目录树），控制半边待建").foregroundStyle(Theme.Palette.ink).font(.callout)
                        Text("证据：CockpitView.swift").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                        HStack(spacing: 6) {
                            chip("20260626-cp"); Text("驾驶舱 cockpit").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    controlHalfCard
                }
            }
        }
    }

    // MARK: 任务（看板）

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 10) {
            anno("task 看板按状态分列 · 数据=docs/tasks frontmatter · 可按 crew 沿 DAG 子树过滤")
            HStack(alignment: .top, spacing: 12) {
                box("看板（左）", "todo / doing / pending-qa / done / dropped") {
                    HStack(alignment: .top, spacing: 8) {
                        kanban("todo", "planned", ["控制半边"])
                        kanban("doing", "doing", ["cockpit"])
                        kanban("pending-qa", "pending-qa", ["GUI QA"])
                        kanban("done", "done", ["task 账本", "reconcile"])
                    }
                }
                box("task 详情（右）", "expects→期望 · state→现状 · deps→task（跨账跳转）") {
                    Text("驾驶舱 cockpit").font(.callout.weight(.medium))
                    HStack(spacing: 6) { StatusBadge(raw: "doing"); Text("20260626-cp").font(.caption.monospaced()).foregroundStyle(Theme.Palette.inkMuted) }
                    linkLine("expects →期望", "doc.text.magnifyingglass", "concepts/cockpit")
                    linkLine("state →现状", "checklist", "concepts/cockpit")
                    HStack(spacing: 6) { Text("deps →task").font(.caption2).foregroundStyle(Theme.Palette.inkMuted); chip("20260626-tl") }
                }
                .frame(width: 200)
            }
        }
    }

    // MARK: 控制半边卡片（规划）

    private var controlHalfCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.Palette.gold)
                Text("控制半边（规划 · 未建）").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.gold)
            }
            Text("在读出差的地方（现状条 / 期望页）挂「⚡生 session 补差」—— 把这段期望当 brief 派给子 crew。")
                .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            Text("接 CrewSessionRunner.start(brief) · 不排队 / 不冒 chip / 人审不自动").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Palette.gold.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: 小件

    private func anno(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.caption2)
            Text(text).font(.caption2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.accent)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.Palette.accentBg, in: RoundedRectangle(cornerRadius: 7))
    }

    private func box(_ title: String, _ annotation: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
            anno(annotation)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ label: String, _ n: String, _ unit: String, _ dist: [(Int, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(n).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(unit).font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !dist.isEmpty { distBar(dist) } else { Spacer().frame(height: 8) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func distBar(_ dist: [(Int, String)]) -> some View {
        GeometryReader { geo in
            let total = max(1, dist.reduce(0) { $0 + $1.0 })
            HStack(spacing: 1) {
                ForEach(Array(dist.enumerated()), id: \.offset) { _, seg in
                    CockpitUI.color(seg.1).frame(width: geo.size.width * CGFloat(seg.0) / CGFloat(total))
                }
            }
        }
        .frame(height: 7).clipShape(Capsule())
    }

    private func moduleRow(_ name: String, _ dist: [(Int, String)]) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.callout).frame(width: 96, alignment: .leading)
            distBar(dist).frame(maxWidth: 200)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func treeRow(_ icon: String, _ name: String, _ indent: Int, _ selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.inkMuted)
            Text(name).font(.callout).foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.ink)
        }
        .padding(.leading, CGFloat(indent) * 16).padding(.vertical, 2)
    }

    private func kanban(_ title: String, _ status: String, _ cards: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(CockpitUI.color(status)).frame(width: 7, height: 7)
                Text(title).font(.caption2.weight(.medium))
            }
            ForEach(cards, id: \.self) { c in
                Text(c).font(.caption2).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkLine(_ label: String, _ icon: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
            Label(value, systemImage: icon).font(.caption).foregroundStyle(Theme.Palette.accent)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption2.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.Palette.surfaceMuted, in: Capsule())
            .foregroundStyle(Theme.Palette.inkMuted)
    }

    // MARK: 样例数据

    private var sampleTasks: [CockpitTask] {
        [
            CockpitTask(id: "20260626-cp", title: "驾驶舱 cockpit", status: "doing", owner: "~", crew: "~", expects: [], state: [], deps: [], updated: "06-26"),
            CockpitTask(id: "20260626-tl", title: "task 账本", status: "done", owner: "~", crew: "~", expects: [], state: [], deps: [], updated: "06-26"),
            CockpitTask(id: "20260626-qa", title: "GUI QA 批次", status: "pending-qa", owner: "~", crew: "~", expects: [], state: [], deps: [], updated: "06-26"),
        ]
    }

    private var sampleTopics: [CockpitTopic] {
        [
            CockpitTopic(area: "pendingcrew", key: "concepts/cockpit", status: "partial", summary: "看板 v2 已落，控制半边待建", evidence: "CockpitView.swift", taskIds: [], taskRaw: ""),
            CockpitTopic(area: "pendingcrew", key: "vision", status: "done", summary: "北极星已定稿", evidence: "vision.md", taskIds: [], taskRaw: ""),
            CockpitTopic(area: "pendingcrew", key: "features/three-pane", status: "pending-qa", summary: "三栏布局，真机验待", evidence: "MacRootView.swift", taskIds: [], taskRaw: ""),
            CockpitTopic(area: "pendingcrew", key: "governance", status: "planned", summary: "治理模型仍是前沿", evidence: "—", taskIds: [], taskRaw: ""),
        ]
    }
}
#endif
