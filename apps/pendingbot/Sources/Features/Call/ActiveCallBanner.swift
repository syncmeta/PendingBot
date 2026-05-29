#if os(iOS)
import SwiftUI

/// Slim "通话中" pill that ConversationView pins above the messages list
/// when a group voice call is live. Layout (left → right):
///   phone-icon · MM:SS elapsed · "N 人"
/// Tapping it triggers the supplied action — typically rejoining /
/// opening the call view.
struct ActiveCallBanner: View {
    let snapshot: ActiveVoiceCallStore.Snapshot
    let onTap: () -> Void

    /// Drives the live MM:SS — SwiftUI redraws on each tick because of
    /// the @State reference. Cheap (one Text view).
    @State private var now = Date()

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill")
                    .font(Theme.Fonts.glyph(size: 14, weight: .semibold))
                Text(elapsed)
                    .monospacedDigit()
                    .font(Theme.Fonts.subheadline.weight(.medium))
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("\(snapshot.participantCount) 人")
                    .font(Theme.Fonts.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.glyph(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.95))
        }
        .buttonStyle(.plain)
        .onAppear {
            now = Date()
        }
        .task(id: snapshot.conversationId) {
            // Tick once a second while the banner is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
    }

    private var elapsed: String {
        let secs = max(0, Int(now.timeIntervalSince(snapshot.startedAt)))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}
#endif
