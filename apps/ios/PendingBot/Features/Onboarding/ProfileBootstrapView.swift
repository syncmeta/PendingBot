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
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                Text("许多人懒得取名字、选头像，\n所以给你随机生成了")
                    .font(Theme.Fonts.serif(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.center)
                Text("不满意可以现在改，以后随时也能改。")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                VStack(spacing: 18) {
                    Button {
                        avatarSeed = UUID().uuidString
                        Haptics.tap()
                    } label: {
                        BotAvatar(seed: avatarSeed, size: 120)
                    }
                    .buttonStyle(.plain)
                    Text("点头像换一个")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("名字", text: $name)
                            .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                            .multilineTextAlignment(.center)
                            .submitLabel(.done)
                        Button {
                            name = NameCorpus.shared.random()
                            Haptics.tap()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.Palette.accent)
                                .padding(10)
                                .background(Circle().fill(Theme.Palette.accentBg))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                    )
                    Text("点 ↻ 换一个名字（来自城市 / 街区 / 地点列表）")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }

                if let error {
                    Text(error)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.white) }
                        Text(saving ? "保存中" : "确定")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(canSave
                        ? Theme.Palette.accent
                        : Theme.Palette.accent.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)

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
