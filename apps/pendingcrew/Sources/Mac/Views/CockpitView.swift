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
    @EnvironmentObject private var model: AppModel   // 控制半边:拿 backend 渲世界观

    @State private var data: CockpitData?
    @State private var segment: Segment = .dashboard
    @State private var selectedNodeID: String?    // 期望:选中的 handbook 节点 id(页 relpath)
    @State private var selectedTopicID: String?   // 现状:选中的 topic id
    @State private var selectedTaskID: String?    // 任务:选中的 task id
    @State private var taskScopeOnly = false      // 任务:只看本 crew 子树
    @State private var spawnNotice: String?       // 控制半边:派 session 的反馈(成功/失败)

    enum Segment: String, CaseIterable, Identifiable {
        case dashboard = "总览", roadmap = "路线", expectation = "期望", state = "现状", tasks = "任务"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.33percent"
            case .roadmap: return "map"
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
            if let spawnNotice {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.Palette.accent)
                    Text(spawnNotice).font(.caption)
                    Spacer(minLength: 0)
                    Button { self.spawnNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.Palette.accentBg)
            }
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
                CockpitDashboard(data: data, detail: crewStore.selectedDetail, nav: handleNav,
                                 openRoadmap: { segment = .roadmap })
            case .roadmap:
                CockpitRoadmapSegment(data: data, nav: handleNav, onSpawnBrief: spawnBrief)
            case .expectation:
                CockpitExpectation(data: data, selectedNodeID: $selectedNodeID, nav: handleNav)
            case .state:
                CockpitState(data: data, selectedTopicID: $selectedTopicID, nav: handleNav,
                             onSpawnBrief: spawnBrief)
            case .tasks:
                CockpitTasks(data: data, selectedTaskID: $selectedTaskID,
                             scopeCrewIds: taskScopeOnly ? scopeCrewIds : nil,
                             scopeOnly: $taskScopeOnly, scopeName: scopeName, nav: handleNav)
            }
        } else {
            emptyState(crewStore.selectedDetail == nil
                ? "选一个 crew 看它的驾驶舱"
                : "此 crew 的工作目录里没有三本账(docs/handbook · state · tasks)。\n让某个 crew 的工作目录指向带这三本账的仓库(比如大绿豆自己),驾驶舱就渲染真数据。")
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

    // MARK: 控制半边 —— 看着差,直接生一个 session 去补(cockpit.md:terraform apply,人审不自动)

    /// 把某条现状的「期望 + 当前现状」当 brief,真起一个 worker session 去对齐。
    /// 不排队、不冒 chip —— 一个动作直接派下去(handbook 边界)。派完退出驾驶舱,
    /// 在三栏里看新 session 跑。
    private func spawnBrief(for topic: CockpitTopic) {
        guard let data, let detail = crewStore.selectedDetail else { return }
        let expectation = CockpitLoader.readExpectation(
            handbookDir: data.handbookDir, relpath: topic.expectationRelpath) ?? "(期望页缺失)"
        let brief = """
        对齐期望与现状的差(驾驶舱控制半边派单)。

        主题:\(topic.key)
        当前现状:\(topic.summary)(status: \(topic.status))

        期望(docs/handbook/\(topic.expectationRelpath).md):
        \(expectation)

        请把代码 / 产物对齐到上面这段期望;完成后刷新现状那本(docs/state/\(topic.area).md 里对应条目)让差消失。
        """
        Task {
            do {
                try await runner.startForBrief(detail: detail, backend: model.backend, brief: brief)
                runner.viewingTerminal = true
                runner.showingCockpit = false      // 退出驾驶舱,去三栏看 session 跑
            } catch {
                spawnNotice = "派 session 失败:\(error.localizedDescription)"
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
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
    let openRoadmap: () -> Void

    var body: some View {
        let stats = data.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let roadmap = data.roadmap,
                   let current = roadmap.phases.first(where: { cockpitStatusBucket($0.status) == "partial" }) {
                    currentPhaseCard(current)
                }
                statCards(stats)
                if !stats.recentTasks.isEmpty { recentTasks(stats) }
                modules
                if let detail { dagMap(detail) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 「当前阶段」摘要卡 —— 第一个 doing 阶段 + 派生进度,点击去路线段。
    private func currentPhaseCard(_ phase: CockpitPhase) -> some View {
        Button(action: openRoadmap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "map").foregroundStyle(Theme.Palette.accent)
                    Text("当前阶段").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                    Text(phase.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.Palette.ink)
                    if !phase.target.isEmpty {
                        Text(phase.target).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.Palette.inkMuted)
                }
                if !phase.goal.isEmpty {
                    Text(phase.goal).font(.caption).foregroundStyle(Theme.Palette.inkMuted).lineLimit(1)
                }
                CockpitDistributionBar(dist: cockpitPhaseProgress(phase, topics: data.topics))
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// MARK: - 期望(handbook 书本目录浏览)

/// 期望段 = 书本目录:左树像书目录(无图标、紧凑、章 semibold / 节 regular、节尾现状色点),
/// 右栏翻到哪章/哪节看哪页 —— 章(目录)的正文只认该目录下的 README.md(spec 2026-07-11),
/// 根 README.md 当"全书序"(未选中时默认渲)。
private struct CockpitExpectation: View {
    let data: CockpitData
    @Binding var selectedNodeID: String?
    let nav: (CockpitNav) -> Void

    var body: some View {
        CockpitSplit(leftWidth: 260) {
            List(selection: $selectedNodeID) {
                OutlineGroup(data.handbookTree, children: \.childrenOrNil) { node in
                    tocRow(node)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
        } right: {
            pageDetail
        }
    }

    /// 书目录行:章 semibold、节 regular;节尾缀同 relpath 现状条的状态色点(纯展示,不判 drift)。
    private func tocRow(_ node: HandbookNode) -> some View {
        HStack(spacing: 6) {
            Text(node.name)
                .font(.system(size: 12.5, weight: node.isPage ? .regular : .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if node.isPage, let topic = data.topics.first(where: { $0.expectationRelpath == node.id }) {
                Circle().fill(CockpitUI.color(topic.status))
                    .frame(width: 6, height: 6)
                    .help("现状:\(topic.status)")
            }
        }
    }

    @ViewBuilder private var pageDetail: some View {
        if let id = selectedNodeID, let n = node(id, in: data.handbookTree) {
            if n.isPage {
                pageBody(relpath: id)
            } else {
                chapterBody(n)
            }
        } else {
            // 全书序:根 README.md;没有就退回引导文案。
            if let body = CockpitLoader.readExpectation(handbookDir: data.handbookDir, relpath: "README") {
                article { MarkdownText(text: body, variant: .article) }
            } else {
                placeholder("从左边目录选一章或一节")
            }
        }
    }

    /// 节(页)正文:页头并排现状 + markdown。
    private func pageBody(relpath id: String) -> some View {
        article {
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
    }

    /// 章(目录)正文:只认该目录下的 README.md;没有就一行占位(引言归人写,UI 不合成)。
    @ViewBuilder private func chapterBody(_ n: HandbookNode) -> some View {
        if let body = CockpitLoader.readExpectation(handbookDir: data.handbookDir, relpath: "\(n.id)/README") {
            article { MarkdownText(text: body, variant: .article) }
        } else {
            placeholder("本章还没有引言(docs/handbook/\(n.id)/README.md)")
        }
    }

    private func article<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas)
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
    let onSpawnBrief: (CockpitTopic) -> Void   // 控制半边:看着这条差,真起 session 去补

    var body: some View {
        CockpitSplit(leftWidth: 330) {
            topicList
        } right: {
            topicDetail
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
                    // 控制半边:读出差 → 一步生 session 去补(cockpit.md:terraform apply,人审不自动)
                    Button { onSpawnBrief(topic) } label: {
                        Label("生 session 补差", systemImage: "bolt.fill").font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .help("把这条期望当 brief,真起一个 session 去对齐(不排队、不冒 chip)")
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
        CockpitSplit(rightWidth: 320) {
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
        } right: {
            taskDetail
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

/// 驾驶舱内的左右分栏 —— 用 GeometryReader 按**可用宽度**切。内容无 min 宽需求,所以永远
/// 等于可用宽、绝不向 NavigationSplitView detail 列要更多宽把 sidebar 顶出去(HSplitView 两侧
/// minWidth 相加会顶 sidebar/toolbar 出屏,见 tech-debt「inspector 被切」、memory「detail ideal 太贪」)。
private struct CockpitSplit<L: View, R: View>: View {
    var leftWidth: CGFloat? = nil    // 固定左宽(右弹性);期望/现状用
    var rightWidth: CGFloat? = nil   // 固定右宽(左弹性);任务看板用
    @ViewBuilder var left: () -> L
    @ViewBuilder var right: () -> R

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let (lw, rw) = split(total)
            HStack(spacing: 0) {
                left().frame(width: lw)
                Divider()
                right().frame(width: rw)
            }
        }
    }

    /// 左 + 右 + divider 恒等于 total —— 永不外溢。
    private func split(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let d: CGFloat = 1
        if let l = leftWidth {
            let lw = max(160, min(l, total - 220))   // 左固定,但至少给右 220
            return (lw, max(0, total - lw - d))
        }
        if let r = rightWidth {
            let rw = max(160, min(r, total - 260))   // 右固定,但至少给左 260
            return (max(0, total - rw - d), rw)
        }
        return ((total - d) / 2, (total - d) / 2)
    }
}

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

/// 状态分布横条(按桶比例上色)。internal(非 private):供 CockpitRoadmapView.swift 复用。
struct CockpitDistributionBar: View {
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
