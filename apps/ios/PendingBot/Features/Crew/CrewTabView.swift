import SwiftUI

struct CrewTabView: View {
    @Environment(\.api) private var api
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var subject: CrewSubject?
    @State private var crews: [CrewSummary] = []
    @State private var runnerHosts: [CrewRunnerHost] = []
    @State private var sessionsByCrew: [String: [CrewSessionSummary]] = [:]
    @State private var selectedCrewId: String?
    @State private var newCrewTitle = ""
    @State private var taskBrief = ""
    @State private var selectedRunnerKind: CrewRunnerKind = .cloudSandbox
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var scanningDeviceLogin = false

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
                            sessions: sessionsByCrew[crew.id] ?? [],
                            runnerHosts: runnerHosts,
                            selectedRunnerKind: $selectedRunnerKind,
                            taskBrief: $taskBrief,
                            onRefresh: { Task { await loadSessions(for: crew.id) } },
                            onCreateSession: { Task { await createSession(in: crew.id) } }
                        )
                    } else {
                        EmptyDetailHint(text: "选择一个 Crew", systemImage: "command")
                    }
                }
            } else {
                NavigationStack {
                    sidebarContent
                        .navigationDestination(for: String.self) { crewId in
                            if let crew = crews.first(where: { $0.id == crewId }) {
                                CrewDetailPane(
                                    crew: crew,
                                    sessions: sessionsByCrew[crew.id] ?? [],
                                    runnerHosts: runnerHosts,
                                    selectedRunnerKind: $selectedRunnerKind,
                                    taskBrief: $taskBrief,
                                    onRefresh: { Task { await loadSessions(for: crew.id) } },
                                    onCreateSession: { Task { await createSession(in: crew.id) } }
                                )
                                .task { await loadSessions(for: crew.id) }
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
                Task { await approveDeviceLogin(from: value) }
            } onError: { err in
                error = err.localizedDescription
            }
            .ignoresSafeArea()
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
            TabHeaderBar(title: "Crew") {
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
                        title: "Mac Crew",
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
                TextField("Crew 名称", text: $newCrewTitle)
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
                Text("Crew")
                    .font(Theme.Fonts.rounded(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                Spacer()
                if loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if crews.isEmpty && !loading {
                ContentUnavailableView("还没有 Crew", systemImage: "command")
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
                Task { await loadSessions(for: crew.id) }
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
                await loadSessions(for: selectedCrewId)
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
                title: title.isEmpty ? "Crew" : title
            )
            newCrewTitle = ""
            selectedCrewId = id
            crews = try await api.crewList()
            await loadSessions(for: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSessions(for crewId: String) async {
        guard let api else { return }
        do {
            sessionsByCrew[crewId] = try await api.crewSessions(crewId: crewId)
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
            sessionsByCrew[crewId] = try await api.crewSessions(crewId: crewId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approveDeviceLogin(from scannedValue: String) async {
        guard let api else { return }
        guard let subject else {
            error = "还没有加载账号主体"
            return
        }
        guard let payload = DeviceLoginLink.parse(scannedValue) else {
            error = "这不是 PendingCrew 登录二维码"
            return
        }
        do {
            let response = try await api.approvePendingCrewDeviceLogin(
                challengeId: payload.challengeId,
                secret: payload.secret,
                subjectId: subject.id
            )
            notice = response.ok ? "已确认 PendingCrew 登录" : "扫码登录状态：\(response.status)"
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
    let crew: CrewSummary
    let sessions: [CrewSessionSummary]
    let runnerHosts: [CrewRunnerHost]
    @Binding var selectedRunnerKind: CrewRunnerKind
    @Binding var taskBrief: String
    let onRefresh: () -> Void
    let onCreateSession: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                composer
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
            Text(crew.title)
                .font(Theme.Fonts.serif(size: 24, weight: .semibold))
            Text("云端可用 · \(onlineMacRunnerCount) 台 Mac 在线")
                .font(Theme.Fonts.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.inkMuted)
        }
    }

    private var composer: some View {
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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surface)
        )
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

    private var onlineMacRunnerCount: Int {
        runnerHosts.filter { $0.platform == "macos" && $0.status == "online" }.count
    }
}
