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
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 20)

                VStack(alignment: .leading, spacing: 8) {
                    Text("许多人懒得取名字、选头像，\n所以给你随机生成了")
                        .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("不满意可以现在改，以后随时也能改。")
                        .font(Theme.Fonts.serif(size: 14, weight: .regular))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                // Name card — avatar + name on a raised surface so it
                // visually reads as the artefact you'll keep.
                VStack(spacing: 14) {
                    Button {
                        // .transition + withAnimation drives the cross-fade
                        // when the seed (and therefore the BotAvatar) flips.
                        withAnimation(.easeInOut(duration: 0.25)) {
                            avatarSeed = UUID().uuidString
                        }
                        Haptics.tap()
                    } label: {
                        BotAvatar(seed: avatarSeed, size: 120)
                            .id(avatarSeed)
                            .transition(.opacity)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Text(name.isEmpty ? "—" : name)
                            .font(Theme.Fonts.serif(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(1)
                            .id(name)
                            .transition(.opacity)
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                name = NameCorpus.shared.random()
                            }
                            Haptics.tap()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.accent)
                                .padding(8)
                                .background(Circle().fill(Theme.Palette.accentBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)

                Text("点头像或 ↻ 换一组（地名来自全国城市 / 街区 / 地点）")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
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
