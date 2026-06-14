import SwiftUI

/// 盲盒「猜模型」sheet。复用 `ModelPickerSheet`(它自带 NavigationStack + 「取消」)
/// 让用户从目录里挑一个 slug 当作猜测,底部再压一条「不想猜,直接揭晓」放弃条;两种
/// 情况都 POST reveal-model 并展示揭晓结果。`onRevealed` 让宿主(ConversationView)
/// 在揭晓后刷新 conv 模型状态,让 header pill 从 "PendingModel" 切到真实名字。
///
/// 注意:不在外面再套一层 NavigationStack —— `ModelPickerSheet` 已经自带一层,
/// 嵌套会叠出两条导航栏。额外的「放弃」动作走 `.safeAreaInset` 底栏。
struct GuessModelSheet: View {
    let conversationId: String
    var onRevealed: (RevealResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var submitting = false
    @State private var result: RevealResult?

    var body: some View {
        Group {
            if let result {
                resultView(result)
            } else {
                ModelPickerSheet(initial: "", showLegend: false, onPick: { picked in
                    guard let slug = picked?.slug else { return }
                    Task { await submit(guess: slug) }
                })
                .safeAreaInset(edge: .bottom) { giveUpBar }
            }
        }
        .tint(Theme.Palette.accent)
    }

    private var giveUpBar: some View {
        Button {
            Task { await submit(guess: nil) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                Text("不想猜,直接揭晓")
            }
            .font(Theme.Fonts.rounded(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(submitting ? Theme.Palette.inkMuted : Theme.Palette.accent)
        .disabled(submitting)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(Theme.Palette.hairline),
            alignment: .top
        )
    }

    @ViewBuilder private func resultView(_ r: RevealResult) -> some View {
        VStack(spacing: 16) {
            let actual = catalog.displayName(for: r.actual_slug)
            Text(resultHeadline(r, actual: actual))
                .font(Theme.Fonts.serif(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Button("好") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas)
    }

    private func resultHeadline(_ r: RevealResult, actual: String) -> String {
        switch r.correct {
        case .some(true):  return "🎉 猜对了!就是 \(actual)"
        case .some(false): return "差一点!实际是 \(actual)"
        case .none:        return "揭晓:\(actual)"
        }
    }

    private func submit(guess: String?) async {
        guard !submitting else { return }
        submitting = true; defer { submitting = false }
        struct Body: Encodable { let guess: String? }
        do {
            let r: RevealResult = try await APIClient()
                .post("v1/conversations/\(conversationId)/reveal-model", body: Body(guess: guess))
            await MainActor.run {
                self.result = r
                onRevealed(r)
            }
            await Haptics.success()
        } catch {
            await Haptics.error()
        }
    }
}
