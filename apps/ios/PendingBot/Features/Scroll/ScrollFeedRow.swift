import SwiftUI
import Supabase

/// One row in the 奏折 feed. Layout mirrors the message-list style —
/// bot avatar on the left, title + summary on the right, status pill
/// for in-progress runs.
struct ScrollFeedRow: View {
    let run: ScrollRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(seed: run.bot_id, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayTitle)
                        .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if let stamp = relativeTime {
                        Text(stamp)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }

                if run.isRunning {
                    HStack(spacing: 6) {
                        TypingDots()
                        Text(progressLabel)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                } else if let summary = run.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else if run.status == "error" {
                    Text("拟稿失败")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Derived

    private var displayTitle: String {
        if let t = run.title, !t.isEmpty { return t }
        if run.isRunning { return "正在拟稿" }
        return "未命名奏折"
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

