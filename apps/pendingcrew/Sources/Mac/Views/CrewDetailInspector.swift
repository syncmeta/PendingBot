#if os(macOS)
import SwiftUI
import AppKit

/// crew 详情 / 设置面板（spec §9 把它从中栏挪出来，中栏改放群聊）。
/// 显示 crew 元数据 + 机长 + 父/子 crew(DAG) + 责任比例 + 工作目录。
/// 以 inspector sheet 形式从 `CrewCenterView` 顶栏 ⓘ 打开。
struct CrewDetailInspector: View {
    let detail: CrewDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    captainSection
                    linkSection("父 crew", links: detail.parents)
                    linkSection("子 crew", links: detail.children)
                    sharesSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 420, minHeight: 440)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("crew 详情").font(.headline) }
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.crew.title).font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Label(detail.crew.runtimeLocationKind?.shortLabel ?? detail.crew.runtimeLocation,
                      systemImage: detail.crew.runtimeLocationKind?.displayIcon ?? "questionmark.circle")
                if let tag = detail.crew.tag, !tag.isEmpty {
                    Label(tag, systemImage: "tag")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let wd = detail.crew.workingDirectory, !wd.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(wd)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { revealInFinder(wd) } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中打开")
                }
            }
        }
    }

    @ViewBuilder
    private var captainSection: some View {
        sectionHeader("机长")
        if let captain = detail.captain {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.tint)
                Text(captain.displayName)
                Spacer()
                Text(captain.botId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        } else {
            Text("(无机长)").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func linkSection(_ title: String, links: [CrewDetail.CrewLink]) -> some View {
        sectionHeader(title)
        if links.isEmpty {
            Text("(无)").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(links, id: \.crewId) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        Text(link.title)
                        Spacer()
                        Text("\(sharePercent(link.childShareBps))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sharesSection: some View {
        sectionHeader("责任比例")
        if detail.shares.isEmpty {
            Text("(尚未结算)").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.shares, id: \.subjectId) { share in
                    HStack(spacing: 8) {
                        Image(systemName: share.kind == "group_account" ? "person.3" : "person.crop.circle")
                            .foregroundStyle(.secondary)
                        Text(share.displayName.isEmpty ? share.subjectId : share.displayName)
                            .lineLimit(1)
                        if share.isTiebreaker {
                            Text("决胜")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                        Spacer()
                        Text("\(sharePercent(share.shareBps))%")
                            .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func sharePercent(_ bps: Int) -> String {
        String(format: "%.2f", Double(bps) / 100.0)
    }

    private func revealInFinder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }
}
#endif
