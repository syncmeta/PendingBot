import SwiftUI

public struct PendingBotBigScreenAppView: View {
    @State private var selectedTab: PendingBotBigScreenTab = .message
    @State private var selectedCrewId: String?

    private let crews: [PendingBotCrewSummary]

    public init(crews: [PendingBotCrewSummary] = []) {
        self.crews = crews
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("PendingBot") {
                    ForEach(PendingBotBigScreenTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
            }
            .navigationTitle("PendingBot")
        } content: {
            tabContent
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .message:
            PendingBotPlaceholderList(title: "消息", systemImage: "bubble.left.and.bubble.right")
        case .friends:
            PendingBotPlaceholderList(title: "好友", systemImage: "person.2")
        case .crew:
            PendingBotCrewList(crews: crews, selectedCrewId: $selectedCrewId)
        case .envelope:
            PendingBotPlaceholderList(title: "来信", systemImage: "envelope.open")
        case .me:
            PendingBotPlaceholderList(title: "我", systemImage: "person.crop.circle")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedTab == .crew, let selectedCrewId,
           let crew = crews.first(where: { $0.id == selectedCrewId }) {
            PendingBotCrewDetailPlaceholder(crew: crew)
        } else {
            ContentUnavailableView(selectedTab.title, systemImage: selectedTab.systemImage)
        }
    }
}

private struct PendingBotCrewList: View {
    let crews: [PendingBotCrewSummary]
    @Binding var selectedCrewId: String?

    var body: some View {
        List(selection: $selectedCrewId) {
            Section("机组") {
                ForEach(PendingBotCrewSidebarRow.rows(for: crews)) { row in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: row.systemImage)
                    }
                    .tag(row.id)
                }
            }
        }
        .navigationTitle("机组")
    }
}

private struct PendingBotCrewDetailPlaceholder: View {
    let crew: PendingBotCrewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(crew.title)
                .font(.title2.weight(.semibold))
            Text("\(crew.runtimeKind.title) · \(crew.status)")
                .foregroundStyle(.secondary)
            Divider()
            ContentUnavailableView("机组群聊", systemImage: "bubble.left.and.bubble.right")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PendingBotPlaceholderList: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .navigationTitle(title)
    }
}
