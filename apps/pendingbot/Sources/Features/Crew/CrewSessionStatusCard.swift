import SwiftUI
import UIKit

// T4.6 P1 Step 6 — the inline session-status strip pinned above the chat.
// Surfaces the subset of crew_sessions fields that excludes full logs /
// file tree (those live in PendingCrew): task brief, status badge,
// progress summary, runner. Tapping opens that session in PendingCrew via
// the existing deep-link path. No live status in P1 (poll only).
struct CrewSessionStrip: View {
    let sessions: [CrewSessionRow]
    let crewId: String

    var body: some View {
        if !sessions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sessions) { session in
                        CrewSessionStatusCard(session: session, crewId: crewId)
                    }
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.vertical, 8)
            }
            .background(Theme.Palette.canvas)
        }
    }
}

struct CrewSessionStatusCard: View {
    let session: CrewSessionRow
    let crewId: String

    @State private var showShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusBadge
                Spacer(minLength: 4)
                Button { showShare = true } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在 PendingCrew 中打开会话")
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let progress = session.progress_summary, !progress.isEmpty {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let runner = session.runner_kind {
                Label(CrewSessionIndex.runnerLabel(runner), systemImage: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .sheet(isPresented: $showShare) {
            CrewDeepLinkShareSheet(url: sessionDeepLink)
        }
    }

    private var title: String {
        session.task_brief?.isEmpty == false ? session.task_brief! : "未命名会话"
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor.opacity(0.16)))
            .foregroundStyle(statusColor)
    }

    private var statusLabel: String {
        switch session.status {
        case "running":  return "运行中"
        case "idle":     return "空闲"
        case "paused":   return "已暂停"
        case "finished": return "已结束"
        case "failed":   return "失败"
        default:         return session.status
        }
    }

    private var statusColor: Color {
        switch session.status {
        case "running":  return .green
        case "paused":   return .orange
        case "failed":   return .red
        case "finished": return .secondary
        default:         return .blue
        }
    }

    /// `pendingcrew://crew/<crew-id>/session/<session-id>` (spec v2 §11.3).
    private var sessionDeepLink: URL {
        URL(string: "pendingcrew://crew/\(crewId)/session/\(session.id)")!
    }
}

/// Shared UIActivityViewController bridge for crew/session deep-link share.
struct CrewDeepLinkShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}
