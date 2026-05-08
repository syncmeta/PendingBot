import SwiftUI
import Supabase

/// Detail view for a single scroll. Loads the row, then subscribes to
/// it via Realtime so a still-running scroll fills in the body live as
/// the runner writes it. Renders body_md with MarkdownText.
struct ScrollArticleView: View {
    let scrollRunId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.api) private var api

    @State private var run: ScrollRun?
    @State private var loading = true
    @State private var error: String?
    @State private var bot: BotMeta?
    @State private var feedToken: ScrollFeedToken?
    @State private var cancelling = false
    @State private var showCancelConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let run {
                    headerSection(run: run)
                    bodySection(run: run)
                } else if loading {
                    ProgressView().padding(.top, 80)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .readableColumnWidth()
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("来信")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let run, run.isRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("中止") { showCancelConfirm = true }
                        .disabled(cancelling)
                }
            }
        }
        .confirmationDialog(
            "中止这封来信？",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("中止", role: .destructive) { Task { await cancel() } }
            Button("继续等", role: .cancel) {}
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .task { await load() }
        .onDisappear { Task { await stop() } }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection(run: ScrollRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BotAvatar(seed: run.bot_id, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot?.display_name ?? "机器人")
                        .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                    if let date = ServerTimestamp.parse(run.created_at) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer()
            }
            if let title = run.title, !title.isEmpty {
                Text(title)
                    .font(Theme.Fonts.serif(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func bodySection(run: ScrollRun) -> some View {
        if let body = run.body_md, !body.isEmpty {
            MarkdownText(text: body)
            // Even after the article is done, keep the thinking trace
            // available so the reader can audit the research path.
            EnvelopeThinkingTrace(turns: EnvelopeTurn.parse(run.turns), collapsed: true)
        } else if run.isRunning {
            runningSection(progress: ScrollProgress.from(run.progress))
            EnvelopeThinkingTrace(turns: EnvelopeTurn.parse(run.turns), collapsed: false)
        } else if run.status == "error" {
            Text("这封来信写丢了。可以从来信列表删掉重来。")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
            EnvelopeThinkingTrace(turns: EnvelopeTurn.parse(run.turns), collapsed: true)
        } else if run.status == "cancelled" {
            Text("这封来信被中止了。")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.inkMuted)
            EnvelopeThinkingTrace(turns: EnvelopeTurn.parse(run.turns), collapsed: true)
        }
    }

    // MARK: - Running progress

    /// Live "process" panel shown while body_md is empty. Surfaces the
    /// runner's phase, the notes it has taken, and the URLs it has
    /// fetched — all of which the runner persists into `progress` after
    /// every turn so this view fills in over Realtime as the agent works.
    @ViewBuilder
    private func runningSection(progress: ScrollProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TypingDots()
                    Text(progress.currentActivity ?? ScrollPhaseLabel.text(progress.phase))
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.ink)
                }
                // When the runner has a fresher activity line, keep the
                // phase label visible underneath as quieter context so
                // the user can still see "上网查证" while the heartbeat
                // line updates per step.
                if progress.currentActivity != nil {
                    Text(ScrollPhaseLabel.text(progress.phase))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.leading, 22)
                }
            }

            if !progress.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已记下的线索（\(progress.notes.count)）")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(progress.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("·")
                                    .foregroundStyle(Theme.Palette.inkMuted)
                                Text(note.text)
                                    .font(Theme.Fonts.footnote)
                                    .foregroundStyle(Theme.Palette.ink)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if !progress.visitedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("翻过的网页（\(progress.visitedURLs.count)）")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(progress.visitedURLs, id: \.self) { url in
                            Text(displayHost(url))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.inkMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Text("写好之后会出现在这里。可以离开这页，等会儿回来看。")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.top, 8)
        .animation(.default, value: progress.notes.count)
        .animation(.default, value: progress.visitedURLs.count)
        .animation(.default, value: progress.phase)
        .animation(.default, value: progress.currentActivity)
    }

    /// Strip scheme + path so the URL list reads as a quiet list of
    /// sources rather than a wall of links.
    private func displayHost(_ raw: String) -> String {
        if let host = URL(string: raw)?.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return raw
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let row: ScrollRun? = try await SupabaseStack.shared
                .from("scroll_runs")
                .select("id, bot_id, conversation_id, status, title, summary, body_md, progress, turns, created_at, started_at, finished_at")
                .eq("id", value: scrollRunId)
                .limit(1)
                .single()
                .execute()
                .value
            self.run = row
            if let row {
                await loadBot(id: row.bot_id)
                if row.isRunning { await subscribe() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadBot(id: String) async {
        do {
            let row: BotMeta = try await SupabaseStack.shared
                .from("bots")
                .select("id, display_name")
                .eq("id", value: id)
                .single()
                .execute()
                .value
            self.bot = row
        } catch {
            // Non-fatal — header just shows a generic label.
        }
    }

    private func subscribe() async {
        guard let userId = AccountStore.shared.current?.id, feedToken == nil else { return }
        feedToken = await ScrollFeedChannel.shared.start(
            userId: userId,
            onUpsert: { record in
                guard let r = ScrollRunDecoder.decode(record),
                      r.id == scrollRunId else { return }
                Task { @MainActor in self.run = r }
            },
            onDelete: { _ in
                // Row deleted (silent run) — pop back.
                Task { @MainActor in self.dismiss() }
            }
        )
    }

    private func stop() async {
        if let t = feedToken {
            await ScrollFeedChannel.shared.stop(t)
            feedToken = nil
        }
    }

    private func cancel() async {
        guard let api else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            try await api.scrollCancel(id: scrollRunId)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BotMeta: Decodable {
    let id: String
    let display_name: String
}
