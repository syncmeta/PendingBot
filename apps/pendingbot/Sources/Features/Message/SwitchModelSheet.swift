import SwiftUI

/// 盲盒「换模型」sheet。复用 `ModelPickerSheet`(它自带 NavigationStack + 「取消」)
/// 让用户挑一个具体模型(mode:specific),conv 有模型池时底部再压一条「随机换一个」
/// (mode:random)。两种都 POST `/v1/conversations/:id/model`,成功后调 `onSwitched`
/// 让宿主刷新 conv 模型状态再关闭 sheet。
///
/// 注意:不在外面再套一层 NavigationStack —— `ModelPickerSheet` 已经自带一层,
/// 嵌套会叠出两条导航栏。额外的「随机」动作走 `.safeAreaInset` 底栏。
struct SwitchModelSheet: View {
    let conversationId: String
    let hasPool: Bool
    var onSwitched: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        ModelPickerSheet(initial: "", showLegend: false, onPick: { picked in
            guard let p = picked else { return }
            Task { await call(SpecificBody(mode: "specific", slug: p.slug, provider: p.model_provider)) }
        })
        .safeAreaInset(edge: .bottom) {
            if hasPool { randomBar }
        }
        .tint(Theme.Palette.accent)
    }

    private var randomBar: some View {
        Button {
            Task { await call(RandomBody(mode: "random")) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shuffle")
                Text("随机换一个")
            }
            .font(Theme.Fonts.rounded(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(busy ? Theme.Palette.inkMuted : Theme.Palette.accent)
        .disabled(busy)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(Theme.Palette.hairline),
            alignment: .top
        )
    }

    private struct SpecificBody: Encodable { let mode: String; let slug: String; let provider: String? }
    private struct RandomBody: Encodable { let mode: String }
    private struct SwitchResult: Decodable {
        let current_model_slug: String?
        let current_model_provider: String?
        let model_revealed: Bool
    }

    private func call<B: Encodable>(_ body: B) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let _: SwitchResult = try await APIClient()
                .post("v1/conversations/\(conversationId)/model", body: body)
            await MainActor.run {
                onSwitched()
                dismiss()
            }
            await Haptics.success()
        } catch {
            await Haptics.error()
        }
    }
}
