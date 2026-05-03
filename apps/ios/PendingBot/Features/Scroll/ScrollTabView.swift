import SwiftUI
import Supabase

/// 奏折 tab — feed of articles each bot has written for the user. Tap a
/// row to open the article; tap the "+" toolbar button to ask one of
/// your bots to write a new one (manual trigger only for now; cron
/// auto-trigger is pending design tests).
///
/// Reads the initial page directly from `pendingbot.scroll_runs` (RLS
/// scoped to the signed-in user) and subscribes to a feed-level
/// Realtime channel for live INSERT/UPDATE/DELETE.
struct ScrollTabView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.api) private var api

    @State private var runs: [ScrollRun] = []
    @State private var loading = false
    @State private var error: String?
    @State private var composing = false
    @State private var path: [ScrollNav] = []

    @State private var feedToken: ScrollFeedToken?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TabHeaderBar(title: "奏折") {
                    Button {
                        composing = true
                        Haptics.tap()
                    } label: {
                        CirclePlusButton()
                    }
                }
                ZStack {
                    Theme.Palette.canvas.ignoresSafeArea()
                    if runs.isEmpty && !loading {
                        EmptyState()
                    } else {
                        List {
                            ForEach(runs) { run in
                                ScrollFeedRow(run: run)
                                    .listRowBackground(Theme.Palette.surface)
                                    .listRowInsets(
                                        EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard run.isDone || run.isRunning else { return }
                                        path.append(.article(run.id))
                                        Haptics.tap()
                                    }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .refreshable { await load() }
                    }
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ScrollNav.self) { dest in
                switch dest {
                case .article(let id):
                    ScrollArticleView(scrollRunId: id)
                }
            }
            .sheet(isPresented: $composing) {
                ScrollComposerSheet { conversationId in
                    composing = false
                    await trigger(conversationId: conversationId)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
        .task { await onAppearLifecycle() }
        .onDisappear { Task { await onDisappearLifecycle() } }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: - Lifecycle

    private func onAppearLifecycle() async {
        await load()
        await subscribe()
    }

    private func onDisappearLifecycle() async {
        if let t = feedToken {
            await ScrollFeedChannel.shared.stop(t)
            feedToken = nil
        }
    }

    // MARK: - Data

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let rows: [ScrollRun] = try await SupabaseStack.shared
                .from("scroll_runs")
                .select("id, bot_id, conversation_id, status, title, summary, body_md, progress, created_at, started_at, finished_at")
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            // Hide rows the runner deleted before iOS could see them, plus
            // any stuck "pending" rows (initial INSERT before the runner
            // updates to running). The feed is meant to read as articles.
            runs = rows.filter { $0.status != "cancelled" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func subscribe() async {
        guard let userId = store.current?.id, feedToken == nil else { return }
        feedToken = await ScrollFeedChannel.shared.start(
            userId: userId,
            onUpsert: { record in
                guard let run = ScrollRunDecoder.decode(record) else { return }
                Task { @MainActor in
                    upsert(run: run)
                }
            },
            onDelete: { record in
                guard let id = record["id"]?.stringValue else { return }
                Task { @MainActor in
                    runs.removeAll { $0.id == id }
                }
            }
        )
    }

    @MainActor
    private func upsert(run: ScrollRun) {
        if run.status == "cancelled" {
            runs.removeAll { $0.id == run.id }
            return
        }
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.insert(run, at: 0)
        }
    }

    // MARK: - Trigger

    private func trigger(conversationId: String) async {
        guard let api else { return }
        do {
            _ = try await api.scrollTrigger(conversationId: conversationId)
            // Realtime INSERT will surface the new run; nothing else to do.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ScrollNav: Hashable {
    case article(String)
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("还没有奏折")
                .font(Theme.Fonts.serif(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("点右上角的「+」让某只机器人为你拟一卷。")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
