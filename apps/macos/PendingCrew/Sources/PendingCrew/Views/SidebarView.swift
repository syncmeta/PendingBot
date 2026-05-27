import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: AppModel.Selection?
    @State private var collapsedCrewIds: Set<String> = []

    private var rows: [CrewSidebarRow] {
        CrewSidebarIndex.flatten(crews: model.crews, linksByCrew: model.linksByCrew)
    }

    private var visibleRows: [CrewSidebarRow] {
        var output: [CrewSidebarRow] = []
        var hiddenParentDepth: Int?
        for row in rows {
            if let depth = hiddenParentDepth, row.depth > depth {
                continue
            }
            if let depth = hiddenParentDepth, row.depth <= depth {
                hiddenParentDepth = nil
            }
            output.append(row)
            if collapsedCrewIds.contains(row.crewId) {
                hiddenParentDepth = row.depth
            }
        }
        return output
    }

    var body: some View {
        List(selection: $selection) {
            Section("工作区") {
                Label("机组", systemImage: "person.3.sequence")
                    .tag(AppModel.Selection.crews)

                Label("Runner", systemImage: "desktopcomputer")
                    .tag(AppModel.Selection.runnerHosts)

                Label("有求于你", systemImage: "tray.and.arrow.down")
                    .tag(AppModel.Selection.helpRequests)

                Label("设置", systemImage: "gearshape")
                    .tag(AppModel.Selection.settings)
            }

            Section("机组索引") {
                if visibleRows.isEmpty {
                    Text("还没有机组")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleRows) { row in
                        CrewSidebarRowView(
                            row: row,
                            isSelected: selection == .crew(row.crewId),
                            hasChildren: hasChildren(row.crewId),
                            isCollapsed: collapsedCrewIds.contains(row.crewId),
                            onToggle: { toggle(row.crewId) }
                        )
                        .tag(AppModel.Selection.crew(row.crewId))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = .crew(row.crewId)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PendingBot")
    }

    private func hasChildren(_ crewId: String) -> Bool {
        !(model.linksByCrew[crewId]?.children.isEmpty ?? true)
    }

    private func toggle(_ crewId: String) {
        if collapsedCrewIds.contains(crewId) {
            collapsedCrewIds.remove(crewId)
        } else {
            collapsedCrewIds.insert(crewId)
        }
    }
}

private struct CrewSidebarRowView: View {
    let row: CrewSidebarRow
    let isSelected: Bool
    let hasChildren: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: CGFloat(row.depth) * 14)

            if hasChildren {
                Button(action: onToggle) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 18)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 14, height: 18)
            }

            Image(systemName: row.depth == 0 ? "person.3.sequence" : "arrow.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(row.status)
                    Text(row.runtimeKind)
                    if row.captainBotId != nil {
                        Text("机长")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}
