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
        let phase = run.progress?.phase ?? "拟稿中"
        switch phase {
        case "queued":   return "排队中"
        case "gather":   return "翻最近的对话"
        case "plan":     return "整理思路"
        case "research": return "上网查证"
        case "compose":  return "落笔"
        case "done":     return "收尾"
        case "error":    return "拟稿失败"
        default:         return phase
        }
    }

    private var relativeTime: String? {
        guard let date = ServerTimestamp.parse(run.created_at) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - AnyJSON helpers

private extension AnyJSON {
    /// Read `progress.phase` out of the JSONB blob without spinning up a
    /// full Decoder. AnyJSON exposes both `string(...)` and `object(...)`
    /// cases that we walk by hand. Returns nil if `self` isn't an object
    /// or the field isn't a string.
    var phase: String? {
        guard case let .object(dict) = self else { return nil }
        guard case let .string(s)? = dict["phase"] else { return nil }
        return s
    }
}
