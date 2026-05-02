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
    /// True when launched from the profile sub-page (re-roll mode) — adds
    /// a back chevron and lets the user bail without committing. Default
    /// false for first-launch flow where committing is required.
    var allowsBack: Bool = false

    @State private var name: String = ""
    @State private var avatarSeed: String = UUID().uuidString
    @State private var nextName: String = ""
    @State private var nextAvatarSeed: String = UUID().uuidString
    @State private var dragOffset: CGFloat = 0
    @State private var animating = false
    @State private var saving = false
    @State private var editing = false
    @State private var error: String?

    private let cardWidthFraction: CGFloat = 0.78
    private let cardGap: CGFloat = 14

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer(minLength: 0)

                // Stack copy + card + caption tightly so they read as one
                // unit centered around the swipe affordance.
                VStack(alignment: .leading, spacing: 14) {
                    headerCopy
                    cardCarousel
                    swipeCaption
                    if let error {
                        Text(error)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(.red)
                    }
                    customizeRow
                }

                Spacer(minLength: 0)
                confirmRow
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            if name.isEmpty { name = NameCorpus.shared.random() }
            if nextName.isEmpty { nextName = NameCorpus.shared.random() }
        }
        .sheet(isPresented: $editing) {
            CustomizeSheet(
                name: $name,
                avatarSeed: $avatarSeed
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // ── Pieces ─────────────────────────────────────────────────────────

    @ViewBuilder
    private var topBar: some View {
        HStack {
            if allowsBack {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(height: 32)
        .padding(.top, 4)
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("许多人懒得取名字、选头像，\n所以给你随机生成了")
                .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("不满意可以现在改，以后随时也能改。")
                .font(Theme.Fonts.serif(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardCarousel: some View {
        // Card carousel: current card centered with a peek of the
        // pre-rolled "next" card on the right. Swiping left commits —
        // current slides off, next becomes current, and we pre-roll a
        // fresh next behind it.
        GeometryReader { geo in
            let cardWidth = geo.size.width * cardWidthFraction
            ZStack(alignment: .leading) {
                // Next card (peek on the right of current).
                nameCardView(seed: nextAvatarSeed, name: nextName)
                    .frame(width: cardWidth)
                    .scaleEffect(0.95)
                    .opacity(0.6)
                    .offset(x: cardWidth + cardGap + dragOffset)

                // Current card.
                nameCardView(seed: avatarSeed, name: name)
                    .frame(width: cardWidth)
                    .offset(x: dragOffset)
                    .gesture(swipeGesture(cardWidth: cardWidth))
            }
            .frame(width: geo.size.width, alignment: .leading)
        }
        .frame(height: 200)
    }

    private var swipeCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("向左滑换一组。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
            Text("名字是随机从中国地名里选的。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customizeRow: some View {
        Button {
            editing = true
            Haptics.tap()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                Text("自己填一个 / 换头像")
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.Palette.accentBg))
        }
        .buttonStyle(.plain)
    }

    private var confirmRow: some View {
        // Confirm button: small circular "next" arrow, accentBg
        // (same palette as the bot-name capsule on the message list).
        // Right-aligned because the action is forward.
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
    }

    /// One name card — avatar on the left, name on the right with extra
    /// breathing room between them. Used for both the front (current)
    /// and back (peek) cards.
    private func nameCardView(seed: String, name: String) -> some View {
        HStack(spacing: 28) {
            BotAvatar(seed: seed, size: 76)
            Text(name.isEmpty ? "—" : name)
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // ── Drag mechanics ──────────────────────────────────────────────────

    /// Returns the mid-drag offset given a raw translation. Mimics
    /// iOS-native scroll feel: the first ~30% feels 1:1; past the card
    /// width it gets progressively heavier (rubber-band) so flicking
    /// without enough distance still snaps back.
    private func rubberBand(_ translation: CGFloat, cardWidth: CGFloat) -> CGFloat {
        let raw = min(0, translation)
        let absT = -raw
        if absT <= cardWidth * 0.6 { return raw }
        let extra = absT - cardWidth * 0.6
        let damped = cardWidth * 0.6 + (cardWidth * 0.4) * (1 - exp(-extra / (cardWidth * 0.6)))
        return -damped
    }

    private func swipeGesture(cardWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { v in
                guard !animating else { return }
                dragOffset = rubberBand(v.translation.width, cardWidth: cardWidth)
            }
            .onEnded { v in
                guard !animating else { return }
                let threshold = cardWidth * 0.30
                let velocity = v.predictedEndTranslation.width - v.translation.width
                let shouldCommit =
                    v.translation.width < -threshold ||
                    (v.translation.width < -16 && velocity < -200)
                if shouldCommit {
                    advance(cardWidth: cardWidth)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// Commit the swipe: slide the current card all the way off, then in
    /// the same animation step swap state and slide it back to centre.
    /// Doing the swap inside `withAnimation(.linear(duration: 0))` would
    /// snap visibly — instead we wait for the slide to finish, swap, and
    /// reset the offset inside a Transaction with animations disabled so
    /// the (now current) card simply IS at zero, no jump frame.
    private func advance(cardWidth: CGFloat) {
        guard !animating else { return }
        animating = true
        Haptics.tap()
        let target = -(cardWidth + cardGap + 80)
        withAnimation(.easeOut(duration: 0.28)) {
            dragOffset = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            // Disable implicit animation while we re-centre the card —
            // otherwise SwiftUI tweens dragOffset from `target` back to 0
            // and the user sees the (already-swapped) card flying in
            // from the left.
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                avatarSeed = nextAvatarSeed
                name = nextName
                nextAvatarSeed = UUID().uuidString
                nextName = NameCorpus.shared.random()
                dragOffset = 0
            }
            animating = false
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

// MARK: - Customize sheet

/// Manual edit: type a name + reroll the avatar seed if you want a
/// different glyph/color than the random pair gave you.
private struct CustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @Binding var avatarSeed: String

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                VStack(spacing: 22) {
                    Spacer(minLength: 12)

                    Button {
                        avatarSeed = UUID().uuidString
                        Haptics.tap()
                    } label: {
                        VStack(spacing: 6) {
                            BotAvatar(seed: avatarSeed, size: 96)
                            Text("点头像换一个")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("昵称")
                            .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Palette.inkMuted)
                        TextField("起一个吧", text: $name)
                            .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.Palette.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 22)

                    Spacer()
                }
            }
            .navigationTitle("自定义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
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
