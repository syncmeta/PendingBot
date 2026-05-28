import SwiftUI

struct CrewTabView: View {
    @Environment(\.api) private var api
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var subject: CrewSubject?
    @State private var crews: [CrewSummary] = []
    @State private var runnerHosts: [CrewRunnerHost] = []
    @State private var sessionsByCrew: [String: [CrewSessionSummary]] = [:]
    @State private var linksByCrew: [String: CrewLinksResponse] = [:]
    @State private var membersByCrew: [String: [CrewMemberSummary]] = [:]
    @State private var announcementsByCrew: [String: [CrewAnnouncementSummary]] = [:]
    @State private var loadingDetailCrewIds: Set<String> = []
    @State private var selectedCrewId: String?
    @State private var newCrewTitle = ""
    @State private var childCrewTitle = ""
    @State private var taskBrief = ""
    @State private var announcementSummary = ""
    @State private var selectedRunnerKind: CrewRunnerKind = .cloudSandbox
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var scanningDeviceLogin = false
    // T1.3 P2: after scanning a PendingCrew/PendingBot device-login QR,
    // hold the parsed payload here so the SubjectPickerSheet can prompt
    // the user to choose which subject to authorize as. Set to nil on
    // cancel / completion.
    @State private var pendingDeviceLogin: DeviceLoginLink.Payload?

    var body: some View {
        Group {
            if sidebarLayout {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        sidebarContent
                        if let topTabSelection {
                            SidebarTabBar(selection: topTabSelection)
                        }
                    }
                    .sidebarColumnWidth()
                } detail: {
                    if let crew = selectedCrew {
                        CrewDetailPane(
                            crew: crew,
                            links: linksByCrew[crew.id],
                            members: membersByCrew[crew.id] ?? [],
                            sessions: sessionsByCrew[crew.id] ?? [],
                            announcements: announcementsByCrew[crew.id] ?? [],
                            runnerHosts: runnerHosts,
                            loadingDetail: loadingDetailCrewIds.contains(crew.id),
                            selectedRunnerKind: $selectedRunnerKind,
                            taskBrief: $taskBrief,
                            childCrewTitle: $childCrewTitle,
                            announcementSummary: $announcementSummary,
                            onRefresh: { Task { await loadDetail(for: crew.id) } },
                            onCreateSession: { Task { await createSession(in: crew.id) } },
                            onCreateChildCrew: { Task { await createChildCrew(parentCrewId: crew.id) } },
                            onSendAnnouncement: { Task { await sendAnnouncement(in: crew.id) } }
                        )
                    } else {
                        EmptyDetailHint(text: "选择一个机组", systemImage: "command")
                    }
                }
            } else {
                NavigationStack {
                    sidebarContent
                        .navigationDestination(for: String.self) { crewId in
                            if let crew = crews.first(where: { $0.id == crewId }) {
                                CrewDetailPane(
                                    crew: crew,
                                    links: linksByCrew[crew.id],
                                    members: membersByCrew[crew.id] ?? [],
                                    sessions: sessionsByCrew[crew.id] ?? [],
                                    announcements: announcementsByCrew[crew.id] ?? [],
                                    runnerHosts: runnerHosts,
                                    loadingDetail: loadingDetailCrewIds.contains(crew.id),
                                    selectedRunnerKind: $selectedRunnerKind,
                                    taskBrief: $taskBrief,
                                    childCrewTitle: $childCrewTitle,
                                    announcementSummary: $announcementSummary,
                                    onRefresh: { Task { await loadDetail(for: crew.id) } },
                                    onCreateSession: { Task { await createSession(in: crew.id) } },
                                    onCreateChildCrew: { Task { await createChildCrew(parentCrewId: crew.id) } },
                                    onSendAnnouncement: { Task { await sendAnnouncement(in: crew.id) } }
                                )
                                .task { await loadDetail(for: crew.id) }
                                .toolbar(.hidden, for: .tabBar)
                            }
                        }
                }
            }
        }
        .task { await loadAll() }
        .sheet(isPresented: $scanningDeviceLogin) {
            QRScannerView { value in
                scanningDeviceLogin = false
                if let payload = DeviceLoginLink.parse(value) {
                    pendingDeviceLogin = payload
                } else {
                    error = "这不是 PendingCrew 登录二维码"
                }
            } onError: { err in
                error = err.localizedDescription
            }
            .ignoresSafeArea()
        }
        .sheet(item: $pendingDeviceLogin) { payload in
            SubjectPickerSheet(
                payload: payload,
                defaultSubject: subject,
                onApprove: { selected in
                    pendingDeviceLogin = nil
                    Task { await approveDeviceLogin(payload: payload, subjectId: selected.id, label: selected.label) }
                },
                onCancel: { pendingDeviceLogin = nil }
            )
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert("完成", isPresented: .constant(notice != nil)) {
            Button("好") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var selectedCrew: CrewSummary? {
        guard let selectedCrewId else { return crews.first }
        return crews.first { $0.id == selectedCrewId }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            TabHeaderBar(title: "机组") {
                Button {
                    scanningDeviceLogin = true
                } label: {
                    HeaderActionIcon(systemImage: "qrcode.viewfinder")
                }
                Button {
                    Task { await loadAll() }
                } label: {
                    HeaderActionIcon(systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    subjectSection
                    runnerSection
                    createCrewSection
                    crewListSection
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.vertical, 12)
                .readableColumnWidth(sidebarLayout ? .infinity : Theme.Metrics.readableColumn)
            }
            .refreshable { await loadAll() }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var subjectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("主体")
                .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            HStack {
                Image(systemName: "person.crop.square")
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject?.display_name ?? "未加载")
                        .font(Theme.Fonts.system(size: 15, weight: .semibold))
                    if let subject {
                        Text(subject.subject_type)
                            .font(Theme.Fonts.system(size: 12))
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
        }
    }

    private var runnerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Runner")
                    .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                Spacer()
                Text("\(onlineMacRunnerCount) 台 Mac 在线")
                    .font(Theme.Fonts.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            VStack(spacing: 0) {
                RunnerCapabilityRow(
                    title: "云端资源",
                    subtitle: "可直接创建 cloud_sandbox session",
                    systemImage: "cloud",
                    isOnline: true
                )
                Divider()
                if runnerHosts.isEmpty {
                    RunnerCapabilityRow(
                        title: "Mac 机组",
                        subtitle: "还没有已登录的 Mac runner",
                        systemImage: "desktopcomputer",
                        isOnline: false
                    )
                } else {
                    ForEach(runnerHosts) { host in
                        RunnerCapabilityRow(
                            title: host.display_name,
                            subtitle: "\(host.platform) · \(host.status)",
                            systemImage: "desktopcomputer",
                            isOnline: host.status == "online"
                        )
                        if host.id != runnerHosts.last?.id { Divider() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
        }
    }

    private var createCrewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新建")
                .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            HStack(spacing: 10) {
                TextField("机组名称", text: $newCrewTitle)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await createCrew() }
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.Fonts.glyph(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(subject == nil)
            }
        }
    }

    private var crewListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("机组")
                    .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                Spacer()
                if loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if crews.isEmpty && !loading {
                ContentUnavailableView("还没有机组", systemImage: "command")
                    .frame(minHeight: 140)
            } else {
                VStack(spacing: 8) {
                    ForEach(crews) { crew in
                        crewRow(crew)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func crewRow(_ crew: CrewSummary) -> some View {
        if sidebarLayout {
            Button {
                selectedCrewId = crew.id
                Task { await loadDetail(for: crew.id) }
            } label: {
                CrewRowContent(crew: crew, isSelected: selectedCrew?.id == crew.id)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: crew.id) {
                CrewRowContent(crew: crew, isSelected: false)
            }
        }
    }

    private var onlineMacRunnerCount: Int {
        runnerHosts.filter { $0.platform == "macos" && $0.status == "online" }.count
    }

    private func loadAll() async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let subject = api.crewCurrentSubject()
            async let crews = api.crewList()
            async let hosts = api.crewRunnerHosts()
            self.subject = try await subject
            self.crews = try await crews
            self.runnerHosts = try await hosts
            if selectedCrewId == nil {
                selectedCrewId = self.crews.first?.id
            }
            if let selectedCrewId {
                await loadDetail(for: selectedCrewId)
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createCrew() async {
        guard let api, let subject else { return }
        let title = newCrewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id = try await api.crewCreate(
                responsibleSubjectId: subject.id,
                title: title.isEmpty ? "机组" : title
            )
            newCrewTitle = ""
            selectedCrewId = id
            crews = try await api.crewList()
            await loadDetail(for: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDetail(for crewId: String) async {
        guard let api else { return }
        loadingDetailCrewIds.insert(crewId)
        defer { loadingDetailCrewIds.remove(crewId) }
        do {
            async let links = api.crewLinks(crewId: crewId)
            async let members = api.crewMembers(crewId: crewId)
            async let sessions = api.crewSessions(crewId: crewId)
            async let announcements = api.crewAnnouncements(crewId: crewId)
            linksByCrew[crewId] = try await links
            membersByCrew[crewId] = try await members
            sessionsByCrew[crewId] = try await sessions
            announcementsByCrew[crewId] = try await announcements
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createSession(in crewId: String) async {
        guard let api else { return }
        let brief = taskBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }
        do {
            _ = try await api.crewCreateSession(
                crewId: crewId,
                runnerKind: selectedRunnerKind,
                taskBrief: brief
            )
            taskBrief = ""
            await loadDetail(for: crewId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createChildCrew(parentCrewId: String) async {
        guard let api else { return }
        let title = childCrewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try await api.crewCreateChild(crewId: parentCrewId, title: title)
            childCrewTitle = ""
            async let updatedCrews = api.crewList()
            async let updatedLinks = api.crewLinks(crewId: parentCrewId)
            crews = try await updatedCrews
            linksByCrew[parentCrewId] = try await updatedLinks
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendAnnouncement(in crewId: String) async {
        guard let api else { return }
        let summary = announcementSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        do {
            _ = try await api.crewCreateAnnouncement(crewId: crewId, summary: summary)
            announcementSummary = ""
            announcementsByCrew[crewId] = try await api.crewAnnouncements(crewId: crewId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approveDeviceLogin(
        payload: DeviceLoginLink.Payload,
        subjectId: String,
        label: String
    ) async {
        guard let api else { return }
        let initialApproval: DeviceLoginGrantApproval = payload.appKind == .pendingBotMacOS
            ? .pendingBotClient
            : .pendingCrewControl
        do {
            let response: DeviceLoginApprovalResponse
            do {
                response = try await api.approvePendingCrewDeviceLogin(
                    challengeId: payload.challengeId,
                    secret: payload.secret,
                    subjectId: subjectId,
                    approval: initialApproval
                )
            } catch {
                guard let retry = DeviceLoginGrantApproval.retryPlan(after: error) else { throw error }
                guard retry != initialApproval else { throw error }
                response = try await api.approvePendingCrewDeviceLogin(
                    challengeId: payload.challengeId,
                    secret: payload.secret,
                    subjectId: subjectId,
                    approval: retry
                )
            }
            notice = response.ok
                ? "已以 \(label) 身份授权桌面端登录"
                : "扫码登录状态：\(response.status)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RunnerCapabilityRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(Theme.Fonts.glyph(size: 18, weight: .regular))
                .foregroundStyle(isOnline ? Theme.Palette.accent : Theme.Palette.inkMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(Theme.Fonts.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }
}

private struct CrewRowContent: View {
    let crew: CrewSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.inkMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(crew.title)
                    .font(Theme.Fonts.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(crew.status)
                    .font(Theme.Fonts.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Theme.Fonts.glyph(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.Palette.accent.opacity(0.12) : Theme.Palette.surface)
        )
    }
}

private struct CrewDetailPane: View {
    @Environment(\.openURL) private var openURL

    let crew: CrewSummary
    let links: CrewLinksResponse?
    let members: [CrewMemberSummary]
    let sessions: [CrewSessionSummary]
    let announcements: [CrewAnnouncementSummary]
    let runnerHosts: [CrewRunnerHost]
    let loadingDetail: Bool
    @Binding var selectedRunnerKind: CrewRunnerKind
    @Binding var taskBrief: String
    @Binding var childCrewTitle: String
    @Binding var announcementSummary: String
    let onRefresh: () -> Void
    let onCreateSession: () -> Void
    let onCreateChildCrew: () -> Void
    let onSendAnnouncement: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                relationshipsSection
                childCrewComposer
                sessionComposer
                announcementsSection
                membersSection
                sessionsSection
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, 18)
            .readableColumnWidth()
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(crew.title)
        .toolbar {
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(crew.title)
                        .font(Theme.Fonts.serif(size: 24, weight: .semibold))
                    Text("云端可用 · \(onlineMacRunnerCount) 台 Mac 在线 · \(crew.status)")
                        .font(Theme.Fonts.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                Spacer()
                if loadingDetail {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var relationshipsSection: some View {
        CrewSectionCard(title: "关系与责任") {
            VStack(alignment: .leading, spacing: 12) {
                linkGroup(title: "上级机组", links: links?.parents ?? [], emptyText: "没有上级机组")
                Divider()
                linkGroup(title: "子机组", links: links?.children ?? [], emptyText: "还没有子机组")
                Divider()
                responsibilityShares
            }
        }
    }

    private var childCrewComposer: some View {
        CrewSectionCard(title: "新建子机组") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("子机组名称", text: $childCrewTitle)
                    .textFieldStyle(.roundedBorder)
                Button {
                    onCreateChildCrew()
                } label: {
                    Label("创建子机组", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.bordered)
                .disabled(childCrewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var sessionComposer: some View {
        CrewSectionCard(title: "创建 Session") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Runner", selection: $selectedRunnerKind) {
                    ForEach(CrewRunnerKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                TextField("任务", text: $taskBrief, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)

                Button {
                    onCreateSession()
                } label: {
                    Label("创建 Session", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(taskBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var announcementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CrewSectionCard(title: "公告") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("发送范围：全部成员与所有 session")
                        .font(Theme.Fonts.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)

                    TextField("同步一条公告", text: $announcementSummary, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)

                    Button {
                        onSendAnnouncement()
                    } label: {
                        Label("发送公告", systemImage: "paperplane")
                    }
                    .buttonStyle(.bordered)
                    .disabled(announcementSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if announcements.isEmpty {
                ContentUnavailableView("还没有公告", systemImage: "megaphone")
                    .frame(minHeight: 120)
            } else {
                VStack(spacing: 10) {
                    ForEach(announcements.reversed()) { announcement in
                        AnnouncementRow(announcement: announcement)
                    }
                }
            }
        }
    }

    private var membersSection: some View {
        CrewSectionCard(title: "成员") {
            if members.isEmpty {
                Text("还没有成员")
                    .font(Theme.Fonts.system(size: 13))
                    .foregroundStyle(Theme.Palette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(members) { member in
                        CrewMemberRow(member: member)
                        if member.id != members.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session")
                .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)

            if sessions.isEmpty {
                ContentUnavailableView("还没有 session", systemImage: "terminal")
                    .frame(minHeight: 160)
            } else {
                VStack(spacing: 10) {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(session.runner_kind)
                                    .font(Theme.Fonts.system(size: 13, weight: .semibold))
                                Spacer()
                                if let deepLink = pendingCrewDeepLink(for: session) {
                                    Button {
                                        openURL(deepLink)
                                    } label: {
                                        Image(systemName: "arrow.up.forward.app")
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("在 PendingCrew 打开")
                                }
                                Text(session.status)
                                    .font(Theme.Fonts.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                            Text(session.task_brief)
                                .font(Theme.Fonts.system(size: 14))
                                .lineLimit(3)
                            if let progress = session.progress_summary {
                                Text(progress)
                                    .font(Theme.Fonts.system(size: 12))
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.Palette.surface)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkGroup(title: String, links: [CrewLinkSummary], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.Fonts.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            if links.isEmpty {
                Text(emptyText)
                    .font(Theme.Fonts.system(size: 13))
                    .foregroundStyle(Theme.Palette.inkMuted)
            } else {
                ForEach(links) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "command")
                            .foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title)
                                .font(Theme.Fonts.system(size: 14, weight: .semibold))
                            Text("\(link.runtime_kind) · \(link.status)")
                                .font(Theme.Fonts.system(size: 12))
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var responsibilityShares: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("责任份额")
                .font(Theme.Fonts.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            let shares = links?.responsibilityShares ?? []
            if shares.isEmpty {
                Text("还没有责任份额")
                    .font(Theme.Fonts.system(size: 13))
                    .foregroundStyle(Theme.Palette.inkMuted)
            } else {
                ForEach(shares) { share in
                    HStack {
                        Text(share.subject_id)
                            .font(Theme.Fonts.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(share.share_bps / 100)% · \(share.source)")
                            .font(Theme.Fonts.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
            }
        }
    }

    private var onlineMacRunnerCount: Int {
        runnerHosts.filter { $0.platform == "macos" && $0.status == "online" }.count
    }

    private func pendingCrewDeepLink(for session: CrewSessionSummary) -> URL? {
        URL(string: "pendingcrew://crew/\(crew.id)/session/\(session.id)")
    }
}

private struct CrewSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surface)
        )
    }
}

private struct CrewMemberRow: View {
    let member: CrewMemberSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: memberIcon)
                .font(Theme.Fonts.glyph(size: 16, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.display_name)
                    .font(Theme.Fonts.system(size: 14, weight: .semibold))
                Text([member.member_kind, member.role, member.status].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Fonts.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var memberIcon: String {
        switch member.member_kind {
        case "bot": "sparkles"
        case "code_session": "terminal"
        case "crew_captain": "command"
        default: "person.crop.circle"
        }
    }
}

private struct AnnouncementRow: View {
    let announcement: CrewAnnouncementSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(announcement.message_kind, systemImage: "megaphone")
                    .font(Theme.Fonts.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                Spacer()
                Text(announcement.recipient_mode)
                    .font(Theme.Fonts.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Text(announcement.summary)
                .font(Theme.Fonts.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            if !announcement.mentions.isEmpty {
                Text("\(announcement.mentions.count) 个指定目标")
                    .font(Theme.Fonts.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surface)
        )
    }
}
