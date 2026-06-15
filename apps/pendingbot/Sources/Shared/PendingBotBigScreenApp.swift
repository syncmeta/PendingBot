import SwiftUI

public struct PendingBotBigScreenAppView: View {
    @State private var selectedTab: PendingBotBigScreenTab = .message
    @Binding private var selectedCrewId: String?

    private let crews: [PendingBotCrewSummary]
    private let crewDetails: [String: PendingBotCrewDetail]
    private let crewListLoading: Bool
    private let crewDetailLoadingIds: Set<String>
    private let crewDetailErrors: [String: String]
    private let onRefresh: () -> Void
    private let onSelectCrew: (String) -> Void
    private let onSendAnnouncement: (String, String) -> Void
    private let onCreateSession: (String, PendingBotCrewRunnerKind, String) -> Void
    private let onCreateChildCrew: (String, String) -> Void

    public init(
        crews: [PendingBotCrewSummary] = [],
        selectedCrewId: Binding<String?> = .constant(nil),
        crewDetails: [String: PendingBotCrewDetail] = [:],
        crewListLoading: Bool = false,
        crewDetailLoadingIds: Set<String> = [],
        crewDetailErrors: [String: String] = [:],
        onRefresh: @escaping () -> Void = {},
        onSelectCrew: @escaping (String) -> Void = { _ in },
        onSendAnnouncement: @escaping (String, String) -> Void = { _, _ in },
        onCreateSession: @escaping (String, PendingBotCrewRunnerKind, String) -> Void = { _, _, _ in },
        onCreateChildCrew: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.crews = crews
        self._selectedCrewId = selectedCrewId
        self.crewDetails = crewDetails
        self.crewListLoading = crewListLoading
        self.crewDetailLoadingIds = crewDetailLoadingIds
        self.crewDetailErrors = crewDetailErrors
        self.onRefresh = onRefresh
        self.onSelectCrew = onSelectCrew
        self.onSendAnnouncement = onSendAnnouncement
        self.onCreateSession = onCreateSession
        self.onCreateChildCrew = onCreateChildCrew
    }

    public var body: some View {
        NavigationSplitView {
            Group {
                #if os(macOS)
                List(selection: $selectedTab) {
                    Section("PendingBot") {
                        ForEach(PendingBotBigScreenTab.allCases) { tab in
                            Label {
                                Text(tab.title)
                            } icon: {
                                tab.symbol.image
                            }
                                .tag(tab)
                        }
                    }
                }
                #else
                List {
                    Section("PendingBot") {
                        ForEach(PendingBotBigScreenTab.allCases) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                Label {
                                    Text(tab.title)
                                } icon: {
                                    tab.symbol.image
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                #endif
            }
            .navigationTitle("PendingBot")
        } content: {
            tabContent
        } detail: {
            detailContent
        }
        .onAppear(perform: selectCrewIfNeeded)
        .onChange(of: selectedTab) { _, _ in
            selectCrewIfNeeded()
        }
        .onChange(of: crews.map(\.id)) { _, _ in
            selectCrewIfNeeded()
        }
        .onChange(of: selectedCrewId) { _, crewId in
            if let crewId {
                onSelectCrew(crewId)
            }
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
            PendingBotCrewList(
                crews: crews,
                isLoading: crewListLoading,
                selectedCrewId: $selectedCrewId,
                onRefresh: onRefresh
            )
        case .envelope:
            PendingBotPlaceholderList(title: "来信", systemImage: "envelope.open")
        case .me:
            PendingBotPlaceholderList(title: "我", systemImage: "person.crop.circle")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedTab == .crew, let currentCrewId = selectedCrewId,
           let crew = crews.first(where: { $0.id == currentCrewId }) {
            PendingBotCrewDetailView(
                crew: crew,
                detail: crewDetails[currentCrewId],
                isLoading: crewDetailLoadingIds.contains(currentCrewId),
                errorMessage: crewDetailErrors[currentCrewId],
                onRefresh: onRefresh,
                onSendAnnouncement: { message in
                    onSendAnnouncement(currentCrewId, message)
                },
                onCreateSession: { runnerKind, taskBrief in
                    onCreateSession(currentCrewId, runnerKind, taskBrief)
                },
                onCreateChildCrew: { title in
                    onCreateChildCrew(currentCrewId, title)
                },
                onOpenCrew: { crewId in
                    selectedCrewId = crewId
                }
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text(selectedTab.title)
                } icon: {
                    selectedTab.symbol.image
                }
            }
        }
    }

    private func selectCrewIfNeeded() {
        guard selectedTab == .crew else { return }
        let crewIds = Set(crews.map(\.id))
        if let selectedCrewId, crewIds.contains(selectedCrewId) {
            return
        }
        selectedCrewId = crews.first?.id
    }
}

public struct PendingBotCrewWorkspaceView: View {
    @Binding private var selectedCrewId: String?

    private let crews: [PendingBotCrewSummary]
    private let crewDetails: [String: PendingBotCrewDetail]
    private let crewListLoading: Bool
    private let crewDetailLoadingIds: Set<String>
    private let crewDetailErrors: [String: String]
    private let onRefresh: () -> Void
    private let onSelectCrew: (String) -> Void
    private let onSendAnnouncement: (String, String) -> Void
    private let onCreateSession: (String, PendingBotCrewRunnerKind, String) -> Void
    private let onCreateChildCrew: (String, String) -> Void

    public init(
        crews: [PendingBotCrewSummary],
        selectedCrewId: Binding<String?>,
        crewDetails: [String: PendingBotCrewDetail],
        crewListLoading: Bool,
        crewDetailLoadingIds: Set<String>,
        crewDetailErrors: [String: String],
        onRefresh: @escaping () -> Void,
        onSelectCrew: @escaping (String) -> Void,
        onSendAnnouncement: @escaping (String, String) -> Void,
        onCreateSession: @escaping (String, PendingBotCrewRunnerKind, String) -> Void,
        onCreateChildCrew: @escaping (String, String) -> Void
    ) {
        self.crews = crews
        self._selectedCrewId = selectedCrewId
        self.crewDetails = crewDetails
        self.crewListLoading = crewListLoading
        self.crewDetailLoadingIds = crewDetailLoadingIds
        self.crewDetailErrors = crewDetailErrors
        self.onRefresh = onRefresh
        self.onSelectCrew = onSelectCrew
        self.onSendAnnouncement = onSendAnnouncement
        self.onCreateSession = onCreateSession
        self.onCreateChildCrew = onCreateChildCrew
    }

    public var body: some View {
        NavigationSplitView {
            PendingBotCrewList(
                crews: crews,
                isLoading: crewListLoading,
                selectedCrewId: $selectedCrewId,
                onRefresh: onRefresh
            )
        } detail: {
            if let selectedCrewId,
               let crew = crews.first(where: { $0.id == selectedCrewId }) {
                PendingBotCrewDetailView(
                    crew: crew,
                    detail: crewDetails[selectedCrewId],
                    isLoading: crewDetailLoadingIds.contains(selectedCrewId),
                    errorMessage: crewDetailErrors[selectedCrewId],
                    onRefresh: onRefresh,
                    onSendAnnouncement: { message in
                        onSendAnnouncement(selectedCrewId, message)
                    },
                    onCreateSession: { runnerKind, taskBrief in
                        onCreateSession(selectedCrewId, runnerKind, taskBrief)
                    },
                    onCreateChildCrew: { title in
                        onCreateChildCrew(selectedCrewId, title)
                    },
                    onOpenCrew: { crewId in
                        self.selectedCrewId = crewId
                    }
                )
            } else {
                ContentUnavailableView {
                    Label {
                        Text("选择一个机组")
                    } icon: {
                        AppSymbol.pendingCrew.image
                    }
                }
            }
        }
        .onAppear(perform: selectCrewIfNeeded)
        .onChange(of: crews.map(\.id)) { _, _ in
            selectCrewIfNeeded()
        }
        .onChange(of: selectedCrewId) { _, crewId in
            if let crewId {
                onSelectCrew(crewId)
            }
        }
    }

    private func selectCrewIfNeeded() {
        let crewIds = Set(crews.map(\.id))
        if let selectedCrewId, crewIds.contains(selectedCrewId) {
            return
        }
        selectedCrewId = crews.first?.id
    }
}

private struct PendingBotCrewList: View {
    let crews: [PendingBotCrewSummary]
    let isLoading: Bool
    @Binding var selectedCrewId: String?
    let onRefresh: () -> Void

    var body: some View {
        Group {
            #if os(macOS)
            List(selection: $selectedCrewId) {
                Section("机组") {
                    if crews.isEmpty {
                        ContentUnavailableView {
                            Label {
                                Text("还没有机组")
                            } icon: {
                                AppSymbol.pendingCrew.image
                            }
                        }
                            .frame(minHeight: 220)
                    } else {
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
            }
            #else
            List {
                Section("机组") {
                    if crews.isEmpty {
                        ContentUnavailableView {
                            Label {
                                Text("还没有机组")
                            } icon: {
                                AppSymbol.pendingCrew.image
                            }
                        }
                            .frame(minHeight: 220)
                    } else {
                        ForEach(PendingBotCrewSidebarRow.rows(for: crews)) { row in
                            Button {
                                selectedCrewId = row.id
                            } label: {
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
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            #endif
        }
        .navigationTitle("机组")
        .overlay {
            if isLoading && crews.isEmpty {
                ProgressView("正在加载机组")
            }
        }
        .toolbar {
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
        }
    }
}

private struct PendingBotCrewDetailView: View {
    @Environment(\.openURL) private var openURL

    let crew: PendingBotCrewSummary
    let detail: PendingBotCrewDetail?
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () -> Void
    let onSendAnnouncement: (String) -> Void
    let onCreateSession: (PendingBotCrewRunnerKind, String) -> Void
    let onCreateChildCrew: (String) -> Void
    let onOpenCrew: (String) -> Void

    @State private var announcementText = ""
    @State private var sessionTaskBrief = ""
    @State private var childCrewTitle = ""
    @State private var runnerKind: PendingBotCrewRunnerKind = .localCodex

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let errorMessage {
                    PendingBotCrewStatusPanel(
                        title: "机组详情加载失败",
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle"
                    )
                } else if isLoading && detail == nil {
                    ProgressView("正在加载机组详情")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let detail {
                    composer
                    childCrewComposer
                    relationshipSection(detail)
                    responsibilitySection(detail)
                    memberSection(detail)
                    sessionSection(detail)
                    announcementSection(detail)
                } else {
                    PendingBotCrewStatusPanel(
                        title: "选择机组后会显示详情",
                        message: "这里会显示成员、关系、责任分摊、Session 和机组公告。",
                        symbol: .pendingCrew
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle(crew.title)
        .toolbar {
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(crew.title)
                .font(.title2.weight(.semibold))
            Text("\(crew.runtimeKind.title) · \(crew.status)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("操作")
                .font(.headline)

            TextField("给机组发一条公告", text: $announcementText, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    let text = trimmed(announcementText)
                    guard !text.isEmpty else { return }
                    onSendAnnouncement(text)
                    announcementText = ""
                } label: {
                    Label("发送公告", systemImage: "paperplane")
                }
                .disabled(trimmed(announcementText).isEmpty)

                Spacer()
            }

            Divider()

            Picker("Runner", selection: $runnerKind) {
                ForEach(PendingBotCrewRunnerKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)

            TextField("创建 Session 的任务说明", text: $sessionTaskBrief, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)

            Button {
                let taskBrief = trimmed(sessionTaskBrief)
                guard !taskBrief.isEmpty else { return }
                onCreateSession(runnerKind, taskBrief)
                sessionTaskBrief = ""
            } label: {
                Label("创建 Session", systemImage: "play.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmed(sessionTaskBrief).isEmpty)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var childCrewComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("子机组")
                .font(.headline)

            TextField("新子机组名称", text: $childCrewTitle)
                .textFieldStyle(.roundedBorder)

            Button {
                let title = trimmed(childCrewTitle)
                guard !title.isEmpty else { return }
                onCreateChildCrew(title)
                childCrewTitle = ""
            } label: {
                Label("创建子机组", systemImage: "plus.square.on.square")
            }
            .disabled(trimmed(childCrewTitle).isEmpty)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func relationshipSection(_ detail: PendingBotCrewDetail) -> some View {
        PendingBotCrewSection(title: "关系", systemImage: "point.3.connected.trianglepath.dotted") {
            let rows = PendingBotCrewRelationshipRow.rows(for: detail)
            if rows.isEmpty {
                PendingBotCrewEmptyLine(text: "还没有上级或下级机组。")
            } else {
                ForEach(rows) { row in
                    Button {
                        onOpenCrew(row.crewId)
                    } label: {
                        PendingBotCrewInfoRow(systemImage: row.systemImage, title: row.title, subtitle: row.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func responsibilitySection(_ detail: PendingBotCrewDetail) -> some View {
        PendingBotCrewSection(title: "责任分摊", systemImage: "chart.pie") {
            if detail.responsibilityShares.isEmpty {
                PendingBotCrewEmptyLine(text: "还没有责任分摊数据。")
            } else {
                ForEach(detail.responsibilityShares) { share in
                    PendingBotCrewInfoRow(
                        systemImage: "person.crop.circle.badge.checkmark",
                        title: share.percentText,
                        subtitle: "\(share.subjectId) · \(share.source)"
                    )
                }
            }
        }
    }

    private func memberSection(_ detail: PendingBotCrewDetail) -> some View {
        PendingBotCrewSection(title: "成员", systemImage: "person.2") {
            if detail.members.isEmpty {
                PendingBotCrewEmptyLine(text: "还没有活跃成员。")
            } else {
                ForEach(detail.members) { member in
                    PendingBotCrewInfoRow(
                        systemImage: member.memberKind == "bot" ? "cpu" : "person",
                        title: member.displayName,
                        subtitle: "\(member.role) · \(member.status)"
                    )
                }
            }
        }
    }

    private func sessionSection(_ detail: PendingBotCrewDetail) -> some View {
        PendingBotCrewSection(title: "Session", systemImage: "terminal") {
            if detail.sessions.isEmpty {
                PendingBotCrewEmptyLine(text: "还没有 Session。")
            } else {
                ForEach(detail.displaySessions) { session in
                    HStack(alignment: .top, spacing: 8) {
                        PendingBotCrewInfoRow(
                            systemImage: "terminal",
                            title: session.taskBrief,
                            subtitle: "\(session.runnerKind.title) · \(session.status)\(session.progressSummary.map { " · \($0)" } ?? "")"
                        )

                        if let deepLink = session.pendingCrewDeepLink {
                            Button {
                                openURL(deepLink)
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.borderless)
                            .help("在 PendingCrew 打开")
                        }
                    }
                }
            }
        }
    }

    private func announcementSection(_ detail: PendingBotCrewDetail) -> some View {
        PendingBotCrewSection(title: "公告", systemImage: "bubble.left.and.bubble.right") {
            if detail.announcements.isEmpty {
                PendingBotCrewEmptyLine(text: "还没有可见公告。")
            } else {
                ForEach(detail.displayAnnouncements) { announcement in
                    PendingBotCrewInfoRow(
                        systemImage: "text.bubble",
                        title: announcement.summary,
                        subtitle: "\(announcement.senderKind) · \(announcement.messageKind) · \(announcement.createdAt)"
                    )
                }
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension PendingBotBigScreenTab {
    var symbol: AppSymbol {
        self == .crew ? .pendingCrew : .system(systemImage)
    }
}

private struct PendingBotCrewSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PendingBotCrewInfoRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PendingBotCrewEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

private struct PendingBotCrewStatusPanel: View {
    let title: String
    let message: String
    let symbol: AppSymbol

    init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.symbol = .system(systemImage)
    }

    init(title: String, message: String, symbol: AppSymbol) {
        self.title = title
        self.message = message
        self.symbol = symbol
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                symbol.image
            }
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
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
