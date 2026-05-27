import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $model.selection)
        } detail: {
            DetailRouter(selection: model.selection)
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBarView()
        }
    }
}

private struct DetailRouter: View {
    @EnvironmentObject private var model: AppModel
    let selection: AppModel.Selection?

    var body: some View {
        switch selection {
        case .crews, .none:
            CrewHomeView()
        case .crew(let crewId):
            CrewDetailView(crewId: crewId)
        case .runnerHosts:
            RunnerHostsView()
        case .helpRequests:
            HumanHelpRequestsView()
        case .settings:
            SettingsView()
        }
    }
}

private struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text(model.statusMessage.isEmpty ? "就绪" : model.statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(model.apiBaseURL)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
