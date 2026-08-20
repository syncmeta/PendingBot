import SwiftUI

/// Default avatar for group conversations: white disc with a gray
/// hairline border and a small cluster of emoji glyphs inside.
///
/// The emoji set is picked deterministically from `seed` so the same
/// group always renders the same face across launches — "random-looking"
/// without being unstable. Three glyphs are arranged in a triangle so
/// the avatar reads as "many people" at a glance, distinct from the
/// single-emoji `BotAvatar` used by 1v1 conversations.
struct GroupAvatar: View {
    let seed: String
    var size: CGFloat = 36

    /// Same curated list as `ColorHash.emoji` so the visual language
    /// stays consistent. Duplicated here to keep `ColorHash` private to
    /// its single-emoji use case.
    private static let glyphs: [String] = [
        "🦊", "🐼", "🐯", "🦁", "🐸", "🐧", "🐳", "🐙",
        "🦉", "🦄", "🐝", "🦋", "🐢", "🐬", "🦒", "🦔",
        "🌵", "🌻", "🌸", "🌙", "⭐", "🔥", "🍄", "🍀",
        "🍓", "🍑", "🍋", "🍇", "🥑", "🌽", "🥨", "🍪",
        "🎈", "🎨", "🎭", "🎪", "🎲", "🧩", "🪁", "🪐",
        "🚀", "⛵", "🏕", "🪴", "🪨", "💎", "🧊", "🦤",
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.Palette.surface)
                .overlay(
                    Circle().strokeBorder(
                        Theme.Palette.hairline.opacity(1),
                        lineWidth: max(0.5, size * 0.025),
                    )
                )

            let chosen = pickGlyphs(seed: seed)
            // Equilateral-triangle layout so it reads as a small group.
            // Radius ≈ 18 % of the avatar; glyph font ≈ 32 % so they
            // touch comfortably without overlapping.
            let r = size * 0.18
            let glyphSize = size * 0.32
            let offsets: [(CGFloat, CGFloat)] = [
                (0, -r),
                (-r * 0.866, r * 0.5),
                (r * 0.866, r * 0.5),
            ]
            ForEach(0..<3, id: \.self) { i in
                Text(chosen[i])
                    .font(Theme.Fonts.glyph(size: glyphSize))
                    .offset(x: offsets[i].0, y: offsets[i].1)
            }
        }
        .frame(width: size, height: size)
    }

    /// Deterministic three-emoji pick, guaranteed distinct.
    private func pickGlyphs(seed: String) -> [String] {
        var h: UInt64 = 1469598103934665603 // FNV-1a offset
        for s in seed.unicodeScalars {
            h ^= UInt64(s.value)
            h = h &* 1099511628211
        }
        var picked: [String] = []
        var cursor = h
        let n = UInt64(Self.glyphs.count)
        while picked.count < 3 {
            let idx = Int(cursor % n)
            let g = Self.glyphs[idx]
            if !picked.contains(g) { picked.append(g) }
            cursor = cursor &* 6364136223846793005 &+ 1442695040888963407
        }
        return picked
    }
}
