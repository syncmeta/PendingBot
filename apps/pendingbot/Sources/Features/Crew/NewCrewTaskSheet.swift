import SwiftUI

/// The new-task sheet: pick a crew (annotated with runner online status),
/// pick a runner kind, write a brief, and POST a queued session. On success
/// the caller reloads the list and highlights the new row.
struct NewCrewTaskSheet: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    /// Called with the freshly created session id after a successful POST.
    let onCreated: (String) -> Void

    @State private var crews: [CrewRow] = []
    @State private var onlineCrewIds: Set<String> = []
    @State private var selectedCrewId: String?
    @State private var runnerKind: CrewRunnerKind = .claude
    @State private var brief = ""
    @State private var loading = true
    @State private var submitting = false
    @State private var errorText: String?

    private static let briefLimit = 12_000

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if crews.isEmpty {
                    Text("还没有可用的机组。先在消息 tab / PendingCrew 建一个机组。")
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                } else {
                    crewSection
                    runnerSection
                    briefSection
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
            .navigationTitle("新任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("派发") { submit() }
                        .disabled(!canSubmit)
                }
            }
            .task { await load() }
        }
    }

    private var crewSection: some View {
        Section("机组") {
            Picker("机组", selection: $selectedCrewId) {
                ForEach(crews) { crew in
                    HStack {
                        Text(crew.title ?? "Crew")
                        if onlineCrewIds.contains(crew.conversation_id) {
                            Text("· runner 在线").foregroundStyle(Theme.Palette.success)
                        } else {
                            Text("· 排队等 runner").foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    .tag(Optional(crew.conversation_id))
                }
            }
        }
    }

    private var runnerSection: some View {
        Section("Runner") {
            Picker("类型", selection: $runnerKind) {
                ForEach(CrewRunnerKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var briefSection: some View {
        Section {
            TextField("任务简报…", text: $brief, axis: .vertical)
                .lineLimit(4...12)
        } header: {
            Text("简报")
        } footer: {
            Text("\(brief.count) / \(Self.briefLimit)")
                .foregroundStyle(brief.count > Self.briefLimit ? Theme.Palette.danger : Theme.Palette.inkMuted)
        }
    }

    private var canSubmit: Bool {
        selectedCrewId != nil
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && brief.count <= Self.briefLimit
            && !submitting
    }

    private func load() async {
        guard let api else { loading = false; return }
        loading = true
        defer { loading = false }
        do {
            async let crewsCall = api.listCrews()
            async let hostsCall = api.listRunnerHosts()
            let (loadedCrews, hosts) = try await (crewsCall, hostsCall)
            self.crews = loadedCrews
            self.selectedCrewId = loadedCrews.first?.conversation_id
            // A crew shows "runner online" when its responsible subject owns a
            // runner_host that's status=online and was seen within 3 minutes.
            let onlineSubjects = Set(
                hosts.filter { isOnline($0) }.compactMap(\.responsible_subject_id)
            )
            self.onlineCrewIds = Set(
                loadedCrews
                    .filter { crew in
                        guard let subject = crew.responsible_subject_id else { return false }
                        return onlineSubjects.contains(subject)
                    }
                    .map(\.conversation_id)
            )
        } catch {
            self.errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func isOnline(_ host: RunnerHostRow) -> Bool {
        guard (host.status ?? "").lowercased() == "online" else { return false }
        guard let seen = CrewDate.parse(host.last_seen_at) else { return false }
        return Date().timeIntervalSince(seen) < 180
    }

    private func submit() {
        guard let api, let crewId = selectedCrewId, canSubmit else { return }
        submitting = true
        errorText = nil
        Task {
            defer { submitting = false }
            do {
                let sessionId = try await api.createSession(
                    crewConversationId: crewId,
                    runnerKind: runnerKind.rawValue,
                    taskBrief: brief.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                onCreated(sessionId)
                dismiss()
            } catch {
                self.errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
