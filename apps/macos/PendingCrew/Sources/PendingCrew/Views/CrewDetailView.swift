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
        .navigationTitle(crew?.title ?? "Crew")
        .task {
            await model.refreshCrew(crewId)
            selectInitialSessionIfNeeded()
        }
        .onChange(of: sessions.map(\.id)) { _, _ in
            selectInitialSessionIfNeeded()
        }
    }

    private var conversationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(crew?.title ?? "Crew")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    Text("\(members.count) members · \(sessions.count) sessions")
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

                if let selectedSessionId {
                    SessionEventsView(sessionId: selectedSessionId)
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
        InspectorSection(title: "创建任务") {
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
        InspectorSection(title: "Sessions") {
            if sessions.isEmpty {
                ContentUnavailableView("还没有 session", systemImage: "terminal")
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions) { session in
                        Button {
                            selectedSessionId = session.id
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

    private func selectInitialSessionIfNeeded() {
        guard selectedSessionId == nil || sessions.contains(where: { $0.id == selectedSessionId }) == false else {
            return
        }
        selectedSessionId = sessions.first?.id
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
                    if link.captainBotId != nil {
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

private struct SessionEventsView: View {
    @EnvironmentObject private var model: AppModel
    let sessionId: String

    private var events: [SessionEvent] {
        model.eventsBySession[sessionId] ?? []
    }

    private var mailbox: [SessionMailboxItem] {
        model.mailboxBySession[sessionId] ?? []
    }

    var body: some View {
        InspectorSection(title: "事件与收件箱") {
            if events.isEmpty && mailbox.isEmpty {
                ContentUnavailableView("还没有事件", systemImage: "list.bullet.rectangle")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(mailbox) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "tray.full")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("mailbox · \(item.messageKind)")
                                    .font(.headline)
                                Text(item.summary)
                                Text(item.createdAt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(events) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "smallcircle.filled.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.eventType)
                                    .font(.headline)
                                if let summary = event.summary {
                                    Text(summary)
                                }
                                Text(event.createdAt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
