import SwiftUI
import Supabase

/// One card in the 奏折 feed. Reads like a clipped letter / column rather
/// than a chat row — top kicker (from + date), large serif headline, lead
/// summary, and a status pill for non-done states. A running row gets a
/// thin accent strip on the leading edge so the whole card reads as
/// "still being written" without crowding the body with typing dots.
struct EnvelopeFeedRow: View {
    let run: EnvelopeRun
    /// Display name for the sender — bot's display_name when kind='bot',
    /// the author's profile name (resolved from local contacts cache)
    /// when kind='human'. Nil while the lookup is in flight; the row
    /// renders a generic kicker label as fallback.
    let senderName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Leading accent strip — only painted while the run is live.
            // Keeps a fixed-width gutter on every card so titles align.
            Rectangle()
                .fill(run.isRunning ? Theme.Palette.accent : Color.clear)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 14) {
                kickerRow
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 0.5)

                Text(displayTitle)
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if run.isRunning {
                    HStack(spacing: 6) {
                        TypingDots()
                        Text(progressLabel)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                    }
                } else if let summary = run.summary, !summary.isEmpty {
                    // Cover deck — the bot's deliberate subtitle. Allow up
                    // to three lines so a 60-char Chinese subtitle can
                    // breathe instead of getting clipped mid-clause.
                    Text(summary)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                }

                statusPill
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
    }

    // MARK: - Kicker (from · date)

    /// "From" line at the top of the card — small avatar + bot name set
    /// in tracked rounded caps, with a relative date on the trailing edge.
    /// This is the postmark on the envelope.
    @ViewBuilder
    private var kickerRow: some View {
        HStack(spacing: 8) {
            // Preset 「读我」row shows the app brand mark; everything else
            // gets BotAvatar's seed-based glyph.
            LetterSenderAvatar(run: run, size: 18)
            if let name = displaySenderName, !name.isEmpty {
                Text(name)
                    .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Palette.ink)
                    .textCase(.uppercase)
                    .lineLimit(1)
            } else {
                Text(run.isHuman ? "好友" : "机器人")
                    .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .textCase(.uppercase)
            }
            Spacer(minLength: 4)
            if let stamp = relativeTime {
                Text(stamp)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    /// Byline name. The preset 「读我」letter is attributed to the app
    /// itself; otherwise use the resolved bot / author name.
    private var displaySenderName: String? {
        run.isPreset ? EnvelopeRun.presetSenderName : senderName
    }

    // MARK: - Status pill (only for non-done, non-running)

    @ViewBuilder
    private var statusPill: some View {
        if run.status == "error" {
            StatusPill(text: "写丢了", tone: .warning)
        } else if run.status == "cancelled" {
            StatusPill(text: "已中止", tone: .neutral)
        } else if run.status == "pending" && !run.isRunning {
            StatusPill(text: "排队中", tone: .neutral)
        } else {
            EmptyView()
        }
    }

    // MARK: - Derived

    private var displayTitle: String {
        if let t = run.title, !t.isEmpty { return t }
        if run.isRunning { return "正在写来信…" }
        if run.status == "error" { return "未命名来信" }
        return "未命名来信"
    }

    /// What the row says next to the typing dots while the run is going.
    /// Prefers the runner's live `current_activity` heartbeat so the
    /// feed updates per step (e.g. "搜索 X · 读 host.com"); falls back to
    /// the coarser phase label between heartbeats.
    private var progressLabel: String {
        let p = EnvelopeProgress.from(run.progress)
        return p.currentActivity ?? EnvelopePhaseLabel.text(p.phase)
    }

    private var relativeTime: String? {
        guard let date = ServerTimestamp.parse(run.created_at) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    enum Tone { case warning, neutral }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(bg)
            )
    }

    private var fg: Color {
        switch tone {
        case .warning: return Theme.Palette.amber
        case .neutral: return Theme.Palette.inkMuted
        }
    }
    private var bg: Color {
        switch tone {
        case .warning: return Theme.Palette.amberBg
        case .neutral: return Theme.Palette.surfaceMuted
        }
    }
}
