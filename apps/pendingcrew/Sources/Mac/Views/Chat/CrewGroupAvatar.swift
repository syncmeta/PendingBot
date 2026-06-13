#if os(macOS)
import SwiftUI

/// crew 头像 —— 与 PendingBot 群聊头像（`GroupAvatar`）同构造：白底圆盘 +
/// 灰发丝边框 + 由 `seed` 确定性挑出的三个 emoji 摆成三角（读作"一群人"）。
///
/// 构造方法逐字对齐 PendingBot 的 `GroupAvatar`（同 glyph 表、同 FNV-1a 哈希、
/// 同三角布局），改用 PendingCrew 现已统一的 `Theme`(共享组件迁移后)。
/// seed 用 `crew.id`，对应 PendingBot 群聊用 `conversation.id`。
struct CrewGroupAvatar: View {
    let seed: String
    var size: CGFloat = 30

    /// 与 PendingBot `GroupAvatar.glyphs` 同一份表，保两端视觉语言一致。
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
                        Theme.Palette.hairline,
                        lineWidth: max(0.5, size * 0.025)
                    )
                )

            let chosen = pickGlyphs(seed: seed)
            let r = size * 0.18
            let glyphSize = size * 0.32
            let offsets: [(CGFloat, CGFloat)] = [
                (0, -r),
                (-r * 0.866, r * 0.5),
                (r * 0.866, r * 0.5),
            ]
            ForEach(0..<3, id: \.self) { i in
                Text(chosen[i])
                    .font(.system(size: glyphSize))
                    .offset(x: offsets[i].0, y: offsets[i].1)
            }
        }
        .frame(width: size, height: size)
    }

    /// 确定性挑三个不重复 emoji —— 与 PendingBot 同算法（FNV-1a + LCG）。
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
#endif
