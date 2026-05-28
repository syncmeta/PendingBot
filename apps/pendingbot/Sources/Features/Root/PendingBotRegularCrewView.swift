// NOTE: `PendingBotShared` is referenced as a placeholder for the
// big-screen shared layer; the types it provides (PendingBotCrewSummary,
// PendingBotCrewWorkspaceView, etc.) actually live in this same target
// under Sources/Shared/. The original `import PendingBotShared` was T0.1
// scaffold dead-code that broke build because the module doesn't exist
// — dropping it makes the file resolve the symbols intra-module.
import SwiftUI

struct PendingBotRegularCrewView: View {
    @Environment(\.api) private var api

    @State private var crews: [CrewSummary] = []
    @State private var selectedCrewId: String?
    @State private var linksByCrew: [String: CrewLinksResponse] = [:]
    @State private var membersByCrew: [String: [CrewMemberSummary]] = [:]
    @State private var sessionsByCrew: [String: [CrewSessionSummary]] = [:]
    @State private var announcementsByCrew: [String: [CrewAnnouncementSummary]] = [:]
    @State private var loadedDetailCrewIds: Set<String> = []
    @State private var loadingDetailCrewIds: Set<String> = []
    @State private var detailErrors: [String: String] = [:]
    @State private var isLoadingCrews = false
    @State private var errorMessage: String?

    var body: some View {
        PendingBotCrewWorkspaceView(
            crews: sharedCrews,
            selectedCrewId: $selectedCrewId,
            crewDetails: sharedDetails,
            crewListLoading: isLoadingCrews,
            crewDetailLoadingIds: loadingDetailCrewIds,
            crewDetailErrors: detailErrors,
            onRefresh: {
                Task { await loadAll() }
            },
            onSelectCrew: { crewId in
                selectedCrewId = crewId
                Task { await loadDetail(for: crewId) }
            },
            onSendAnnouncement: { crewId, summary in
                Task { await sendAnnouncement(in: crewId, summary: summary) }
            },
            onCreateSession: { crewId, runnerKind, taskBrief in
                Task { await createSession(in: crewId, runnerKind: runnerKind, taskBrief: taskBrief) }
            },
            onCreateChildCrew: { crewId, title in
                Task { await createChildCrew(parentCrewId: crewId, title: title) }
            }
        )
        .task { await loadAll() }
        .alert("出错", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var sharedCrews: [PendingBotCrewSummary] {
        crews.map { crew in
            PendingBotCrewSummary(
                id: crew.id,
                title: crew.title,
                status: crew.status,
                runtimeKind: PendingBotCrewRuntimeKind(apiValue: crew.runtime_kind ?? "local"),
                updatedAt: crew.updated_at
            )
        }
    }

    private var sharedDetails: [String: PendingBotCrewDetail] {
        Dictionary(uniqueKeysWithValues: loadedDetailCrewIds.map { crewId in
            let links = linksByCrew[crewId]
            return (
                crewId,
                PendingBotCrewDetail(
                    crewId: crewId,
                    parents: (links?.parents ?? []).map(\.shared),
                    children: (links?.children ?? []).map(\.shared),
                    responsibilityShares: (links?.responsibilityShares ?? []).map(\.shared),
                    sessions: (sessionsByCrew[crewId] ?? []).map(\.shared),
                    members: (membersByCrew[crewId] ?? []).map(\.shared),
                    announcements: (announcementsByCrew[crewId] ?? []).map(\.shared)
                )
            )
        })
    }

    private func loadAll() async {
        guard let api else { return }
        isLoadingCrews = true
        defer { isLoadingCrews = false }

        do {
            crews = try await api.crewList()
            if selectedCrewId.map({ id in crews.contains { $0.id == id } }) != true {
                selectedCrewId = crews.first?.id
            }
            if let selectedCrewId {
                await loadDetail(for: selectedCrewId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDetail(for crewId: String) async {
        guard let api else { return }
        loadingDetailCrewIds.insert(crewId)
        detailErrors[crewId] = nil
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
            loadedDetailCrewIds.insert(crewId)
        } catch {
            detailErrors[crewId] = error.localizedDescription
        }
    }

    private func sendAnnouncement(in crewId: String, summary: String) async {
        guard let api else { return }
        do {
            _ = try await api.crewCreateAnnouncement(crewId: crewId, summary: summary)
            await loadDetail(for: crewId)
        } catch {
            detailErrors[crewId] = error.localizedDescription
        }
    }

    private func createSession(in crewId: String, runnerKind: PendingBotCrewRunnerKind, taskBrief: String) async {
        guard let api else { return }
        do {
            _ = try await api.crewCreateSession(
                crewId: crewId,
                runnerKind: CrewRunnerKind(rawValue: runnerKind.rawValue) ?? .localCodex,
                taskBrief: taskBrief
            )
            await loadDetail(for: crewId)
        } catch {
            detailErrors[crewId] = error.localizedDescription
        }
    }

    private func createChildCrew(parentCrewId: String, title: String) async {
        guard let api else { return }
        do {
            _ = try await api.crewCreateChild(crewId: parentCrewId, title: title)
            await loadAll()
        } catch {
            detailErrors[parentCrewId] = error.localizedDescription
        }
    }
}

private extension CrewLinkSummary {
    var shared: PendingBotCrewLink {
        PendingBotCrewLink(
            crewId: crew_conversation_id,
            title: title,
            status: status,
            runtimeKind: PendingBotCrewRuntimeKind(apiValue: runtime_kind),
            captainBotId: captain_bot_id,
            captainMemberId: captain_member_id,
            createdAt: created_at
        )
    }
}

private extension CrewResponsibilityShareSummary {
    var shared: PendingBotCrewResponsibilityShare {
        PendingBotCrewResponsibilityShare(subjectId: subject_id, shareBps: share_bps, source: source)
    }
}

private extension CrewSessionSummary {
    var shared: PendingBotCrewSession {
        PendingBotCrewSession(
            id: id,
            crewId: crew_conversation_id,
            responsibleSubjectId: responsible_subject_id,
            runnerKind: PendingBotCrewRunnerKind(rawValue: runner_kind) ?? .localCodex,
            status: status,
            taskBrief: task_brief,
            progressSummary: progress_summary,
            createdAt: created_at,
            startedAt: started_at,
            finishedAt: finished_at
        )
    }
}

private extension CrewMemberSummary {
    var shared: PendingBotCrewMember {
        PendingBotCrewMember(
            id: id,
            crewId: conversation_id,
            memberKind: member_kind,
            displayName: display_name,
            role: role ?? member_kind,
            status: status,
            createdAt: created_at
        )
    }
}

private extension CrewAnnouncementMentionSummary {
    var shared: PendingBotCrewAnnouncementMention {
        PendingBotCrewAnnouncementMention(
            id: id,
            announcementId: announcement_id,
            targetKind: target_kind,
            targetSessionId: target_session_id,
            targetMemberId: target_member_id,
            createdAt: created_at
        )
    }
}

private extension CrewAnnouncementSummary {
    var shared: PendingBotCrewAnnouncement {
        PendingBotCrewAnnouncement(
            id: id,
            crewId: crew_conversation_id,
            responsibleSubjectId: responsible_subject_id,
            senderKind: sender_kind,
            senderMemberId: sender_member_id,
            senderSessionId: sender_session_id,
            recipientMode: recipient_mode,
            messageKind: message_kind,
            boardVisible: board_visible,
            summary: summary,
            createdAt: created_at,
            mentions: mentions.map(\.shared)
        )
    }
}
