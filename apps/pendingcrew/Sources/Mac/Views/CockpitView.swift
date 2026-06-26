#if os(macOS)
import SwiftUI

/// 驾驶舱(cockpit)—— [对账](docs/handbook/pendingcrew/concepts/cockpit.md) 的呈现面,
/// **直接铺在主窗口**(侧栏 | 驾驶舱 两栏,由 `MacThreePaneView` 在 `showingCockpit` 时整片切),
/// 不是临时小窗口/info 面板。范围 = 侧栏选中的 crew + 其 DAG 子树(cockpit.md:per-crew 是
/// 沿 DAG 切一刀的过滤视图,存储仓库级一份)。
///
/// 四块(分段):
/// - **总览**:最近任务 / 模块(按 area)/ 状态分布统计 / DAG 责任地图。
/// - **期望**:handbook 以**目录树**浏览(左树右页),页头并排显示对应**现状**状态(对账的一眼读)。
/// - **现状**:现状条按 area 分组、status 色块,右栏看 现状 + 证据 + 关联 task + 期望页。
/// - **任务**:task 看板(按状态分列),右栏 task 详情,expects/state/deps 可点**跨账跳转**。
///
/// 全程 read-only:差靠人扫两栏读,**不判 drift、不重解析文档**(cockpit.md 边界)。控制半边
/// (看差一步生 session)是后续增量。
struct CockpitView: View {
    @ObservedObject var runner: CrewSessionRunner
    @EnvironmentObject private var crewStore: CrewStore

    @State private var data: CockpitData?
    @State private var segment: Segment = .dashboard
    @State private var selectedNodeID: String?    // 期望:选中的 handbook 节点 id(页 relpath)
    @State private var selectedTopicID: String?   // 现状:选中的 topic id
    @State private var selectedTaskID: String?    // 任务:选中的 task id
    @State private var taskScopeOnly = false      // 任务:只看本 crew 子树

    enum Segment: String, CaseIterable, Identifiable {
        case dashboard = "总览", expectation = "期望", state = "现状", tasks = "任务"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.33percent"
            case .expectation: return "doc.text.magnifyingglass"
            case .state: return "checklist"
            case .tasks: return "square.stack.3d.up"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.Palette.canvas)
        .task(id: crewStore.selectedDetail?.crew.workingDirectory ?? crewStore.selectedCrewId ?? "") {
            reload()
        }
    }

    // MARK: header(crew + 分段 + 控制)

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "speedometer").foregroundStyle(Theme.Palette.accent).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("驾驶舱").font(.headline)
                    Text(crewStore.selectedDetail?.crew.title ?? crewStore.selectedCrew?.title ?? "—")
                        .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            Spacer(minLength: 12)
            Picker("", selection: $segment) {
                ForEach(Segment.allCases) { seg in
                    Label(seg.rawValue, systemImage: seg.icon).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: 12)
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("重读三本账")
            Button { runner.showingCockpit = false } label: {
                Label("退出驾驶舱", systemImage: "xmark")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    // MARK: 分段路由

    @ViewBuilder private var content: some View {
        if let data {
            switch segment {
            case .dashboard:
                CockpitDashboard(data: data, detail: crewStore.selectedDetail, nav: handleNav)
            case .expectation:
                CockpitExpectation(data: data, selectedNodeID: $selectedNodeID, nav: handleNav)
            case .state:
                CockpitState(data: data, selectedTopicID: $selectedTopicID, nav: handleNav)
            case .tasks:
                CockpitTasks(data: data, selectedTaskID: $selectedTaskID,
                             scopeCrewIds: taskScopeOnly ? scopeCrewIds : nil,
                             scopeOnly: $taskScopeOnly, scopeName: scopeName, nav: handleNav)
            }
        } else {
            emptyState(crewStore.selectedDetail == nil
                ? "选一个 crew 看它的驾驶舱"
                : "此 crew 没有本地工作目录 —— 驾驶舱只渲染本地 crew 的三本账")
        }
    }

    // MARK: 跨账跳转

    private func handleNav(_ nav: CockpitNav) {
        switch nav {
        case .page(let rel):
            selectedNodeID = rel; segment = .expectation
        case .topic(let rel):
            if let topic = data?.topics.first(where: { $0.expectationRelpath == rel }) {
                selectedTopicID = topic.id; segment = .state
            } else {
                selectedNodeID = rel; segment = .expectation
            }
        case .task(let id):
            selectedTaskID = id; segment = .tasks
        }
    }

    // MARK: 范围(DAG 子树 = 自己 + 直接子 crew)

    private var scopeCrewIds: Set<String> {
        guard let d = crewStore.selectedDetail else { return [] }
        return Set([d.crew.id] + d.children.map(\.crewId))
    }
    private var scopeName: String { crewStore.selectedDetail?.crew.title ?? "本 crew" }

    // MARK: data

    private func reload() {
        guard let workdir = crewStore.selectedDetail?.crew.workingDirectory, !workdir.isEmpty else {
            data = nil; return
        }
        data = CockpitLoader.load(crewRoot: URL(fileURLWithPath: workdir))
    }

    private func emptyState(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(Theme.Palette.inkMuted); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 跨账跳转意图

enum CockpitNav {
    case page(String)    // 期望 handbook 页 relpath
    case topic(String)   // 现状 topic(用 expectationRelpath 寻)
    case task(String)    // task id
}

// MARK: - 总览(Dashboard)

private struct CockpitDashboard: View {
    let data: CockpitData
    let detail: CrewDetail?
    let nav: (CockpitNav) -> Void

    var body: some View {
        let stats = data.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statCards(stats)
                if !stats.recentTasks.isEmpty { recentTasks(stats) }
                modules
                if let detail { dagMap(detail) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statCards(_ stats: CockpitStats) -> some View {
        HStack(spacing: 14) {
            statCard(title: "现状", count: stats.topicCount, unit: "条", dist: stats.topicStatus)
            statCard(title: "任务", count: stats.taskCount, unit: "个", dist: stats.taskStatus)
            statCard(title: "期望", count: pageCount(data.handbookTree), unit: "篇", dist: [])
        }
    }

    private func statCard(title: String, count: Int, unit: String,
                          dist: [CockpitStats.StatusCount]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(count)").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(unit).font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !dist.isEmpty {
                CockpitDistributionBar(dist: dist)
                FlowChips(dist: dist)
            } else {
                Spacer().frame(height: 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func recentTasks(_ stats: CockpitStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最近任务")
            VStack(spacing: 0) {
                ForEach(stats.recentTasks) { task in
                    Button { nav(.task(task.id)) } label: {
                        HStack(spacing: 10) {
                            StatusBadge(raw: task.status)
                            Text(task.title.isEmpty ? task.id : task.title)
                                .foregroundStyle(Theme.Palette.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(task.updated).font(.caption2.monospaced())
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if task.id != stats.recentTasks.last?.id { Divider() }
                }
            }
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var modules: some View {
        // 模块 = 现状 area 分组(pendingcrew / pendingbot / shared),各带状态 mini-bar。
        let byArea = Dictionary(grouping: data.topics, by: \.area)
        let areas = byArea.keys.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("模块")
            ForEach(areas, id: \.self) { area in
                let items = byArea[area] ?? []
                let dist = tally(items.map(\.status))
                HStack(spacing: 12) {
                    Text(area).font(.callout.weight(.medium)).frame(width: 120, alignment: .leading)
                    CockpitDistributionBar(dist: dist).frame(maxWidth: 220)
                    Text("\(items.count) 条").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func dagMap(_ detail: CrewDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("DAG 责任地图")
            VStack(alignment: .leading, spacing: 6) {
                if !detail.parents.isEmpty {
                    crewRow(icon: "arrow.up", label: "上游", links: detail.parents)
                }
                HStack(spacing: 8) {
                    Image(systemName: "person.3.fill").foregroundStyle(Theme.Palette.accent)
                    Text(detail.crew.title).font(.callout.weight(.semibold))
                    Text("本 crew").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.Palette.accentBg, in: Capsule())
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.Palette.accentBg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                if !detail.children.isEmpty {
                    crewRow(icon: "arrow.down", label: "子 crew", links: detail.children)
                } else {
                    Text("叶子 crew(无子 crew)—— 驾驶舱只看自己这片")
                        .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private func crewRow(icon: String, label: String, links: [CrewDetail.CrewLink]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.inkMuted).font(.caption)
            Text(label).font(.caption).foregroundStyle(Theme.Palette.inkMuted).frame(width: 52, alignment: .leading)
            FlowText(items: links.map(\.title))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Palette.ink)
    }

    private func pageCount(_ nodes: [HandbookNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.isPage ? 1 : 0) + pageCount($1.children) }
    }
    private func tally(_ statuses: [String]) -> [CockpitStats.StatusCount] {
        var m: [String: Int] = [:]
        for s in statuses { m[cockpitStatusBucket(s), default: 0] += 1 }
        return ["planned", "partial", "pending-qa", "done", "dropped", "other"]
            .compactMap { k in m[k].map { CockpitStats.StatusCount(bucket: k, count: $0) } }
    }
}

// MARK: - 期望(handbook 目录树浏览)

private struct CockpitExpectation: View {
    let data: CockpitData
    @Binding var selectedNodeID: String?
    let nav: (CockpitNav) -> Void

    var body: some View {
        HSplitView {
            List(selection: $selectedNodeID) {
                OutlineGroup(data.handbookTree, children: \.childrenOrNil) { node in
                    Label(node.name, systemImage: node.isPage ? "doc.text" : "folder.fill")
                        .foregroundStyle(node.isPage ? Theme.Palette.ink : Theme.Palette.inkMuted)
                        .font(node.isPage ? .body : .body.weight(.medium))
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 230, idealWidth: 290)

            pageDetail.frame(minWidth: 360)
        }
    }

    @ViewBuilder private var pageDetail: some View {
        if let id = selectedNodeID, let n = node(id, in: data.handbookTree), n.isPage {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 页头并排现状:同一 relpath 的现状条状态(对账一眼读)。
                    if let topic = data.topics.first(where: { $0.expectationRelpath == id }) {
                        Button { nav(.topic(id)) } label: {
                            HStack(spacing: 8) {
                                Text("现状").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                                StatusBadge(raw: topic.status)
                                Text(topic.summary).font(.caption).foregroundStyle(Theme.Palette.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                            }
                            .padding(10)
                            .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let body = CockpitLoader.readExpectation(handbookDir: data.handbookDir, relpath: id) {
                        MarkdownText(text: body, variant: .article)
                    } else {
                        Text("(读不到 docs/handbook/\(id).md)")
                            .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas)
        } else {
            placeholder("从左边目录树选一篇期望页")
        }
    }

    private func node(_ id: String, in nodes: [HandbookNode]) -> HandbookNode? {
        for n in nodes {
            if n.id == id { return n }
            if let f = node(id, in: n.children) { return f }
        }
        return nil
    }
    private func placeholder(_ t: String) -> some View {
        VStack { Spacer(); Text(t).foregroundStyle(Theme.Palette.inkMuted); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.Palette.canvas)
    }
}

// MARK: - 现状(topic 列表 + 详情)

private struct CockpitState: View {
    let data: CockpitData
    @Binding var selectedTopicID: String?
    let nav: (CockpitNav) -> Void

    var body: some View {
        HSplitView {
            topicList.frame(minWidth: 300, idealWidth: 360)
            topicDetail.frame(minWidth: 360)
        }
    }

    private var topicList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedByArea(), id: \.0) { area, items in
                    Text(area)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                    ForEach(items) { topic in
                        topicRow(topic)
                            .background(selectedTopicID == topic.id ? Theme.Palette.accentBg : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTopicID = topic.id }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .background(Theme.Palette.surface)
    }

    private func topicRow(_ topic: CockpitTopic) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(CockpitUI.color(topic.status))
                .frame(width: 4).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.key).font(.system(.body, design: .monospaced)).lineLimit(1)
                Text(topic.summary).font(.caption).foregroundStyle(Theme.Palette.inkMuted).lineLimit(2)
                if !topic.taskIds.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(topic.taskIds, id: \.self) { tid in
                            Text(data.task(tid)?.status ?? "?")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(CockpitUI.color(data.task(tid)?.status ?? "").opacity(0.18), in: Capsule())
                                .foregroundStyle(CockpitUI.color(data.task(tid)?.status ?? ""))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 36)
    }

    @ViewBuilder private var topicDetail: some View {
        if let id = selectedTopicID ?? data.topics.first?.id,
           let topic = data.topics.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(topic.key).font(.system(.title3, design: .monospaced))
                            StatusBadge(raw: topic.status)
                        }
                        Text(topic.summary).foregroundStyle(Theme.Palette.ink)
                        if !topic.evidence.isEmpty, topic.evidence != "—" {
                            Text("证据:\(topic.evidence)").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    let tasks = topic.taskIds.compactMap { data.task($0) }
                    if !tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("task").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                            ForEach(tasks) { task in
                                Button { nav(.task(task.id)) } label: { TaskMiniCard(task: task) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    Divider()
                    Button { nav(.page(topic.expectationRelpath)) } label: {
                        Label("看期望页 \(topic.expectationRelpath)", systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    if let body = CockpitLoader.readExpectation(handbookDir: data.handbookDir, relpath: topic.expectationRelpath) {
                        MarkdownText(text: body, variant: .article)
                    } else {
                        Text("(没找到期望页 docs/handbook/\(topic.expectationRelpath).md)")
                            .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas)
        } else {
            VStack { Spacer(); Text("此 crew 没有现状条(docs/state)").foregroundStyle(Theme.Palette.inkMuted); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.Palette.canvas)
        }
    }

    private func groupedByArea() -> [(String, [CockpitTopic])] {
        var order: [String] = []
        var map: [String: [CockpitTopic]] = [:]
        for t in data.topics {
            if map[t.area] == nil { order.append(t.area) }
            map[t.area, default: []].append(t)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

// MARK: - 任务(task 看板)

private struct CockpitTasks: View {
    let data: CockpitData
    @Binding var selectedTaskID: String?
    let scopeCrewIds: Set<String>?    // nil = 全部;非 nil = 只看这些 crew
    @Binding var scopeOnly: Bool
    let scopeName: String
    let nav: (CockpitNav) -> Void

    private let columns = ["todo", "doing", "pending-qa", "done", "dropped"]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                scopeBar
                Divider()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns, id: \.self) { col in
                            column(col)
                        }
                        let leftovers = filtered.filter { !columns.contains($0.status.lowercased()) }
                        if !leftovers.isEmpty { columnView("其他", leftovers) }
                    }
                    .padding(14)
                }
            }
            .frame(minWidth: 420)
            taskDetail.frame(minWidth: 300, idealWidth: 340)
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 10) {
            if scopeCrewIds != nil || scopeOnly {
                Toggle(isOn: $scopeOnly) { Text("只看「\(scopeName)」子树").font(.caption) }
                    .toggleStyle(.switch).controlSize(.mini)
            } else {
                Toggle(isOn: $scopeOnly) { Text("只看本 crew 子树").font(.caption) }
                    .toggleStyle(.switch).controlSize(.mini)
            }
            Spacer()
            Text("\(filtered.count) / \(data.tasks.count) 个任务")
                .font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var filtered: [CockpitTask] {
        guard let scope = scopeCrewIds else { return data.tasks }
        return data.tasks.filter { scope.contains($0.crew) }
    }

    private func column(_ status: String) -> some View {
        columnView(status, filtered.filter { $0.status.lowercased() == status })
    }

    private func columnView(_ title: String, _ tasks: [CockpitTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(CockpitUI.color(title)).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.ink)
                Text("\(tasks.count)").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
            }
            if tasks.isEmpty {
                Text("—").font(.caption2).foregroundStyle(Theme.Palette.inkMuted).padding(.vertical, 4)
            } else {
                ForEach(tasks) { task in
                    Button { selectedTaskID = task.id } label: { kanbanCard(task) }
                        .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .leading)
    }

    private func kanbanCard(_ task: CockpitTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(task.title.isEmpty ? task.id : task.title).font(.callout).lineLimit(2)
                .foregroundStyle(Theme.Palette.ink)
            HStack(spacing: 6) {
                Text(task.id).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                if task.crew != "~", !task.crew.isEmpty {
                    Text(task.crew).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.Palette.accentBg, in: Capsule()).foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedTaskID == task.id ? Theme.Palette.accentBg : Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.Palette.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var taskDetail: some View {
        if let id = selectedTaskID, let task = data.task(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title.isEmpty ? task.id : task.title).font(.title3.weight(.semibold))
                        HStack(spacing: 8) {
                            StatusBadge(raw: task.status)
                            Text(task.id).font(.caption.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                            if task.crew != "~", !task.crew.isEmpty {
                                Text("crew \(task.crew)").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                            }
                        }
                    }
                    linkSection("期望(expects)", task.expects, icon: "doc.text.magnifyingglass") { nav(.page($0)) }
                    linkSection("现状(state)", task.state, icon: "checklist") { nav(.topic($0)) }
                    if !task.deps.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("依赖(deps)").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                            ForEach(task.deps, id: \.self) { dep in
                                Button { nav(.task(dep)) } label: {
                                    if let dt = data.task(dep) { TaskMiniCard(task: dt) }
                                    else { Label(dep, systemImage: "arrow.triangle.branch").font(.caption) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !task.updated.isEmpty {
                        Text("更新 \(task.updated)").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas)
        } else {
            VStack { Spacer(); Text("选一张卡看 task 详情 + 跨账链接").foregroundStyle(Theme.Palette.inkMuted); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.Palette.canvas)
        }
    }

    @ViewBuilder private func linkSection(_ title: String, _ items: [String], icon: String,
                                          tap: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                ForEach(items, id: \.self) { item in
                    Button { tap(item) } label: {
                        Label(item, systemImage: icon)
                            .font(.caption).foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 共享小件

/// status 色块徽章。
struct StatusBadge: View {
    let raw: String
    var body: some View {
        Text(raw.isEmpty ? "?" : raw)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(CockpitUI.color(raw).opacity(0.18), in: Capsule())
            .foregroundStyle(CockpitUI.color(raw))
    }
}

private struct TaskMiniCard: View {
    let task: CockpitTask
    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(raw: task.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title.isEmpty ? task.id : task.title).font(.callout).lineLimit(1)
                    .foregroundStyle(Theme.Palette.ink)
                Text(task.id).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

/// 状态分布横条(按桶比例上色)。
private struct CockpitDistributionBar: View {
    let dist: [CockpitStats.StatusCount]
    var body: some View {
        let total = max(1, dist.reduce(0) { $0 + $1.count })
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(dist) { c in
                    CockpitUI.color(c.bucket)
                        .frame(width: max(2, geo.size.width * CGFloat(c.count) / CGFloat(total)))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

/// 分布的 chip 图例。
private struct FlowChips: View {
    let dist: [CockpitStats.StatusCount]
    var body: some View {
        FlowText(items: dist.map { "\($0.bucket) \($0.count)" }, colors: dist.map { CockpitUI.color($0.bucket) })
    }
}

/// 极简自动换行行(避免引第三方 flow layout)。等宽分块铺,够用即可。
private struct FlowText: View {
    let items: [String]
    var colors: [Color]? = nil
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 64), spacing: 4)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                Text(item).font(.caption2).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((colors?[idx] ?? Theme.Palette.inkMuted).opacity(0.15), in: Capsule())
                    .foregroundStyle(colors?[idx] ?? Theme.Palette.inkMuted)
            }
        }
    }
}

/// status → 颜色(纯展示,无判 drift)。桶值幂等,传 raw 或 bucket 都行。
enum CockpitUI {
    static func color(_ raw: String) -> Color {
        switch cockpitStatusBucket(raw) {
        case "done": return Theme.Palette.success
        case "pending-qa": return Theme.Palette.gold
        case "partial": return Theme.Palette.amber
        case "planned": return Theme.Palette.inkMuted
        case "dropped": return Theme.Palette.danger
        default: return Theme.Palette.inkMuted
        }
    }
}
#endif
