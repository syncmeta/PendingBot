import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: AppModel.Selection?

    var body: some View {
        List(selection: $selection) {
            Section("工作区") {
                Label("Crew", systemImage: "person.3.sequence")
                    .tag(AppModel.Selection.crews)

                Label("Runner", systemImage: "desktopcomputer")
                    .tag(AppModel.Selection.runnerHosts)

                Label("有求于你", systemImage: "tray.and.arrow.down")
                    .tag(AppModel.Selection.helpRequests)
            }

            Section("Crew") {
                ForEach(model.crews) { crew in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(crew.title)
                            .lineLimit(1)
                        Text(crew.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(AppModel.Selection.crew(crew.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PendingBot")
    }
}

