import SwiftUI
import Supabase

/// One card in the 奏折 feed. Reads like a news/article preview rather
/// than a chat row — large serif headline up top, lead summary, byline
/// at the bottom (small avatar + bot name + relative time).
struct ScrollFeedRow: View {
    let run: ScrollRun
    let botName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displayTitle)
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if run.isRunning {
                HStack(spacing: 6) {
                    TypingDots()
                    Text(progressLabel)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            } else if let summary = run.summary, !summary.isEmpty {
                Text(summary)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            } else if run.status == "error" {
                Text("写信失败")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            byline
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }

    // MARK: - Byline

    @ViewBuilder
    private var byline: some View {
        HStack(spacing: 8) {
            BotAvatar(seed: run.bot_id, size: 22)
            if let name = botName, !name.isEmpty {
                Text(name)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
            if let stamp = relativeTime {
                Text("·")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                Text(stamp)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: - Derived

    private var displayTitle: String {
        if let t = run.title, !t.isEmpty { return t }
        if run.isRunning { return "正在写来信…" }
        if run.status == "error" { return "未命名来信" }
        return "未命名来信"
    }

    /// Phase tag from `progress.phase`. Falls back to a generic label
    /// when the runner hasn't written one yet.
    private var progressLabel: String {
        ScrollPhaseLabel.text(ScrollProgress.from(run.progress).phase)
    }

    private var relativeTime: String? {
        guard let date = ServerTimestamp.parse(run.created_at) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
