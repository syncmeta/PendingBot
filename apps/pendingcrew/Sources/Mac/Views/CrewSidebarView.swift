#if os(macOS)
import SwiftUI

/// 左栏：crew 列表 + toolbar（新建 / 刷新）。
///
/// MVP 阶段是平铺 list —— DAG 树形 sidebar 留下次（spec v2 §12.1 说明）。
/// `runtimeLocation` 用一个 systemImage + 缩写标签提示用户这是 local /
/// peer / fly。
struct CrewSidebarView: View {
    @EnvironmentObject private var crewStore: CrewStore
    @State private var showingCreateSheet = false

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                if crewStore.crews.isEmpty {
                    emptyRow
                } else {
                    ForEach(crewStore.crews) { crew in
                        CrewRow(crew: crew).tag(crew.id)
                    }
                }
            } header: {
                Text("Crew")
            }
            // Machines section — 占位提示(v1.1 才接真 Fly machine 列表)。
            // BYOK 模式显示 "登录解锁" prompt;登录模式显示 v1.1 placeholder。
            // 这条目前不可选(没 tag),只展示状态。
            Section {
                machinesRow
            } header: {
                Text("Machines")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PendingCrew")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("新建 crew", systemImage: "plus")
                }
                .help("新建 crew")
                Button {
                    Task { await crewStore.refreshList() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新 crew 列表")
                .disabled(crewStore.loadingList)
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateCrewSheet()
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { crewStore.selectedCrewId },
            set: { crewStore.selectCrew($0) }
        )
    }

    /// 根据 backend.mode 切两种 placeholder。
    /// - logged → "Fly machine — v1.1 上线"(灰显)
    /// - byok → "登录 PendingBot 解锁云端 Fly machine"(灰显 + 锁图标)
    @ViewBuilder
    private var machinesRow: some View {
        if crewStore.supportsCloudRuntime {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fly machine")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("v1.1 上线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("云端 Fly machine")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("登录 PendingBot 解锁")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if crewStore.loadingList {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…").foregroundStyle(.secondary)
                }
            } else {
                Text("还没有 crew")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("点上面 + 创建第一个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct CrewRow: View {
    let crew: CrewSummary

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: crew.runtimeLocationKind?.displayIcon ?? "questionmark.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(crew.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(crew.runtimeLocationKind?.shortLabel ?? crew.runtimeLocation)
                    if let tag = crew.tag, !tag.isEmpty {
                        Text("·")
                        Text(tag).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
