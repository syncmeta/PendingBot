import SwiftUI

struct CrewDetailView: View {
    @EnvironmentObject private var model: AppModel
    let crewId: String

    @State private var runnerKind: RunnerKind = .localCodex
    @State private var taskBrief = ""
    @State private var selectedSessionId: String?
    @State private var announcementText = ""
    @State private var mentionedSessionIds: Set<String> = []

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
        GroupBox("公告板") {
            VStack(alignment: .leading, spacing: 12) {
                if announcements.isEmpty {
                    ContentUnavailableView("还没有公告", systemImage: "bubble.left.and.bubble.right")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(announcements) { announcement in
                            AnnouncementRow(
                                announcement: announcement,
                                sessions: sessions,
                                members: members,
                                onReplyToSession: { sessionId in
                                    mentionedSessionIds = [sessionId]
                                    announcementText = ""
                                }
                            )
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("发送公告")
                        .font(.headline)
                    MentionSessionPicker(sessions: sessions, selectedSessionIds: $mentionedSessionIds)
                    TextEditor(text: $announcementText)
                        .font(.body)
                        .frame(minHeight: 70)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary)
                        }
                    HStack {
                        Text(mentionedSessionIds.isEmpty ? "未 @ session：全员广播" : "已 @ \(mentionedSessionIds.count) 个 session")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task {
                                await model.createAnnouncement(
                                    crewId: crewId,
                                    summary: announcementText,
                                    recipientSessionIds: mentionedSessionIds
                                )
                                announcementText = ""
                                mentionedSessionIds = []
                            }
                        } label: {
                            Label("发送", systemImage: "paperplane")
                        }
                        .disabled(announcementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

private struct MentionSessionPicker: View {
    let sessions: [CrewSession]
    @Binding var selectedSessionIds: Set<String>

    var body: some View {
        if sessions.isEmpty {
            Text("当前没有可 @ 的 session")
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedSessionIds = []
                    } label: {
                        Label("全员", systemImage: selectedSessionIds.isEmpty ? "checkmark.circle.fill" : "circle")
                    }
                    ForEach(sessions) { session in
                        Button {
                            if selectedSessionIds.contains(session.id) {
                                selectedSessionIds.remove(session.id)
                            } else {
                                selectedSessionIds.insert(session.id)
                            }
                        } label: {
                            Label(
                                session.runnerKind,
                                systemImage: selectedSessionIds.contains(session.id) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .help(session.id)
                    }
                }
            }
        }
    }
}

private struct AnnouncementRow: View {
    let announcement: CrewAnnouncement
    let sessions: [CrewSession]
    let members: [CrewMember]
    let onReplyToSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(senderLabel)
                    .font(.headline)
                Text(targetLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(announcement.createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(announcement.summary)
            if let senderSessionId = announcement.senderSessionId {
                Button {
                    onReplyToSession(senderSessionId)
                } label: {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var senderLabel: String {
        if let senderSessionId = announcement.senderSessionId {
            return sessionLabel(senderSessionId)
        }
        switch announcement.senderKind {
        case "human": return "人类"
        case "master_bot": return "Master Bot"
        case "system": return "系统"
        default: return announcement.senderKind
        }
    }

    private var targetLabel: String {
        if announcement.recipientMode == "all_sessions" {
            return "@全员"
        }
        let targets = announcement.mentions.map { mention -> String in
            if let sessionId = mention.targetSessionId {
                return "@\(sessionLabel(sessionId))"
            }
            if let memberId = mention.targetMemberId {
                return "@\(memberLabel(memberId))"
            }
            return "@?"
        }
        return targets.isEmpty ? "@-" : targets.joined(separator: " ")
    }

    private func sessionLabel(_ sessionId: String) -> String {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            return "session:\(sessionId.prefix(8))"
        }
        return "\(session.runnerKind):\(session.id.prefix(8))"
    }

    private func memberLabel(_ memberId: String) -> String {
        guard let member = members.first(where: { $0.id == memberId }) else {
            return "member:\(memberId.prefix(8))"
        }
        return member.displayName
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
