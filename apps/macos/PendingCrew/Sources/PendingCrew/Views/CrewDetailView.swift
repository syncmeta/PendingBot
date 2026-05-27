import Foundation
import SwiftUI

struct CrewDetailView: View {
    @EnvironmentObject private var model: AppModel
    let crewId: String

    @State private var runnerKind: RunnerKind = .localCodex
    @State private var taskBrief = ""
    @State private var selectedSessionId: String?
    @State private var announcementText = ""
    @State private var mentionedSessionIds: Set<String> = []
    @State private var mentionedMemberIds: Set<String> = []
    @State private var childCrewTitle = ""
    @State private var progressUpdateText = ""
    @State private var finalSummaryText = ""

    private var crew: Crew? {
        model.crews.first { $0.id == crewId }
    }

    private var sessions: [CrewSession] {
        model.sessionsByCrew[crewId] ?? []
    }

    private var members: [CrewMember] {
        model.membersByCrew[crewId] ?? []
    }

    private var announcements: [CrewAnnouncement] {
        model.announcementsByCrew[crewId] ?? []
    }

    private var links: CrewLinksResponse? {
        model.linksByCrew[crewId]
    }

    private var parents: [CrewLink] {
        links?.parents ?? []
    }

    private var children: [CrewLink] {
        links?.children ?? []
    }

    private var responsibilityShares: [CrewResponsibilityShare] {
        links?.responsibilityShares ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationPane

            Divider()

            inspectorPane
        }
        .frame(minWidth: 940, minHeight: 640)
        .navigationTitle(crew?.title ?? "机组")
        .task {
            await model.refreshCrew(crewId)
            selectInitialSessionIfNeeded()
        }
        .onChange(of: sessions.map(\.id)) { _, _ in
            selectInitialSessionIfNeeded()
        }
        .onChange(of: model.focusedSessionIdsByCrew[crewId]) { _, _ in
            selectInitialSessionIfNeeded()
        }
    }

    private var conversationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(crew?.title ?? "机组")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    Text("\(members.count) 位成员 · \(sessions.count) 个 session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await model.refreshCrew(crewId) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }

            CrewChatView(
                announcements: announcements,
                sessions: sessions,
                members: members,
                draftText: $announcementText,
                mentionedSessionIds: $mentionedSessionIds,
                mentionedMemberIds: $mentionedMemberIds,
                onSend: {
                    Task {
                        await model.createAnnouncement(
                            crewId: crewId,
                            summary: announcementText,
                            recipientSessionIds: mentionedSessionIds,
                            recipientMemberIds: mentionedMemberIds
                        )
                        announcementText = ""
                        mentionedSessionIds = []
                        mentionedMemberIds = []
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                relationshipsBox
                createSessionBox
                sessionsBox

                if let selectedSession {
                    SelectedSessionWindow(
                        session: selectedSession,
                        events: model.eventsBySession[selectedSession.id] ?? [],
                        mailbox: model.mailboxBySession[selectedSession.id] ?? [],
                        activeRunnerSessionId: model.activeRunnerSession?.id,
                        progressUpdateText: $progressUpdateText,
                        finalSummaryText: $finalSummaryText,
                        onRefresh: {
                            Task { await model.refreshEvents(sessionId: selectedSession.id) }
                        },
                        onReportProgress: {
                            Task {
                                await model.appendRunnerStatus(summary: progressUpdateText)
                                progressUpdateText = ""
                            }
                        },
                        onComplete: {
                            let summary = finalSummaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.finishActiveRunnerSession(status: "completed", summary: summary)
                                finalSummaryText = ""
                            }
                        },
                        onFail: {
                            let summary = finalSummaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.finishActiveRunnerSession(status: "failed", summary: summary)
                                finalSummaryText = ""
                            }
                        }
                    )
                } else {
                    InspectorSection(title: "Session 窗口") {
                        ContentUnavailableView("选择一个 session", systemImage: "macwindow")
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 380)
        .background(.background)
    }

    private var header: some View {
        InspectorSection(title: "概览") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    Text(crewId).font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("状态").foregroundStyle(.secondary)
                    Text(crew?.status ?? "-")
                }
                GridRow {
                    Text("成员").foregroundStyle(.secondary)
                    Text("\(members.count)")
                }
                GridRow {
                    Text("责任主体").foregroundStyle(.secondary)
                    Text("\(responsibilityShares.count)")
                }
            }
        }
    }

    private var relationshipsBox: some View {
        InspectorSection(title: "机组关系") {
            VStack(alignment: .leading, spacing: 12) {
                relationshipGroup(title: "父机组", links: parents, emptyText: "没有父机组")
                relationshipGroup(title: "子机组", links: children, emptyText: "还没有子机组")

                VStack(alignment: .leading, spacing: 8) {
                    Text("新建子机组")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("子机组名称", text: $childCrewTitle)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            let title = childCrewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.createChildCrew(parentCrewId: crewId, title: title)
                                childCrewTitle = ""
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(childCrewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if !responsibilityShares.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 7) {
                        Text("责任分摊")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(responsibilityShares) { share in
                            HStack(spacing: 8) {
                                Text(share.subjectId)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)

                                Spacer(minLength: 0)

                                Text(formatShare(share.shareBps))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var createSessionBox: some View {
        InspectorSection(title: "排队任务") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Runner", selection: $runnerKind) {
                    ForEach(RunnerKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $taskBrief)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }

                Button {
                    Task {
                        await model.createSession(crewId: crewId, runnerKind: runnerKind, taskBrief: taskBrief)
                        taskBrief = ""
                    }
                } label: {
                    Label("排队", systemImage: "play.circle")
                }
                .disabled(taskBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var sessionsBox: some View {
        InspectorSection(title: "Session 队列") {
            if sessions.isEmpty {
                ContentUnavailableView("还没有 session", systemImage: "terminal")
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions) { session in
                        Button {
                            selectedSessionId = session.id
                            model.focusedSessionIdsByCrew[crewId] = nil
                            progressUpdateText = ""
                            finalSummaryText = ""
                            Task { await model.refreshEvents(sessionId: session.id) }
                        } label: {
                            SessionSummaryRow(
                                session: session,
                                isSelected: selectedSessionId == session.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var selectedSession: CrewSession? {
        guard let selectedSessionId else { return nil }
        return sessions.first { $0.id == selectedSessionId }
    }

    private func selectInitialSessionIfNeeded() {
        if let focusedSessionId = model.focusedSessionIdsByCrew[crewId],
           sessions.contains(where: { $0.id == focusedSessionId }) {
            selectedSessionId = focusedSessionId
            progressUpdateText = ""
            finalSummaryText = ""
            Task { await model.refreshEvents(sessionId: focusedSessionId) }
            return
        }
        guard selectedSessionId == nil || sessions.contains(where: { $0.id == selectedSessionId }) == false else {
            return
        }
        selectedSessionId = sessions.first?.id
        progressUpdateText = ""
        finalSummaryText = ""
        if let selectedSessionId {
            Task { await model.refreshEvents(sessionId: selectedSessionId) }
        }
    }

    private func formatShare(_ shareBps: Int) -> String {
        let percent = Double(shareBps) / 100
        if percent.rounded() == percent {
            return "\(Int(percent))%"
        }
        return String(format: "%.2f%%", percent)
    }

    @ViewBuilder
    private func relationshipGroup(title: String, links: [CrewLink], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if links.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(links) { link in
                    Button {
                        model.selection = .crew(link.crewConversationId)
                    } label: {
                        CrewRelationshipRow(link: link)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SessionSummaryRow: View {
    let session: CrewSession
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.runnerKind)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    StatusBadge(text: session.status)
                }

                Text(session.taskBrief)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let progress = session.progressSummary, !progress.isEmpty {
                    Text(progress)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct CrewRelationshipRow: View {
    let link: CrewLink

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(link.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    StatusBadge(text: link.status)
                }

                HStack(spacing: 6) {
                    Text(link.runtimeKind)
                    if link.hasCaptainRepresentative {
                        Text("机长")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct StatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

enum SessionOperatorMode: Equatable {
    case activeLocalRunner
    case queuedClaimable
    case observable
}

struct SessionOperatorState: Equatable {
    let mode: SessionOperatorMode

    init(session: CrewSession, activeRunnerSessionId: String?) {
        if activeRunnerSessionId == session.id {
            mode = .activeLocalRunner
        } else if session.status == "queued" {
            mode = .queuedClaimable
        } else {
            mode = .observable
        }
    }

    var badgeText: String {
        switch mode {
        case .activeLocalRunner:
            "本机执行中"
        case .queuedClaimable:
            "可认领 / 队列中"
        case .observable:
            "只读观察"
        }
    }

    var systemImage: String {
        switch mode {
        case .activeLocalRunner:
            "desktopcomputer"
        case .queuedClaimable:
            "tray.and.arrow.down"
        case .observable:
            "eye"
        }
    }

    var detailText: String {
        switch mode {
        case .activeLocalRunner:
            "这是当前本机 runner 认领的 session，可以直接上报进度或结束。"
        case .queuedClaimable:
            "这个 session 正在队列中等待 runner 认领；去 Runner 页认领后会切换成本机控制。"
        case .observable:
            "这个 session 不属于当前本机 runner，只能查看事件和收件箱。"
        }
    }

    var canReportProgress: Bool {
        mode == .activeLocalRunner
    }

    var canFinish: Bool {
        mode == .activeLocalRunner
    }
}

struct SessionInspectorModel {
    let session: CrewSession
    let operatorState: SessionOperatorState
    let sortedEvents: [SessionEvent]
    let sortedMailbox: [SessionMailboxItem]

    init(
        session: CrewSession,
        events: [SessionEvent],
        mailbox: [SessionMailboxItem],
        activeRunnerSessionId: String? = nil
    ) {
        self.session = session
        self.operatorState = SessionOperatorState(session: session, activeRunnerSessionId: activeRunnerSessionId)
        self.sortedEvents = events.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt > $1.createdAt
        }
        self.sortedMailbox = mailbox.sorted {
            let lhsActive = Self.isActiveMailboxItem($0)
            let rhsActive = Self.isActiveMailboxItem($1)
            if lhsActive != rhsActive {
                return lhsActive
            }
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt > $1.createdAt
        }
    }

    var shortSessionId: String {
        String(session.id.prefix(9))
    }

    var progressText: String {
        guard let progress = session.progressSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !progress.isEmpty
        else {
            return "暂无进度"
        }
        return progress
    }

    var activeMailboxCount: Int {
        sortedMailbox.filter(Self.isActiveMailboxItem).count
    }

    private static func isActiveMailboxItem(_ item: SessionMailboxItem) -> Bool {
        item.status != "archived"
    }
}

private struct SelectedSessionWindow: View {
    let model: SessionInspectorModel
    @Binding var progressUpdateText: String
    @Binding var finalSummaryText: String
    let onRefresh: () -> Void
    let onReportProgress: () -> Void
    let onComplete: () -> Void
    let onFail: () -> Void

    init(
        session: CrewSession,
        events: [SessionEvent],
        mailbox: [SessionMailboxItem],
        activeRunnerSessionId: String?,
        progressUpdateText: Binding<String>,
        finalSummaryText: Binding<String>,
        onRefresh: @escaping () -> Void,
        onReportProgress: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onFail: @escaping () -> Void
    ) {
        self.model = SessionInspectorModel(
            session: session,
            events: events,
            mailbox: mailbox,
            activeRunnerSessionId: activeRunnerSessionId
        )
        self._progressUpdateText = progressUpdateText
        self._finalSummaryText = finalSummaryText
        self.onRefresh = onRefresh
        self.onReportProgress = onReportProgress
        self.onComplete = onComplete
        self.onFail = onFail
    }

    private var canSubmitProgress: Bool {
        model.operatorState.canReportProgress && !progressUpdateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canFinishSession: Bool {
        model.operatorState.canFinish && !finalSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            windowHeader
            operatorStateBanner
            taskBrief
            statusProgress
            progressControls
            finishControls
            mailboxSection
            eventsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
    }

    private var windowHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Session 窗口", systemImage: "macwindow")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onRefresh) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新 session 事件和收件箱")
            }

            HStack(spacing: 8) {
                Text(model.session.runnerKind)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                StatusBadge(text: model.session.status)
                Spacer(minLength: 8)
                Text(model.shortSessionId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var operatorStateBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: model.operatorState.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.operatorState.badgeText)
                    .font(.subheadline.weight(.semibold))
                Text(model.operatorState.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var taskBrief: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Task brief")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.session.taskBrief)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var statusProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(model.progressText, systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("created").foregroundStyle(.secondary)
                    Text(model.session.createdAt).lineLimit(1)
                }
                if let startedAt = model.session.startedAt {
                    GridRow {
                        Text("started").foregroundStyle(.secondary)
                        Text(startedAt).lineLimit(1)
                    }
                }
                if let finishedAt = model.session.finishedAt {
                    GridRow {
                        Text("finished").foregroundStyle(.secondary)
                        Text(finishedAt).lineLimit(1)
                    }
                }
            }
            .font(.caption)
        }
    }

    private var progressControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("上报进度", text: $progressUpdateText)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.operatorState.canReportProgress)

            HStack {
                Button {
                    onReportProgress()
                } label: {
                    Label("上报进度", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!canSubmitProgress)

                if !model.operatorState.canReportProgress {
                    Text("只有本机已认领的 session 可直接上报")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var finishControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("结束摘要", text: $finalSummaryText)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.operatorState.canFinish)

            HStack(spacing: 8) {
                Button {
                    onComplete()
                } label: {
                    Label("完成", systemImage: "checkmark.circle")
                }
                .disabled(!canFinishSession)

                Button(role: .destructive) {
                    onFail()
                } label: {
                    Label("失败", systemImage: "xmark.circle")
                }
                .disabled(!canFinishSession)
            }

            if model.operatorState.canFinish {
                Text("填写结束摘要后可以完成或失败当前本机 session。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var mailboxSection: some View {
        SessionWindowSection(
            title: "Mailbox",
            badge: model.activeMailboxCount == 0 ? nil : "\(model.activeMailboxCount)"
        ) {
            if model.sortedMailbox.isEmpty {
                EmptyTimelineText(text: "没有收件箱消息")
            } else {
                ForEach(model.sortedMailbox) { item in
                    TimelineRow(
                        systemImage: item.status == "archived" ? "tray" : "tray.full",
                        title: "\(item.messageKind) · \(item.status)",
                        summary: item.summary,
                        timestamp: item.createdAt
                    )
                }
            }
        }
    }

    private var eventsSection: some View {
        SessionWindowSection(title: "Events", badge: "\(model.sortedEvents.count)") {
            if model.sortedEvents.isEmpty {
                EmptyTimelineText(text: "还没有事件")
            } else {
                ForEach(model.sortedEvents) { event in
                    TimelineRow(
                        systemImage: "smallcircle.filled.circle",
                        title: event.eventType,
                        summary: event.summary,
                        timestamp: event.createdAt
                    )
                }
            }
        }
    }
}

private struct SessionWindowSection<Content: View>: View {
    let title: String
    let badge: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TimelineRow: View {
    let systemImage: String
    let title: String
    let summary: String?
    let timestamp: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyTimelineText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}
