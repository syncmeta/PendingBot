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
///
/// Two layouts driven by `useSidebarLayout` (mirrors Friends / Messages):
///   • compact (iPhone): NavigationStack push from the feed into the article
///   • regular (iPad landscape, Mac Catalyst): NavigationSplitView with the
///     feed as a sidebar and the article on the right detail pane.
struct EnvelopeTabView: View {
    @EnvironmentObject private var store: AccountStore
    // unread 一律走 UnreadStore.shared 单例,不用 @EnvironmentObject:本视图所有
    // unread 访问都在脱离 view body 的逃逸/async 上下文(open/load/subscribe),
    // 那里 wrapper 解析到 placeholder 会 fatalError。详见 MessageTabView 同款注释。
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
    /// Selection-driven detail for the regular size class — mirrors
    /// Friends / Messages so picking a row on Mac / iPad-landscape opens the
    /// article in the right pane instead of pushing inside the sidebar.
    @State private var selectedRunId: String?

    @State private var feedToken: EnvelopeFeedToken?

    /// External selection sink, only set when the Mac three-column shell
    /// reuses our feed via `FeatureSurface.listColumn(selection:)`. When
    /// non-nil, row taps + highlight read/write THIS binding instead of the
    /// internal `selectedRunId` @State, so the shell's own detail column (a
    /// separate `NavigationSplitView` column) updates. nil for every iOS
    /// code path — the normal `body` never sets it, so iOS behavior is
    /// byte-identical to before.
    var externalSelection: Binding<String?>? = nil
    /// 列模式开关:true = body 渲染 Mac 壳的 list 列(见 body 注释)。
    var renderAsMacListColumn = false

    /// The selection the feed reads for row highlight: the shell's binding
    /// when the feed is hosted by the Mac shell, otherwise the internal
    /// @State. The single seam that lets one `coreContent` serve both the
    /// iOS `regularBody` (internal state) and the Mac `listColumn` (external
    /// binding). When `externalSelection` is nil (every iOS path) this is
    /// exactly `selectedRunId`.
    private var effectiveSelection: String? {
        externalSelection?.wrappedValue ?? selectedRunId
    }

    var body: some View {
        // 列模式必须经 body 渲染(同 MessageTabView:在图外手动求值
        // macListColumn 会让 self 拷贝的 @EnvironmentObject 永不灌注 →
        // 首次读取断言崩溃)。
        if renderAsMacListColumn {
            macListColumn
        } else {
            chrome(
                Group {
                    if sidebarLayout {
                        regularBody
                    } else {
                        compactBody
                    }
                }
            )
        }
    }

    /// Wraps a root view with the tab's shared chrome — the `.task` (load +
    /// feed subscribe), the `.onDisappear` channel teardown, and the error
    /// alert. Pulled out of `body` so the Mac three-column shell's
    /// `listColumn` and the `compactRoot` can each be self-contained: every
    /// entry point that hosts the feed carries the same load + Realtime +
    /// error surface, regardless of which SwiftUI container it's planted in.
    /// The iOS `body` calls this with the exact same content it used to
    /// inline, so its behavior is unchanged.
    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        content
            .task { await onAppearLifecycle() }
            .onDisappear { Task { await onDisappearLifecycle() } }
            .alert("出错", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }

    // ── Compact (iPhone) ────────────────────────────────────────────────────

    private var compactBody: some View {
        coreContent
            .platformTabBarVisibility(path.isEmpty)
    }

    // ── Regular (iPad landscape, Mac Catalyst) ──────────────────────────────

    private var regularBody: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                feedList
                if let topTabSelection {
                    SidebarTabBar(selection: topTabSelection)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .sidebarColumnWidth()
        } detail: {
            if let id = selectedRunId {
                EnvelopeArticleView(envelopeRunId: id)
                    // .id forces a fresh article view (and a fresh Realtime
                    // subscription) when the user picks a different letter —
                    // without it the existing view would just rebind, leaking
                    // the prior run's load / subscribe state.
                    .id(id)
            } else {
                EmptyDetailHint(text: "选一封来信开读", systemImage: "envelope.open")
            }
        }
    }

    // ── Compact feed → push article ─────────────────────────────────────────

    @ViewBuilder
    private var coreContent: some View {
        NavigationStack(path: $path) {
            feedList
                .background(Theme.Palette.canvas.ignoresSafeArea())
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .navigationDestination(for: EnvelopeNav.self) { dest in
                    switch dest {
                    case .article(let id):
                        EnvelopeArticleView(envelopeRunId: id)
                    }
                }
        }
    }

    // ── Feed (shared) ───────────────────────────────────────────────────────

    /// The feed itself — header + scrolling letter cards. Shared by the
    /// compact `coreContent` (push) and the regular `regularBody` /
    /// Mac `listColumn` (selection). Row taps route through `open(_:)` so
    /// the right surface (push / detail pane / shell binding) gets the pick.
    @ViewBuilder
    private var feedList: some View {
        VStack(spacing: 0) {
            // No "+" trigger — new envelopes are kicked off from each
            // conversation's settings sheet. This tab is read-only.
            // Mac 壳:无表头(标题去掉);iOS/iPad-regular 保留带计数徽标的表头。
            if !renderAsMacListColumn {
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
            }
            ZStack {
                // Shell 模式下不铺 canvas —— 露出合并侧栏的原生玻璃。
                if !renderAsMacListColumn {
                    Theme.Palette.canvas.ignoresSafeArea()
                }
                if runs.isEmpty && !loading {
                    EmptyState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(runs) { run in
                                EnvelopeFeedRow(run: run, senderName: senderName(for: run))
                                    .modifier(SelectedCardHighlight(
                                        selected: sidebarLayout && effectiveSelection == run.id
                                    ))
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(run) }
                            }
                        }
                        // Shell 契约:卡片前导贴 rail 右沿,右侧留 gutter。
                        .padding(.leading, renderAsMacListColumn ? 0 : Theme.Metrics.gutter)
                        .padding(.trailing, Theme.Metrics.gutter)
                        .padding(.vertical, 16)
                        .readableColumnWidth()
                    }
                    .refreshable { await load() }
                }
            }
        }
    }

    /// Route a tapped letter to the right surface: the Mac shell's detail
    /// column via the external binding (when hosted there), the regular-size
    /// detail pane via the internal `selectedRunId` @State (iPad-landscape /
    /// Mac Catalyst), or a compact nav-stack push (iPhone). The
    /// `externalSelection` branch is only reachable when the Mac three-column
    /// shell built this instance — the iOS `body` leaves it nil, so iPhone /
    /// iPad take exactly the push / detail path they always did.
    private func open(_ run: EnvelopeRun) {
        guard run.isDone || run.isRunning else { return }
        UnreadStore.shared.markEnvelopeRead(run.id)
        if let externalSelection {
            externalSelection.wrappedValue = run.id
        } else if sidebarLayout {
            selectedRunId = run.id
        } else {
            path.append(.article(run.id))
        }
        Haptics.tap()
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
            UnreadStore.shared.setCurrentEnvelopes(Set(runs.map(\.id)))
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
                    UnreadStore.shared.removeCurrentEnvelope(id)
                }
            }
        )
    }

    @MainActor
    private func upsert(run: EnvelopeRun) {
        if run.status == "cancelled" {
            runs.removeAll { $0.id == run.id }
            UnreadStore.shared.removeCurrentEnvelope(run.id)
            return
        }
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.insert(run, at: 0)
        }
        UnreadStore.shared.addCurrentEnvelope(run.id)
        if run.kind == "human" {
            refreshAuthorNames(for: [run])
        } else if let botId = run.bot_id, botNames[botId] == nil {
            Task { await refreshBotNames(for: [run]) }
        }
    }

}

// MARK: - FeatureSurface (Mac three-column shell)

/// Exposes the letter FEED and the article DETAIL as separate columns so
/// the macOS `WideRootView` can drop them into one shared
/// `NavigationSplitView` (feed = middle column, article = right column) — no
/// nested split views. The iOS `body` above is untouched; these methods are
/// additive and only the Mac shell calls them.
///
/// Selection plumbing: the shell owns the `Binding<String?>` (an
/// `envelope_runs.id`) and passes it into `listColumn`. We build an
/// `EnvelopeTabView` instance with its `externalSelection` set to that
/// binding, so the (otherwise unchanged) `feedList` routes row taps +
/// highlight through the shell's selection instead of the internal
/// `@State selectedRunId`. `detailColumn` renders the same
/// `EnvelopeArticleView` the iOS `regularBody` shows for a selected letter,
/// which self-fetches the row by id — so the shell only needs to carry the
/// id, not the full feed row.
extension EnvelopeTabView: FeatureSurface {
    typealias Selection = String

    func listColumn(selection: Binding<String?>) -> some View {
        // A fresh instance bound to the shell's selection. Its body is the
        // feed alone (no SidebarTabBar — on Mac the tab strip is the shell's
        // own first column), carrying the shared chrome so `load()` + the
        // feed Realtime subscription work from this column.
        var view = self
        view.externalSelection = selection
        // 返回配置过的 view 本体让 SwiftUI 装图(见 body 注释),渲染分支
        // 在 body 里走 macListColumn。
        view.renderAsMacListColumn = true
        return view
    }

    func detailColumn(selection: String?) -> some View {
        Group {
            if let id = selection {
                EnvelopeArticleView(envelopeRunId: id)
                    .id(id)
            } else {
                EmptyDetailHint(systemImage: "envelope.open")
            }
        }
    }

    func compactRoot() -> some View {
        // The iPhone feed → push, made self-contained by wrapping it in the
        // same chrome the iOS `body` applies (load task + error alert).
        chrome(compactBody)
    }
}

private extension EnvelopeTabView {
    /// The letter feed as a standalone column for the Mac shell: the shared
    /// `feedList` (no SidebarTabBar) on canvas, carrying the full chrome so
    /// its load + Realtime work from this column.
    var macListColumn: some View {
        // 不铺 canvas —— 合并侧栏的原生玻璃透上来,整条侧栏一块玻璃。
        chrome(feedList)
    }
}

enum EnvelopeNav: Hashable {
    case article(String)
}

/// Tints a feed card when it's the one currently shown in the regular-size
/// detail pane, so the user can see what's open on the right. A no-op
/// (clear) when not selected — keeps the card's own background / border.
private struct SelectedCardHighlight: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(
                    selected ? Theme.Palette.accent.opacity(0.6) : Color.clear,
                    lineWidth: selected ? 1.5 : 0
                )
        )
    }
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
