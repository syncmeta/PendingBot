#if os(macOS)
import SwiftUI

/// 路线段 —— 渲染第四本账 docs/roadmap.md(阶段骨架人写、进度从现状账实时派生)。
/// 纯呈现 + 复用控制半边:非 done 条目一步生 session 补差;坏链渲警示色靠人读,无自动断言。
struct CockpitRoadmapSegment: View {
    let data: CockpitData
    let nav: (CockpitNav) -> Void
    let onSpawnBrief: (CockpitTopic) -> Void

    var body: some View {
        if let roadmap = data.roadmap {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !roadmap.preamble.isEmpty {
                        MarkdownText(text: roadmap.preamble, variant: .article)
                    }
                    ForEach(roadmap.phases) { phase in phaseCard(phase) }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Palette.canvas)
        } else {
            emptyGuide
        }
    }

    // MARK: 阶段卡

    private func phaseCard(_ phase: CockpitPhase) -> some View {
        let dist = cockpitPhaseProgress(phase, topics: data.topics)
        let done = dist.first(where: { $0.bucket == "done" })?.count ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(raw: phase.status)
                Text(phase.name).font(.headline)
                if !phase.target.isEmpty {
                    Text(phase.target).font(.caption.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
                }
                Spacer(minLength: 8)
                Text("\(done)/\(phase.entries.count) done")
                    .font(.caption2.monospaced()).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !phase.goal.isEmpty {
                Text(phase.goal).font(.callout).foregroundStyle(Theme.Palette.inkMuted)
            }
            if !phase.entries.isEmpty {
                CockpitDistributionBar(dist: dist)
                VStack(spacing: 0) {
                    ForEach(Array(phase.entries.enumerated()), id: \.offset) { idx, entry in
                        entryRow(entry)
                        if idx < phase.entries.count - 1 { Divider() }
                    }
                }
                .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("（此阶段还没挂期望页）").font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 条目行

    private func entryRow(_ entry: CockpitPhaseEntry) -> some View {
        let topic = data.topics.first { $0.expectationRelpath == entry.relpath }
        let pageExists = FileManager.default.fileExists(
            atPath: data.handbookDir.appendingPathComponent("\(entry.relpath).md").path)
        let bucket = topic.map { cockpitStatusBucket($0.status) } ?? "unfiled"
        return HStack(alignment: .center, spacing: 10) {
            Button { nav(.topic(entry.relpath)) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.relpath).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(pageExists ? Theme.Palette.ink : Theme.Palette.danger)
                        if !entry.note.isEmpty {
                            Text(entry.note).font(.caption2).foregroundStyle(Theme.Palette.inkMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if !pageExists {
                        // 坏链:期望页不存在。纯呈现警示,靠人读后手改 roadmap(无自动断言)。
                        Text("期望页不存在").font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.Palette.danger.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.Palette.danger)
                    } else if let topic {
                        StatusBadge(raw: topic.status)
                        Text(topic.summary).font(.caption).foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1).frame(maxWidth: 260, alignment: .trailing)
                    } else {
                        Text("未入账").font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.Palette.inkMuted.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if pageExists, bucket != "done" {
                Button { onSpawnBrief(topic ?? syntheticTopic(entry.relpath)) } label: {
                    Image(systemName: "bolt.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Palette.accent)
                .help("把这条期望当 brief,生 session 补差")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 期望页还没入现状账时,合成一个空 topic 供 spawnBrief 组 brief(期望原文照读)。
    private func syntheticTopic(_ relpath: String) -> CockpitTopic {
        let parts = relpath.split(separator: "/", maxSplits: 1).map(String.init)
        return CockpitTopic(
            area: parts.first ?? relpath, key: parts.count > 1 ? parts[1] : "",
            status: "", summary: "(未入账——期望还没进现状账)",
            evidence: "", taskIds: [], taskRaw: "")
    }

    // MARK: 空态引导

    private var emptyGuide: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("这个仓库还没有路线账").font(.headline)
            Text("在仓库根建 docs/roadmap.md(人定骨架:主线 + 阶段;captain 填血肉)。格式:")
                .font(.caption).foregroundStyle(Theme.Palette.inkMuted)
            Text("""
            > 路线账。阶段按文件顺序排先后。

            当前主线一段话。

            ## v1 收口
            status: doing
            target: 2026-08
            目标: 一句话阶段目标。
            - pendingcrew/concepts/cockpit — 备注可选
            """)
            .font(.caption.monospaced())
            .padding(12)
            .background(Theme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }
}
#endif
