import SwiftUI

/// Single-account view (multi-account is gone with Supabase Auth — one Apple
/// ID per device). Shows the current user + a sign-out button. Surfaced from
/// MeTabView's "账户" entry.
struct AccountsView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var confirmingSignOut = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let current = store.current {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(Theme.Fonts.glyph(size: 28))
                            .foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.displayName)
                                .font(Theme.Fonts.rounded(size: 16, weight: .medium))
                            if let email = current.email {
                                Text(email)
                                    .font(Theme.Fonts.monoSmall)
                                    .foregroundStyle(Theme.Palette.inkMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )

                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Text("退出登录")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("账户")
        .confirmationDialog(
            "退出当前账户？",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task {
                    await store.signOut()
                    Haptics.success()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}
