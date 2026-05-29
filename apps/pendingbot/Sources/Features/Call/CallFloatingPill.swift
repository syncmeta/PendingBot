#if os(iOS)
import SwiftUI

/// Compact pill that sits above the tab bar while a call is minimized.
///
/// Two halves separated by a hairline divider:
///   * left — tappable area showing avatar + status / elapsed time;
///     tapping it re-expands the full-screen surface
///   * right — small red phone-down button that hangs up the call
///     without going through the full-screen surface
///
/// Driven by `CallCenter`: when `isMinimized` is true and exactly one
/// of `voiceCall` / `groupCall` is non-nil, the pill renders; otherwise
/// the parent collapses it to `EmptyView`. The elapsed-time digit
/// updates via a 1Hz `TimelineView` rather than a manual `Timer`, so
/// the pill and the full-screen view stay perfectly in sync without
/// any shared state on the session.
struct CallFloatingPill: View {
    let center: CallCenter

    var body: some View {
        if let session = center.voiceCall, center.isMinimized {
            voicePill(session: session)
        } else if let session = center.groupCall, center.isMinimized {
            groupPill(session: session)
        }
    }

    // MARK: - 1:1 voice

    private func voicePill(session: CallSession) -> some View {
        pillContainer(
            avatar: AnyView(
                BotAvatar(
                    emojiSeed: session.botId,
                    colorSeed: session.conversationId,
                    size: 32,
                ),
            ),
            title: session.botDisplayName,
            connectedAt: session.connectedAt,
            statusFallback: voiceStatusText(session.phase),
            onExpand: { center.expand() },
            onHangUp: {
                Task {
                    await session.hangUp()
                }
            },
        )
    }

    private func voiceStatusText(_ phase: CallSession.Phase) -> String {
        switch phase {
        case .idle, .connecting: return "正在呼叫…"
        case .connected:         return "通话中"
        case .hangingUp:         return "结束中…"
        case .terminated:        return "已结束"
        }
    }

    // MARK: - Group

    private func groupPill(session: GroupCallSession) -> some View {
        pillContainer(
            avatar: AnyView(
                ZStack {
                    Circle()
                        .fill(Theme.Palette.accentBg)
                        .frame(width: 32, height: 32)
                    Image(systemName: "person.3.fill")
                        .font(Theme.Fonts.glyph(size: 14))
                        .foregroundStyle(Theme.Palette.accent)
                },
            ),
            title: session.groupTitle.isEmpty ? "群语音" : session.groupTitle,
            connectedAt: session.connectedAt,
            statusFallback: groupStatusText(session.phase),
            onExpand: { center.expand() },
            onHangUp: {
                Task {
                    await session.hangUp()
                }
            },
        )
    }

    private func groupStatusText(_ phase: GroupCallSession.Phase) -> String {
        switch phase {
        case .idle, .connecting: return "接通中"
        case .connected:         return "通话中"
        case .hangingUp:         return "结束中…"
        case .terminated:        return "已结束"
        }
    }

    // MARK: - Layout

    private func pillContainer(
        avatar: AnyView,
        title: String,
        connectedAt: Date?,
        statusFallback: String,
        onExpand: @escaping () -> Void,
        onHangUp: @escaping () -> Void,
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                Haptics.tap()
                onExpand()
            }) {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(Theme.Fonts.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        elapsedLabel(
                            connectedAt: connectedAt,
                            fallback: statusFallback,
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 28)

            Button(action: {
                Haptics.tap()
                onHangUp()
            }) {
                Image(systemName: "phone.down.fill")
                    .font(Theme.Fonts.glyph(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.red))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("挂断")
        }
        .background(
            Capsule()
                .fill(Theme.Palette.surface)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4),
        )
        .overlay(
            Capsule()
                .stroke(Theme.Palette.hairline, lineWidth: 0.5),
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Renders `mm:ss` once the call has connected, otherwise shows the
    /// status copy ("正在呼叫…" / "接通中"). `TimelineView` ticks the
    /// inner body once a second so the digits update without any
    /// manual state on the parent.
    @ViewBuilder
    private func elapsedLabel(connectedAt: Date?, fallback: String) -> some View {
        if let start = connectedAt {
            TimelineView(.periodic(from: start, by: 1.0)) { ctx in
                Text(format(elapsed: ctx.date.timeIntervalSince(start)))
                    .font(Theme.Fonts.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(fallback)
                .font(Theme.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func format(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
#endif
