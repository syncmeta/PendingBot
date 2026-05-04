import SwiftUI

/// 我 — borderless header (avatar / name / email) plus a friend-list-style
/// row stack. Tapping the header pushes into `ProfileBootstrapView` (the
/// random-roll 头像 / 用户名生成 page) so avatar + nickname share one
/// editing surface.
struct MeTabView: View {
    @EnvironmentObject private var store: AccountStore

    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var error: String?
    @State private var showHandles = false
    @State private var showQR = false
    @State private var showRandomize = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                List {
                    Section {
                        profileHeader
                            .listRowBackground(Theme.Palette.surface)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showRandomize = true
                                Haptics.tap()
                            }
                    }

                    Section {
                        Button {
                            showHandles = true
                            Haptics.tap()
                        } label: {
                            optionRow(icon: "number", label: "号码")
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.Palette.surface)

                        Button {
                            showQR = true
                            Haptics.tap()
                        } label: {
                            optionRow(icon: "qrcode", label: "二维码")
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.Palette.surface)

                        NavigationLink {
                            SkillsView().toolbar(.hidden, for: .tabBar)
                        } label: {
                            optionRow(icon: "puzzlepiece.extension", label: "技能")
                        }
                        .listRowBackground(Theme.Palette.surface)
                    }

                    Section {
                        Button {
                            confirmingSignOut = true
                            Haptics.tap()
                        } label: {
                            destructiveRow(
                                icon: "rectangle.portrait.and.arrow.right",
                                label: "退出登录"
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.Palette.surface)
                        .disabled(store.current == nil)

                        Button {
                            confirmingDelete = true
                            Haptics.tap()
                        } label: {
                            destructiveRow(
                                icon: "trash",
                                label: deleting ? "正在删除…" : "注销账号"
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.Palette.surface)
                        .disabled(deleting || store.current == nil)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showHandles) {
            MyHandlesSheet()
                .tint(Theme.Palette.accent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQR) {
            MyQRSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showRandomize) {
            ProfileBootstrapView(allowsBack: true)
                .environmentObject(AccountStore.shared)
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(
            "确定？",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) { signOut() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除你在服务器上的所有数据 就像你没来过一样 不可撤销 无法恢复 数据无价 谨慎操作",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { Task { await deleteAccount() } }
            Button("取消", role: .cancel) {}
        }
    }

    // ── Header ─────────────────────────────────────────────────────────────

    /// Avatar (left) + name / email column (right). The whole row is one
    /// tap target → ProfileBootstrapView. No border, no chevron — the
    /// row sits in the same surface as the option rows below it.
    private var profileHeader: some View {
        HStack(spacing: 14) {
            let seed = store.avatarSeed ?? store.current?.id ?? "?"
            UserAvatar(
                seed: seed,
                attachmentId: store.avatarAttachmentId,
                size: 56
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(displayLabel)
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let email = store.current?.email, !email.isEmpty {
                    Text(email)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var displayLabel: String {
        let ws = CharacterSet.whitespacesAndNewlines
        if let stored = store.profileDisplayName?.trimmingCharacters(in: ws),
           !stored.isEmpty {
            return stored
        }
        if let dn = store.current?.displayName.trimmingCharacters(in: ws),
           !dn.isEmpty {
            return dn
        }
        return "未命名"
    }

    // ── Option rows (friend-list style) ────────────────────────────────────

    /// Friend-list-style row: 36px tinted icon, serif 16-semibold label,
    /// trailing space (the List section already provides the chevron via
    /// NavigationLink, and tap-only rows skip it for a flatter look).
    private func optionRow(icon: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Palette.accentBg))
            Text(label)
                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func destructiveRow(icon: String, label: String) -> some View {
        let color = Color(hex: 0xB14B3C)
        return HStack(spacing: 12) {
            if deleting && icon == "trash" {
                ProgressView()
                    .tint(color)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(color.opacity(0.12)))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(color.opacity(0.12)))
            }
            Text(label)
                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // ── Actions ────────────────────────────────────────────────────────────

    private func signOut() {
        Task {
            await store.signOut()
            Haptics.success()
        }
    }

    private func deleteAccount() async {
        guard !deleting else { return }
        deleting = true; defer { deleting = false }
        do {
            try await SupabaseStack.shared
                .rpc("delete_self_account")
                .execute()
            await store.signOut()
            Haptics.success()
        } catch {
            self.error = "注销失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}
