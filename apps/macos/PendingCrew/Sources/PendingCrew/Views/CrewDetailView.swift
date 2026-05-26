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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                createSessionBox
                announcementsBox
                sessionsBox
                if let selectedSessionId {
                    SessionEventsView(sessionId: selectedSessionId)
                }
            }
            .padding()
        }
        .navigationTitle(crew?.title ?? "Crew")
        .task {
            await model.refreshCrew(crewId)
        }
    }

    private var header: some View {
        GroupBox("概览") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    Text(crewId).font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("状态").foregroundStyle(.secondary)
                    Text(crew?.status ?? "-")
                }
            }
        }
    }

    private var createSessionBox: some View {
        GroupBox("创建 Session") {
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
        GroupBox("Sessions") {
            if sessions.isEmpty {
                ContentUnavailableView("还没有 session", systemImage: "terminal")
            } else {
                Table(sessions, selection: $selectedSessionId) {
                    TableColumn("状态") { session in
                        Text(session.status)
                    }
                    TableColumn("Runner") { session in
                        Text(session.runnerKind)
                    }
                    TableColumn("任务") { session in
                        Text(session.taskBrief)
                            .lineLimit(2)
                    }
                    TableColumn("创建时间") { session in
                        Text(session.createdAt)
                    }
                }
                .frame(minHeight: 220)
                .onChange(of: selectedSessionId) { _, newValue in
                    if let newValue {
                        Task { await model.refreshEvents(sessionId: newValue) }
                    }
                }
            }
        }
    }

    private var announcementsBox: some View {
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
        GroupBox("事件与收件箱") {
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
