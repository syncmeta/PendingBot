import SwiftUI

/// 我 — left-aligned header column (avatar / name / email, no card
/// background) plus a native-style settings list. Tapping the header
/// pushes into `ProfileBootstrapView` (the random-roll 头像 / 用户名
/// 生成 page) so avatar + nickname share one editing surface.
struct MeTabView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.useSidebarLayout) private var sidebarLayout
    @Environment(\.topTabSelection) private var topTabSelection

    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var error: String?
    @State private var showRandomize = false

    var body: some View {
        Group {
            if sidebarLayout {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        coreContent
                        if let topTabSelection {
                            SidebarTabBar(selection: topTabSelection)
                        }
                    }
                    .sidebarColumnWidth()
                } detail: {
                    EmptyDetailHint(text: "在左侧选项里走走", systemImage: "person.crop.circle")
                }
            } else {
                coreContent
            }
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

    @ViewBuilder
    private var coreContent: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                List {
                    Section {
                        profileHeader
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
                            .listRowSeparator(.hidden)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showRandomize = true
                                Haptics.tap()
                            }
                    }

                    Section {
                        NavigationLink {
                            AddMeMethodsView().toolbar(.hidden, for: .tabBar)
                        } label: {
                            Text("加我为好友的方式")
                        }
                        NavigationLink {
                            SkillsView().toolbar(.hidden, for: .tabBar)
                        } label: {
                            Text("技能管理")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            confirmingSignOut = true
                            Haptics.tap()
                        } label: {
                            Text("退出登录")
                        }
                        .disabled(store.current == nil)
                    }

                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                            Haptics.tap()
                        } label: {
                            Text(deleting ? "正在删除…" : "注销账号")
                        }
                        .disabled(deleting || store.current == nil)
                    } footer: {
                        Text("很多功能还没做好 不可用")
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // ── Header ─────────────────────────────────────────────────────────────

    /// Avatar / nickname / email stacked vertically, leading-aligned, on
    /// the canvas (no surface card). The whole column is one tap target
    /// → ProfileBootstrapView.
    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            let seed = store.avatarSeed ?? store.current?.id ?? "?"
            UserAvatar(
                seed: seed,
                attachmentId: store.avatarAttachmentId,
                size: 64
            )
            Text(displayLabel)
                .font(Theme.Fonts.serif(size: 22, weight: .semibold))
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
