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
    @State private var showDeleteSheet = false
    @State private var deleting = false
    @State private var error: String?
    @State private var showRandomize = false

    /// Two-way sentiment captured when finalizing account deletion. The
    /// outcome is the same — full account wipe — but recording which
    /// button the user picked tells us how people feel when they leave.
    enum DeletionSentiment: String {
        case seeYouAgain     = "see_you_again"     // "有缘再见"
        case farewellForever = "farewell_forever"  // "再也不见"
    }

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
        .alert("出错", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
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
            "不可撤销 想好再点",
            isPresented: $showDeleteSheet,
            titleVisibility: .visible
        ) {
            Button("去意已决，有缘再见", role: .destructive) {
                Task { await deleteAccount(sentiment: .seeYouAgain) }
            }
            Button("去意已决，再也不见", role: .destructive) {
                Task { await deleteAccount(sentiment: .farewellForever) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删所有数据，云端和本地都删。\n两个选项都能完全注销账号，我只是想知道你对我的态度。")
        }
    }

    @ViewBuilder
    private var coreContent: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        profileHeader
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showRandomize = true
                                Haptics.tap()
                            }

                        GroupedRowsCard {
                            NavigationLink {
                                AddMeMethodsView().toolbar(.hidden, for: .tabBar)
                            } label: {
                                GroupedRow(title: "加我为好友的方式")
                            }
                            .buttonStyle(.plain)

                            GroupedRowDivider()

                            NavigationLink {
                                WalletView().toolbar(.hidden, for: .tabBar)
                            } label: {
                                GroupedRow(title: "钱包")
                            }
                            .buttonStyle(.plain)

                            GroupedRowDivider()

                            NavigationLink {
                                SkillsView().toolbar(.hidden, for: .tabBar)
                            } label: {
                                GroupedRow(title: "技能管理")
                            }
                            .buttonStyle(.plain)
                        }

                        GroupedRowsCard {
                            Button {
                                confirmingSignOut = true
                                Haptics.tap()
                            } label: {
                                GroupedRow(title: "退出登录", role: .destructive, showsChevron: false)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.current == nil)
                        }

                        GroupedRowsCard {
                            Button {
                                showDeleteSheet = true
                                Haptics.tap()
                            } label: {
                                GroupedRow(
                                    title: deleting ? "正在删除…" : "注销账号",
                                    role: .destructive,
                                    showsChevron: false
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(deleting || store.current == nil)
                        }

                        Text("很多功能还没做好 不可用")
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 72)
                    .padding(.bottom, 32)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // ── Header ─────────────────────────────────────────────────────────────

    /// Avatar / nickname / email stacked vertically, centered on the
    /// canvas (no surface card). The whole column is one tap target
    /// → ProfileBootstrapView.
    private var profileHeader: some View {
        VStack(spacing: 16) {
            let seed = store.avatarSeed ?? store.current?.id ?? "?"
            UserAvatar(
                seed: seed,
                attachmentId: store.avatarAttachmentId,
                size: 88
            )
            VStack(spacing: 6) {
                Text(displayLabel)
                    .font(Theme.Fonts.serif(size: 24, weight: .semibold))
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
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
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

    private func deleteAccount(sentiment: DeletionSentiment) async {
        guard !deleting else { return }
        deleting = true; defer { deleting = false }
        do {
            struct Args: Encodable { let p_sentiment: String }
            try await SupabaseStack.shared
                .rpc("delete_self_account",
                     params: Args(p_sentiment: sentiment.rawValue))
                .execute()
            await store.signOut()
            Haptics.success()
        } catch {
            self.error = "注销失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}

/// Native iOS grouped-list container — one rounded surface card holding
/// connected rows separated by hairline dividers. Caller is responsible
/// for placing `GroupedRowDivider()` between rows.
private struct GroupedRowsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
    }
}

/// Inset hairline separator between rows in a `GroupedRowsCard`. Inset
/// matches the row's leading text padding, like iOS Settings.
private struct GroupedRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, 20)
    }
}

/// One row inside a `GroupedRowsCard`. No background of its own — the
/// card supplies the surface; the row only paints text + optional
/// chevron with consistent padding.
private struct GroupedRow: View {
    enum Role { case normal, destructive }

    let title: String
    var role: Role = .normal
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Fonts.bodyEmphasized)
                .foregroundStyle(role == .destructive
                                 ? Color(hex: 0xB14B3C)
                                 : Theme.Palette.ink)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
