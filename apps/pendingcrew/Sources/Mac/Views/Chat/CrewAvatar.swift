#if os(macOS)
import SwiftUI

/// 30pt 圆形头像。三种作者：
/// - bot → CrewColorHash 柔色底 + emoji；captain 加星标角标
/// - session → 终端字形(绿系)，可挂运行状态点
/// - human → 柔色底 + 首字
struct CrewAvatar: View {
    let sender: CrewSender
    var size: CGFloat = Theme.Metrics.avatar

    var body: some View {
        ZStack {
            base
            if sender.isCaptain {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.30, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(1.5)
                    .background(Circle().fill(Theme.Palette.surface))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
            if let status = sender.sessionStatus {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().strokeBorder(Theme.Palette.surface, lineWidth: 1.5))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var base: some View {
        switch sender.kind {
        case .bot:
            Circle().fill(CrewColorHash.softBackground(for: sender.avatarSeed))
                .overlay(Text(CrewColorHash.emoji(for: sender.avatarSeed)).font(.system(size: size * 0.55)))
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        case .human:
            Circle().fill(CrewColorHash.softBackground(for: sender.avatarSeed))
                .overlay(Text(CrewColorHash.initial(for: sender.displayName))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.8)))
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        case .session:
            Circle().fill(Color(hue: 0.38, saturation: 0.22, brightness: 0.93))
                .overlay(Image(systemName: "terminal.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Color(hue: 0.38, saturation: 0.6, brightness: 0.5)))
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "running": return .green
        case "queued":  return .yellow
        default:        return .gray
        }
    }
}
#endif
