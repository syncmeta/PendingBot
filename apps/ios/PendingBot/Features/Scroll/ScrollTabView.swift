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
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var runs: [ScrollRun] = []
    @State private var botNames: [String: String] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var composing = false
    @State private var path: [ScrollNav] = []

    @State private var feedToken: ScrollFeedToken?

    var body: some View {
        Group {
            if sidebarLayout {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        coreContent
                        if let topTabSelection {
                            SidebarTabBar(selection: topTabSelection)
                        }
                    }
                    .sidebarColumnWidth()
                } detail: {
                    EmptyDetailHint(text: "选一篇奏折开读", systemImage: "scroll")
                }
            } else {
                coreContent
                    .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
            }
        }
        .task { await onAppearLifecycle() }
        .onDisappear { Task { await onDisappearLifecycle() } }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder
    private var coreContent: some View {
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
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(runs) { run in
                                    ScrollFeedRow(run: run, botName: botNames[run.bot_id])
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard run.isDone || run.isRunning else { return }
                                            path.append(.article(run.id))
                                            Haptics.tap()
                                        }
                                }
                            }
                            .padding(.horizontal, Theme.Metrics.gutter)
                            .padding(.vertical, 12)
                            .readableColumnWidth()
                        }
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
            await refreshBotNames(for: runs)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Resolve any bot_ids referenced by `feed` into display names so the
    /// row's byline reads "<bot> · 2 分钟前" instead of an anonymous
    /// avatar. Cached in `botNames`; only the missing ids hit the table.
    private func refreshBotNames(for feed: [ScrollRun]) async {
        let missing = Array(Set(feed.map { $0.bot_id }).subtracting(botNames.keys))
        guard !missing.isEmpty else { return }
        struct Row: Decodable { let id: String; let display_name: String }
        do {
            let rows: [Row] = try await SupabaseStack.shared
                .from("bots")
                .select("id, display_name")
                .in("id", values: missing)
                .execute()
                .value
            await MainActor.run {
                for r in rows { botNames[r.id] = r.display_name }
            }
        } catch {
            // Non-fatal — rows just render without a name.
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
        if botNames[run.bot_id] == nil {
            Task { await refreshBotNames(for: [run]) }
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
        Text("这个功能还没做好")
            .font(Theme.Fonts.serif(size: 18, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
