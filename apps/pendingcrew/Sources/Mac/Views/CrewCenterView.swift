#if os(macOS)
import SwiftUI
import AppKit

/// 中栏：选中 crew 的 detail（spec v2 §12.1 留作群聊位置；当前显示元数据
/// + DAG 邻居 + 责任比例 + "新建 session" 按钮）。
///
/// MVP 阶段不做 share-change 提案 UI / 群聊消息时间线 —— 那是 Phase 4+。
struct CrewCenterView: View {
    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @State private var showingCreateSessionSheet = false
    @State private var showingRemoteSessions = false

    var body: some View {
        Group {
            if let detail = crewStore.selectedDetail {
                content(for: detail)
            } else if let id = crewStore.selectedCrewId, crewStore.loadingDetailIds.contains(id) {
                ProgressView("加载 crew 详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if crewStore.selectedCrewId != nil {
                empty("详情加载中…")
            } else {
                empty("在左侧选一个 crew，或者点 \"+\" 新建一个。")
            }
        }
        .toolbar {
            if let detail = crewStore.selectedDetail {
                ToolbarItem {
                    Button {
                        Task { await crewStore.refreshDetail(detail.crew.id) }
                    } label: {
                        Label("刷新详情", systemImage: "arrow.clockwise")
                    }
                }
                // T4.5 viewer — watch this crew's server sessions (incl. ones
                // running on another host) by reading the durable event log.
                ToolbarItem {
                    Button {
                        showingRemoteSessions = true
                    } label: {
                        Label("服务端 session", systemImage: "rectangle.on.rectangle.angled")
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateSessionSheet) {
            if let detail = crewStore.selectedDetail {
                CreateSessionSheet(detail: detail)
                    .environmentObject(sessionRunner)
            }
        }
        .sheet(isPresented: $showingRemoteSessions) {
            if let detail = crewStore.selectedDetail {
                RemoteSessionsView(crewId: detail.crew.id, crewTitle: detail.crew.title)
            }
        }
    }

    @ViewBuilder
    private func content(for detail: CrewDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(detail)
                captainSection(detail)
                linkSection("父 crew", links: detail.parents)
                linkSection("子 crew", links: detail.children)
                sharesSection(detail)
                Divider()
                Button {
                    showingCreateSessionSheet = true
                } label: {
                    Label("新建 session", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func header(_ detail: CrewDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.crew.title)
                .font(.title2.weight(.semibold))
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
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(wd)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        revealInFinder(wd)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中打开")
                }
            }
        }
    }

    @ViewBuilder
    private func captainSection(_ detail: CrewDetail) -> some View {
        sectionHeader("机长")
        if let captain = detail.captain {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.tint)
                Text(captain.displayName)
                Spacer()
                Text(captain.botId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        } else {
            Text("(无机长)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func linkSection(_ title: String, links: [CrewDetail.CrewLink]) -> some View {
        sectionHeader(title)
        if links.isEmpty {
            Text("(无)")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(links, id: \.crewId) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
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
    private func sharesSection(_ detail: CrewDetail) -> some View {
        sectionHeader("责任比例")
        if detail.shares.isEmpty {
            Text("(尚未结算)")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.shares, id: \.subjectId) { share in
                    HStack(spacing: 8) {
                        Image(systemName: share.kind == "group_account"
                              ? "person.3" : "person.crop.circle")
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
        let pct = Double(bps) / 100.0
        return String(format: "%.2f", pct)
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func revealInFinder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
