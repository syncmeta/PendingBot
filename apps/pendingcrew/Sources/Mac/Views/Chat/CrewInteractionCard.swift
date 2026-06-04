#if os(macOS)
import SwiftUI

/// ask_human 交互卡（payload.kind == "interaction"）。操作者就地答。
struct CrewInteractionCard: View {
    let entry: CrewWhiteboardEntry
    @Binding var reply: String
    let onAnswer: () -> Void

    private var reqId: String? { entry.payload?.permissionRequestId }
    private var pending: Bool { (entry.payload?.status ?? "pending") == "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent 在问你", systemImage: "person.fill.questionmark")
                .font(CrewTheme.Fonts.caption.weight(.semibold))
                .foregroundStyle(CrewTheme.Palette.amber)
            Text(entry.payload?.question ?? entry.displayText)
                .font(CrewTheme.Fonts.callout)
                .foregroundStyle(CrewTheme.Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if pending, reqId != nil {
                HStack(spacing: 8) {
                    TextField("回答…", text: $reply, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit(onAnswer)
                    Button("回答", action: onAnswer)
                        .buttonStyle(.borderedProminent)
                        .tint(CrewTheme.Palette.accent)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if !pending {
                Text("已回答").font(CrewTheme.Fonts.caption).foregroundStyle(CrewTheme.Palette.inkMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CrewTheme.Metrics.cardRadius, style: .continuous)
            .fill(CrewTheme.Palette.amberBg.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: CrewTheme.Metrics.cardRadius, style: .continuous)
            .strokeBorder(CrewTheme.Palette.amber.opacity(0.30), lineWidth: 0.5))
        .padding(.horizontal, CrewTheme.Metrics.gutter)
        .padding(.vertical, 4)
    }
}
#endif
