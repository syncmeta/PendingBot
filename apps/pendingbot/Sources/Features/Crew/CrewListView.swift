import SwiftUI

/// The 机组 tab list page — a task card stream (Codex-style, not a dashboard).
/// Segmented 进行中|全部 filter, a + to launch a new task, waiting-permission
/// sessions pinned amber to the top.
struct CrewListView: View {
    @Environment(\.api) private var api
    @StateObject private var store = CrewListStore()

    /// Wide-shell selection binding (list column writes it). nil in compact.
    var externalSelection: Binding<String?>?
    /// Compact mode wraps itself in a NavigationStack + pushes detail; the
    /// wide list column does neither (the shell owns navigation).
    var embedInNavigationStack: Bool

    @State private var showAll = false
    @State private var showNewTask = false
    /// Compact-mode push path.
    @State private var pushed: String?

    var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack {
                    content
                        .navigationTitle("机组")
                        .navigationDestination(item: $pushed) { sessionId in
                            CrewSessionDetailView(sessionId: sessionId)
                        }
                }
            } else {
                content
            }
        }
        .task {
            store.configure(api: api)
            await store.load()
            store.startPolling()
        }
        .onDisappear { store.stopPolling() }
        .sheet(isPresented: $showNewTask) {
            NewCrewTaskSheet { newSessionId in
                Task {
                    await store.load()
                    select(newSessionId)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            filterBar
            listBody
        }
        .background(Theme.Palette.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewTask = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("发新任务")
            }
        }
    }

    private var filterBar: some View {
        Picker("筛选", selection: $showAll) {
            Text("进行中").tag(false)
            Text("全部").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var listBody: some View {
        let rows = store.sorted(all: showAll)
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { session in
                        Button {
                            select(session.id)
                        } label: {
                            CrewSessionCard(
                                session: session,
                                crewTitle: store.crewTitle(for: session.crew_conversation_id),
                                selected: externalSelection?.wrappedValue == session.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.vertical, 8)
            }
            .refreshable { await store.load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.inkMuted.opacity(0.55))
            Text(showAll ? "还没有任务" : "没有进行中的任务")
                .font(Theme.Fonts.serif(size: 18))
                .foregroundStyle(Theme.Palette.ink)
            Text("在 PendingCrew Mac 端接上 runner,再点右上角「+」\n给机组派第一个任务。")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
            Button {
                showNewTask = true
            } label: {
                Text("发新任务")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.Palette.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .overlay(alignment: .top) {
            if let err = store.loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.danger)
                    .padding(8)
            }
        }
    }

    /// Route selection: wide shell writes the binding, compact pushes.
    private func select(_ sessionId: String) {
        if let externalSelection {
            externalSelection.wrappedValue = sessionId
        } else {
            pushed = sessionId
        }
    }
}

// MARK: - Card row

/// One task card: title (task_brief first line) + subrow (crew · runner ·
/// relative time) + status badge.
struct CrewSessionCard: View {
    let session: CrewSessionRow
    let crewTitle: String
    let selected: Bool

    private var status: CrewSessionStatus { CrewSessionStatus(raw: session.status) }
    private var title: String {
        let trimmed = session.task_brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return firstLine.isEmpty ? "(无标题任务)" : firstLine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CrewStatusBadge(status: status)
            }
            HStack(spacing: 6) {
                Text(crewTitle)
                    .lineLimit(1)
                Text("·")
                Text(CrewRunnerKind.shortLabel(session.runner_kind))
                Text("·")
                Text(CrewDate.relative(session.updated_at ?? session.created_at))
            }
            .font(.caption)
            .foregroundStyle(Theme.Palette.inkMuted)
            if let progress = session.progress_summary,
               !progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(progress)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(
                    selected ? Theme.Palette.accent : Theme.Palette.hairline,
                    lineWidth: selected ? 1.5 : 0.5
                )
        )
    }
}
