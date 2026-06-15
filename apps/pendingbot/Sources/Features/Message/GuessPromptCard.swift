import SwiftUI

// Model Blind Box (Task 9.1) — inline timeline card for the
// `prompt_model_guess` tool's `role='log'`, `log_kind='guess_prompt'`
// row. Sibling to PermissionRequestCard: rendered instead of a bubble
// for that log message id. Unlike that one, it carries no per-row
// payload — the reveal state comes from the conv-level
// `convModelState`, so the card just takes flattened props.
struct GuessPromptCard: View {
    let revealed: Bool
    let revealedName: String?
    var onTapGuess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(revealed ? "已揭晓" : "🎁 猜猜我背后是哪个模型?")
                .font(Theme.Fonts.rounded(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            if revealed, let name = revealedName {
                Text(name).foregroundStyle(Theme.Palette.accent)
            } else if !revealed {
                Button(action: onTapGuess) { Text("来猜一猜") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Palette.surfaceMuted))
        .padding(.horizontal)
    }
}
