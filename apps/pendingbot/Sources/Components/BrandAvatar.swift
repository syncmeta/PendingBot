import SwiftUI

/// Cross-platform soft-pastel emoji avatar — shares `ColorHash` with iOS's
/// `BotAvatar` so the emoji glyph + tint match iOS exactly for a given seed,
/// but without the iOS-only `Theme` font/palette dependencies (uses system
/// font + a hex hairline). Used by the macOS 消息/好友 lists + chat bubbles to
/// align visually with iOS.
struct BrandAvatar: View {
    let emojiSeed: String
    let colorSeed: String
    var size: CGFloat = 36

    init(seed: String, size: CGFloat = 36) {
        self.emojiSeed = seed
        self.colorSeed = seed
        self.size = size
    }

    init(emojiSeed: String, colorSeed: String, size: CGFloat = 36) {
        self.emojiSeed = emojiSeed
        self.colorSeed = colorSeed
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle().fill(ColorHash.softBackground(for: colorSeed))
            Text(ColorHash.emoji(for: emojiSeed))
                .font(.system(size: size * 0.55))
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
    }
}
