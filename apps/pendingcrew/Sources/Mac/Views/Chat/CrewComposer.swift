#if os(macOS)
import SwiftUI

/// 中栏底部输入条：胶囊 TextField + 圆形发送钮。对齐 PendingBot iOS Composer。
struct CrewComposer: View {
    @Binding var draft: String
    let sending: Bool
    let errorText: String?
    let onSend: () -> Void

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            if let errorText {
                Text(errorText).font(CrewTheme.Fonts.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("发消息…（不 @ = 广播给所有 session）", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CrewTheme.Fonts.body)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(CrewTheme.Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
                    .onSubmit(onSend)

                Button(action: onSend) {
                    ZStack {
                        Circle().fill(canSend ? CrewTheme.Palette.accent : CrewTheme.Palette.surfaceMuted)
                            .frame(width: 30, height: 30)
                        if sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canSend ? .white : CrewTheme.Palette.inkMuted)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(CrewTheme.Palette.canvas)
    }
}
#endif
