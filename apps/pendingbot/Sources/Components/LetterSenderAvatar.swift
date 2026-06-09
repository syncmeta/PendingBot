import SwiftUI

/// Avatar for a 来信 byline. The preset 「读我」letter (trigger='example')
/// is attributed to the app itself — the brand mark in a circle. Every
/// other row falls back to the deterministic BotAvatar glyph, seeded by
/// bot_id (kind='bot') or author_user_id (kind='human').
struct LetterSenderAvatar: View {
    let run: EnvelopeRun
    var size: CGFloat = 36

    var body: some View {
        if run.isPreset {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
        } else {
            BotAvatar(seed: run.bot_id ?? run.author_user_id ?? run.id, size: size)
        }
    }
}
