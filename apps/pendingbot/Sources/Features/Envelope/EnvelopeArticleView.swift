import SwiftUI
import Supabase

/// Detail view for a single scroll. Loads the row, then subscribes to
/// it via Realtime so a still-running scroll fills in the body live as
/// the runner writes it. Renders body_md with MarkdownText.
struct EnvelopeArticleView: View {
    let envelopeRunId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.api) private var api

    @State private var run: EnvelopeRun?
    @State private var loading = true
    @State private var error: String?
    @State private var bot: BotMeta?
    @State private var feedToken: EnvelopeFeedToken?
    @State private var cancelling = false
    @State private var showCancelConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let run {
                    headerSection(run: run)
                    bodySection(run: run)
                } else if loading {
                    ProgressView().padding(.top, 80)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter + 4)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .readableColumnWidth()
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("来信")
        .inlineNavTitle()
        .toolbar {
            if let run, run.isRunning {
                ToolbarItem(placement: .platformTrailing) {
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

    /// Editorial header — large serif title, optional subtitle as a quiet
    /// deck line under it, hairline divider, then a single byline row:
    /// avatar + bot name on the leading edge, "于 5月10日 14:23" set in
    /// muted caption on the trailing edge. No green kicker on top — the
    /// title is allowed to lead.
    @ViewBuilder
    private func headerSection(run: EnvelopeRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title = run.title, !title.isEmpty {
                Text(title)
                    .font(Theme.Fonts.serif(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
            }

            if let subtitle = run.summary, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Fonts.serif(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 0.5)

            HStack(alignment: .center, spacing: 10) {
                LetterSenderAvatar(run: run, size: 28)
                // Name and timestamp sit as a single byline cluster on
                // the leading edge — the timestamp clings to the name
                // (separated by a thin space) rather than being trailing-
                // aligned to the column edge, which read as two unrelated
                // pieces of metadata in the previous version.
                Text(senderLabel(run: run))
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let stamp = formattedTimestamp(run.created_at) {
                    Text(stamp)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Byline label: "Untitled" for the preset 「读我」letter, the bot's
    /// display_name (loaded async) for kind='bot', or the local contact
    /// alias / display name for kind='human'. The human path doesn't
    /// trigger a network fetch — pendingbot.users is RLS-self so we only
    /// know names of people already in our contacts.
    private func senderLabel(run: EnvelopeRun) -> String {
        if run.isPreset { return EnvelopeRun.presetSenderName }
        if run.isHuman {
            guard let id = run.author_user_id else { return "好友" }
            for c in LocalDatabase.shared.loadContacts() where c.id == id {
                if let alias = c.alias, !alias.isEmpty { return alias }
                if !c.display_name.isEmpty { return c.display_name }
            }
            return "好友"
        }
        return bot?.display_name ?? "机器人"
    }

    /// "于 5月10日 14:23" — Chinese-locale month/day + 24h time. Returns
    /// nil if the row's timestamp can't be parsed (very old / corrupted
    /// rows) so the byline row gracefully drops the date instead of
    /// rendering "于 ".
    private func formattedTimestamp(_ raw: String) -> String? {
        guard let date = ServerTimestamp.parse(raw) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "于 " + f.string(from: date)
    }

    // MARK: - Body

    @ViewBuilder
    private func bodySection(run: EnvelopeRun) -> some View {
        if let body = run.body_md, !body.isEmpty {
            MarkdownText(text: body, variant: .article)
            // Bot envelopes carry a per-turn research trace; human-written
            // letters don't run a loop, so there's nothing to audit there.
            if !run.isHuman {
                EnvelopeThinkingTrace(turns: EnvelopeTurn.parse(run.turns), collapsed: true)
            }
        } else if run.isRunning {
            runningSection(progress: EnvelopeProgress.from(run.progress))
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
    private func runningSection(progress: EnvelopeProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TypingDots()
                    Text(progress.currentActivity ?? EnvelopePhaseLabel.text(progress.phase))
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.ink)
                }
                // When the runner has a fresher activity line, keep the
                // phase label visible underneath as quieter context so
                // the user can still see "上网查证" while the heartbeat
                // line updates per step.
                if progress.currentActivity != nil {
                    Text(EnvelopePhaseLabel.text(progress.phase))
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
        .padding(.top, 4)
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
            // Array fetch (not .single()) so a row that the runner has
            // already silently deleted ("空奏折不落库") returns empty
            // instead of throwing PostgREST's "cannot coerce" error.
            let rows: [EnvelopeRun] = try await SupabaseStack.shared
                .from("envelope_runs")
                .select("id, kind, trigger, bot_id, author_user_id, conversation_id, status, title, summary, body_md, progress, turns, created_at, started_at, finished_at")
                .eq("id", value: envelopeRunId)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else {
                dismiss()
                return
            }
            self.run = row
            // Preset 「读我」rows render as "Untitled" — skip the self-bot fetch.
            if let botId = row.bot_id, !row.isPreset {
                await loadBot(id: botId)
            }
            // No async fetch for human authors — pull whatever the local
            // contacts cache has and let the byline fall back to "好友"
            // if the row arrived from someone not yet cached.
            if row.isRunning { await subscribe() }
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
        feedToken = await EnvelopeFeedChannel.shared.start(
            userId: userId,
            onUpsert: { record in
                guard let r = EnvelopeRunDecoder.decode(record),
                      r.id == envelopeRunId else { return }
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
            await EnvelopeFeedChannel.shared.stop(t)
            feedToken = nil
        }
    }

    private func cancel() async {
        guard let api else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            try await api.envelopeCancel(id: envelopeRunId)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BotMeta: Decodable {
    let id: String
    let display_name: String
}
