#if os(macOS)
import SwiftUI

/// 驾驶舱(cockpit)看板 — read-only MVP。
///
/// cockpit.md:对账的**呈现面**。读某 crew 工作目录里的三本账(期望 docs/handbook /
/// 现状 docs/state / task docs/tasks),按 topic 摆出来,status 渲成色块,**差靠人扫两栏读**——
/// 不替人判 drift、零 violation / 一致性检查(handbook 边界)。正文交给 `MarkdownText` 原样渲。
///
/// 控制半边(看差生 session)+ per-crew DAG 过滤是后续增量。
struct CockpitView: View {
    let detail: CrewDetail

    @State private var data: CockpitData?
    @State private var filter: String = "all"   // all / planned / partial / pending-qa / done / other
    @State private var selectedTopicID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let data {
                if data.topics.isEmpty {
                    emptyState("此 crew 工作目录里没有三本账(docs/state)")
                } else {
                    HSplitView {
                        topicList(data)
                            .frame(minWidth: 300, idealWidth: 360)
                        topicDetail(data)
                            .frame(minWidth: 380)
                    }
                }
            } else {
                emptyState(detail.crew.workingDirectory?.isEmpty == false
                    ? "读取中…"
                    : "此 crew 没有本地工作目录,驾驶舱只渲染本地 crew 的三本账")
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Theme.Palette.canvas)
        .onAppear(perform: reload)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("驾驶舱").font(.headline)
                Text(detail.crew.title).font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer()
            statusFilter
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("重新读三本账")
            Button("关闭") { dismiss() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var statusFilter: some View {
        Picker("", selection: $filter) {
            Text("全部").tag("all")
            Text("planned").tag("planned")
            Text("partial").tag("partial")
            Text("pending-qa").tag("pending-qa")
            Text("done").tag("done")
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    // MARK: topic list (看板半边)

    private func topicList(_ data: CockpitData) -> some View {
        let topics = data.topics.filter { filter == "all" || Self.bucket($0.status) == filter }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedByArea(topics), id: \.0) { area, items in
                    Text(area)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                    ForEach(items) { topic in
                        topicRow(topic, data: data)
                            .background(selectedTopicID == topic.id ? Theme.Palette.accentBg : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTopicID = topic.id }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .background(Theme.Palette.surface)
    }

    private func topicRow(_ topic: CockpitTopic, data: CockpitData) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.color(topic.status))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.key).font(.system(.body, design: .monospaced)).lineLimit(1)
                Text(topic.summary).font(.caption).foregroundStyle(Theme.Palette.inkMuted).lineLimit(2)
                if !topic.taskIds.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(topic.taskIds, id: \.self) { tid in
                            taskChip(tid, data: data)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: 36)
    }

    private func taskChip(_ id: String, data: CockpitData) -> some View {
        let st = data.task(id)?.status ?? "?"
        return Text(st)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Self.color(st).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(st))
    }

    // MARK: topic detail (期望 | 现状 | task 卡)

    private func topicDetail(_ data: CockpitData) -> some View {
        Group {
            if let id = selectedTopicID ?? data.topics.first?.id,
               let topic = data.topics.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 现状
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(topic.key).font(.system(.title3, design: .monospaced))
                                statusBadge(topic.status)
                            }
                            Text(topic.summary).foregroundStyle(Theme.Palette.ink)
                            if !topic.evidence.isEmpty, topic.evidence != "—" {
                                Text("证据:\(topic.evidence)").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                            }
                        }
                        // linked tasks
                        let tasks = topic.taskIds.compactMap { data.task($0) }
                        if !tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("task").font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.inkMuted)
                                ForEach(tasks) { task in taskCard(task) }
                            }
                        }
                        Divider()
                        // 期望页 markdown
                        if let body = CockpitLoader.readExpectation(handbookDir: data.handbookDir, relpath: topic.expectationRelpath) {
                            MarkdownText(text: body, variant: .article)
                        } else {
                            Text("(没找到期望页 docs/handbook/\(topic.expectationRelpath).md)")
                                .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyState("选一条看 期望 | 现状 | task")
            }
        }
        .background(Theme.Palette.canvas)
    }

    private func taskCard(_ task: CockpitTask) -> some View {
        HStack(spacing: 8) {
            statusBadge(task.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.callout).lineLimit(1)
                Text(task.id).font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ raw: String) -> some View {
        Text(raw)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Self.color(raw).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(raw))
    }

    private func emptyState(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(Theme.Palette.inkMuted); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: data

    private func reload() {
        guard let workdir = detail.crew.workingDirectory, !workdir.isEmpty else { data = nil; return }
        data = CockpitLoader.load(crewRoot: URL(fileURLWithPath: workdir))
    }

    private func groupedByArea(_ topics: [CockpitTopic]) -> [(String, [CockpitTopic])] {
        var order: [String] = []
        var map: [String: [CockpitTopic]] = [:]
        for t in topics {
            if map[t.area] == nil { order.append(t.area) }
            map[t.area, default: []].append(t)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    // MARK: status → color / bucket (纯展示,无判 drift)

    static func bucket(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("pending-qa") { return "pending-qa" }
        if s.hasPrefix("done") { return "done" }
        if s.hasPrefix("partial") || s == "doing" { return "partial" }
        if s.hasPrefix("planned") || s == "todo" { return "planned" }
        return "other"
    }

    static func color(_ raw: String) -> Color {
        switch bucket(raw) {
        case "done": return Theme.Palette.success
        case "pending-qa": return Theme.Palette.gold
        case "partial": return Theme.Palette.amber
        case "planned": return Theme.Palette.inkMuted
        default:
            return raw.lowercased() == "dropped" ? Theme.Palette.danger : Theme.Palette.inkMuted
        }
    }
}
#endif
