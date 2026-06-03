#if os(iOS)
import SwiftUI
import Supabase

/// 奏折 tab — feed of articles each bot has written for the user. Tap a
/// row to open the article; tap the "+" toolbar button to ask one of
/// your bots to write a new one (manual trigger only for now; cron
/// auto-trigger is pending design tests).
///
/// Reads the initial page directly from `pendingbot.envelope_runs` (RLS
/// scoped to the signed-in user) and subscribes to a feed-level
/// Realtime channel for live INSERT/UPDATE/DELETE.
struct EnvelopeTabView: View {
    @EnvironmentObject private var store: AccountStore
    @EnvironmentObject private var unread: UnreadStore
    @Environment(\.api) private var api
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var runs: [EnvelopeRun] = []
    @State private var botNames: [String: String] = [:]
    /// Display names for human-letter authors. Resolved from the local
    /// contacts cache (LocalDatabase) since pendingbot.users is RLS-self
    /// and a server round-trip per author would noisy up the feed; if a
    /// letter arrives from a contact not yet cached, the row just shows
    /// the generic "好友" fallback.
    @State private var authorNames: [String: String] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var path: [EnvelopeNav] = []

    @State private var feedToken: EnvelopeFeedToken?

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
                    EmptyDetailHint(text: "选一封来信开读", systemImage: "envelope.open")
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
                // No "+" trigger — new envelopes are kicked off from each
                // conversation's settings sheet. This tab is read-only.
                TabHeaderBar(title: "来信") {
                    if !runs.isEmpty {
                        Text("\(runs.count) 封")
                            .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Theme.Palette.surfaceMuted)
                            )
                    }
                }
                ZStack {
                    Theme.Palette.canvas.ignoresSafeArea()
                    if runs.isEmpty && !loading {
                        EmptyState()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(runs) { run in
                                    EnvelopeFeedRow(run: run, senderName: senderName(for: run))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard run.isDone || run.isRunning else { return }
                                            unread.markEnvelopeRead(run.id)
                                            path.append(.article(run.id))
                                            Haptics.tap()
                                        }
                                }
                            }
                            .padding(.horizontal, Theme.Metrics.gutter)
                            .padding(.vertical, 16)
                            .readableColumnWidth()
                        }
                        .refreshable { await load() }
                    }
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: EnvelopeNav.self) { dest in
                switch dest {
                case .article(let id):
                    EnvelopeArticleView(envelopeRunId: id)
                }
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
            await EnvelopeFeedChannel.shared.stop(t)
            feedToken = nil
        }
    }

    // MARK: - Data

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            // Query lives in the shared `EnvelopeFetch.list()` (Networking/) so
            // iOS + macOS run one query shape.
            let rows: [EnvelopeRun] = try await EnvelopeFetch.list(limit: 50)
            // Hide rows the runner deleted before iOS could see them, plus
            // any stuck "pending" rows (initial INSERT before the runner
            // updates to running). The feed is meant to read as articles.
            runs = rows.filter { $0.status != "cancelled" }
            unread.setCurrentEnvelopes(Set(runs.map(\.id)))
            await refreshBotNames(for: runs)
            refreshAuthorNames(for: runs)
        } catch is CancellationError {
            // Tab switch / refreshable cancellation — silent.
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What to render as the kicker name on a feed row. Bot-letter rows
    /// look up by bot_id; human-letter rows use the local-cached author
    /// name (or alias). Returns nil if the lookup hasn't landed yet —
    /// the row falls back to a generic "机器人" / "好友" label.
    private func senderName(for run: EnvelopeRun) -> String? {
        if run.isHuman {
            guard let id = run.author_user_id else { return nil }
            return authorNames[id]
        }
        guard let id = run.bot_id else { return nil }
        return botNames[id]
    }

    /// Resolve any bot_ids referenced by `feed` into display names so the
    /// row's byline reads "<bot> · 2 分钟前" instead of an anonymous
    /// avatar. Cached in `botNames`; only the missing ids hit the table.
    private func refreshBotNames(for feed: [EnvelopeRun]) async {
        // Preset 「读我」rows render as "Untitled" regardless of bot_id,
        // so don't bother resolving their (self-bot) name.
        let missing = Array(
            Set(feed.compactMap { $0.kind == "bot" && !$0.isPreset ? $0.bot_id : nil })
                .subtracting(botNames.keys)
        )
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

    /// Pull author display names (and the caller's local alias if set)
    /// for human-letter rows out of the local contacts cache. We only
    /// add to the cache; LocalDatabase is the source of truth.
    private func refreshAuthorNames(for feed: [EnvelopeRun]) {
        let missing = Set(feed.compactMap { $0.kind == "human" ? $0.author_user_id : nil })
            .subtracting(authorNames.keys)
        guard !missing.isEmpty else { return }
        let contacts = LocalDatabase.shared.loadContacts()
        var resolved: [String: String] = [:]
        for c in contacts where missing.contains(c.id) {
            if let alias = c.alias, !alias.isEmpty { resolved[c.id] = alias }
            else if !c.display_name.isEmpty { resolved[c.id] = c.display_name }
        }
        if !resolved.isEmpty {
            for (k, v) in resolved { authorNames[k] = v }
        }
    }

    private func subscribe() async {
        guard let userId = store.current?.id, feedToken == nil else { return }
        feedToken = await EnvelopeFeedChannel.shared.start(
            userId: userId,
            onUpsert: { record in
                guard let run = EnvelopeRunDecoder.decode(record) else { return }
                Task { @MainActor in
                    upsert(run: run)
                }
            },
            onDelete: { record in
                guard let id = record["id"]?.stringValue else { return }
                Task { @MainActor in
                    runs.removeAll { $0.id == id }
                    unread.removeCurrentEnvelope(id)
                }
            }
        )
    }

    @MainActor
    private func upsert(run: EnvelopeRun) {
        if run.status == "cancelled" {
            runs.removeAll { $0.id == run.id }
            unread.removeCurrentEnvelope(run.id)
            return
        }
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.insert(run, at: 0)
        }
        unread.addCurrentEnvelope(run.id)
        if run.kind == "human" {
            refreshAuthorNames(for: [run])
        } else if let botId = run.bot_id, botNames[botId] == nil {
            Task { await refreshBotNames(for: [run]) }
        }
    }

}

enum EnvelopeNav: Hashable {
    case article(String)
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.surface)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                    )
                Image(systemName: "envelope")
                    .font(Theme.Fonts.glyph(size: 34, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
            }
            VStack(spacing: 8) {
                Text("还没有来信")
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("打开任意一个机器人对话，进入会话设置，\n请它写一封来信。")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
