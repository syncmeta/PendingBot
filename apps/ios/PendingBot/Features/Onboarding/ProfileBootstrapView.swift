import SwiftUI

/// Random-name + random-avatar onboarding step. Shown right after first
/// sign-in (when the user hasn't set a profile yet) and re-openable from
/// the profile sub-page.
///
/// Both name and avatar are picked client-side from a bundled corpus,
/// so the user can roll repeatedly without making API calls. We only
/// hit Supabase when they tap 确定.
struct ProfileBootstrapView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore
    var onDone: (() -> Void)?

    @State private var name: String = ""
    @State private var avatarSeed: String = UUID().uuidString
    @State private var nextName: String = ""
    @State private var nextAvatarSeed: String = UUID().uuidString
    @State private var dragOffset: CGFloat = 0
    @State private var saving = false
    @State private var error: String?

    /// Card width as a fraction of total horizontal space — leaves a
    /// vertical sliver of the next card visible on the right.
    private let cardWidthFraction: CGFloat = 0.78
    private let cardGap: CGFloat = 14

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("许多人懒得取名字、选头像，\n所以给你随机生成了")
                        .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("不满意可以现在改，以后随时也能改。")
                        .font(Theme.Fonts.serif(size: 14, weight: .regular))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                // Card carousel: current card centered with a peek of the
                // pre-rolled "next" card on the right. Swiping left
                // commits — current slides off, next becomes current,
                // and we pre-roll a fresh next behind it.
                GeometryReader { geo in
                    let cardWidth = geo.size.width * cardWidthFraction
                    ZStack(alignment: .leading) {
                        // Next card (peeking on the right of current).
                        nameCardView(seed: nextAvatarSeed, name: nextName)
                            .frame(width: cardWidth)
                            .scaleEffect(0.95)
                            .opacity(0.6)
                            .offset(x: cardWidth + cardGap + dragOffset)

                        // Current card.
                        nameCardView(seed: avatarSeed, name: name)
                            .frame(width: cardWidth)
                            .offset(x: dragOffset)
                            .gesture(
                                DragGesture()
                                    .onChanged { v in
                                        dragOffset = min(0, v.translation.width)
                                    }
                                    .onEnded { v in
                                        let threshold = cardWidth * 0.25
                                        if v.translation.width < -threshold {
                                            advance(cardWidth: cardWidth)
                                        } else {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                dragOffset = 0
                                            }
                                        }
                                    }
                            )
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                }
                .frame(height: 220)

                VStack(alignment: .leading, spacing: 4) {
                    Text("向左滑换一组。")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Text("名字是随机从中国地名里选的。")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let error {
                    Text(error)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                // Confirm button: small circular "next" arrow, accentBg
                // (same palette as the bot-name capsule on the message
                // list). Right-aligned because the action is forward.
                HStack {
                    Spacer()
                    Button {
                        Task { await save() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(canSave
                                    ? Theme.Palette.accentBg
                                    : Theme.Palette.accentBg.opacity(0.5))
                                .frame(width: 56, height: 56)
                            if saving {
                                ProgressView().tint(Theme.Palette.accent)
                            } else {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(canSave
                                        ? Theme.Palette.accent
                                        : Theme.Palette.accent.opacity(0.5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            if name.isEmpty { name = NameCorpus.shared.random() }
            if nextName.isEmpty { nextName = NameCorpus.shared.random() }
        }
    }

    /// One name card — avatar on the left, name on the right. Used for
    /// both the front (current) and back (peek) cards in the carousel.
    private func nameCardView(seed: String, name: String) -> some View {
        HStack(spacing: 14) {
            BotAvatar(seed: seed, size: 80)
            Text(name.isEmpty ? "—" : name)
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    /// Commit the swipe: animate current card off-screen left, then
    /// promote the pre-rolled next card to current and pre-roll a new
    /// "next" behind it. The reset of dragOffset must happen WITHOUT
    /// animation so the (now-current) card jumps back to centre.
    private func advance(cardWidth: CGFloat) {
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = -(cardWidth + cardGap + 40)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            avatarSeed = nextAvatarSeed
            name = nextName
            nextAvatarSeed = UUID().uuidString
            nextName = NameCorpus.shared.random()
            dragOffset = 0
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    private func save() async {
        guard let userId = store.current?.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true; defer { saving = false }
        struct Patch: Encodable {
            let display_name: String
            let custom_fields: [String: String]
        }
        do {
            try await SupabaseStack.shared.database
                .from("users")
                .update(Patch(display_name: trimmed,
                              custom_fields: [
                                "avatar_seed": avatarSeed,
                                "bootstrapped": "1",
                              ]))
                .eq("id", value: userId)
                .execute()
            // Reflect into the published store so RootView swaps to TabRoot
            // immediately, no app-restart required.
            store.markBootstrapped(displayName: trimmed, avatarSeed: avatarSeed)
            Haptics.success()
            onDone?()
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}

/// Lazy-loaded names corpus from Resources/names.txt. One name per line.
final class NameCorpus {
    static let shared = NameCorpus()
    private let names: [String]
    private init() {
        if let url = Bundle.main.url(forResource: "names", withExtension: "txt"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            self.names = raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            self.names = ["你"]
        }
    }
    func random() -> String {
        names.randomElement() ?? "你"
    }
}
