import SwiftUI

/// 我 — profile, 当前服务器, 画像, AI 收藏. Visual language mirrors the
/// PendingBot settings sheet: canvas background, vertical stack of
/// `card(title, footer, content)` blocks, serif headings, hairline-bordered
/// surface fills, rounded labels.
struct MeTabView: View {
    @Environment(\.api) private var api
    @EnvironmentObject private var store: AccountStore

    @State private var profile: MeProfile?

    @State private var showProfileEdit = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Theme.Palette.canvas.ignoresSafeArea()
                    ScrollView {
                        VStack(spacing: 22) {
                            profileHeader
                            skillsCard
                            signOutCard
                            deleteAccountCard
                        }
                        .padding(.horizontal, Theme.Metrics.gutter)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                        .readableColumnWidth()
                    }
                    .refreshable { await load() }
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .sheet(isPresented: $showProfileEdit) {
            ProfileEditView(profile: profile) { Task { await load() } }
                .tint(Theme.Palette.accent)
                .presentationDragIndicator(.visible)
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(
            "退出当前服务器？",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) { signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台设备会注销「\(store.current?.displayName ?? "当前账户")」的登录。重新用 Apple ID 登录即可恢复。")
        }
        .confirmationDialog(
            "永久注销账号？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { Task { await deleteAccount() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会从服务器删除所有跟你有关的数据 —— 对话、好友、号码、画像。无法恢复。如果只是想退出登录，请用上面的「退出登录」。")
        }
    }

    // ── Cards ───────────────────────────────────────────────────────────────

    /// Card-less header. Tap the avatar (or the name) to open the profile
    /// sub-page where 号码 / 二维码 also live.
    private var profileHeader: some View {
        Button {
            showProfileEdit = true
            Haptics.tap()
        } label: {
            VStack(spacing: 10) {
                profileAvatar
                Text(displayLabel)
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else {
                    Text("点这里完善资料 / 管理号码")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 4)
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
    }

    // Deterministic BotAvatar (svg pattern keyed off user_id) so an unset
    // avatar still renders something coherent instead of a generic placeholder.
    @ViewBuilder
    private var profileAvatar: some View {
        let seed = store.avatarSeed
            ?? profile?.user_id
            ?? store.current?.id
            ?? "?"
        UserAvatar(seed: seed,
                   attachmentId: store.avatarAttachmentId,
                   size: 64)
    }

    // The server's display_name is the canonical handle (PATCH /me/profile
    // edits it directly). When that's empty, fall back to the local-part of
    // the verified email, then "未命名".
    private var displayLabel: String {
        let ws = CharacterSet.whitespacesAndNewlines
        if let stored = store.profileDisplayName?.trimmingCharacters(in: ws),
           !stored.isEmpty {
            return stored
        }
        let dn = profile?.display_name.trimmingCharacters(in: ws) ?? ""
        if !dn.isEmpty { return dn }
        if let local = profile?.email?.split(separator: "@").first, !local.isEmpty {
            return String(local)
        }
        return "未命名"
    }

    private var skillsCard: some View {
        card(title: "技能",
             footer: "启用的技能会拼进系统提示词，机器人按需调用。预设来自 anthropic/skills（Apache-2.0）。")
        {
            NavigationLink {
                SkillsView()
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.Palette.accentBg))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("技能管理")
                            .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Palette.ink)
                        Text("列表 · 启用 · 编辑")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
    }

    private var deleteAccountCard: some View {
        card(title: nil, footer: "永久删除：所有对话、好友、号码、画像都会一并清除，且无法恢复。") {
            Button(role: .destructive) {
                confirmingDelete = true
                Haptics.tap()
            } label: {
                HStack(spacing: 10) {
                    if deleting {
                        ProgressView().tint(Color(hex: 0xB14B3C))
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                    }
                    Text(deleting ? "正在删除…" : "注销账号")
                        .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(hex: 0xB14B3C))
                .padding(.vertical, 4)
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(deleting || store.current == nil)
        }
    }

    private var signOutCard: some View {
        card(title: nil, footer: nil) {
            Button(role: .destructive) {
                confirmingSignOut = true
                Haptics.tap()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 14, weight: .medium))
                    Text("退出登录")
                        .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(hex: 0xB14B3C))
                .padding(.vertical, 4)
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(store.current == nil)
        }
    }

    // ── Card chrome (mirrors PendingBot SettingsView.card) ─────────────────

    @ViewBuilder
    private func card<Content: View>(
        title: String?, footer: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.serif(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.leading, 4)
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 4)
            }
        }
    }

    // ── Data ────────────────────────────────────────────────────────────────

    private func load() async {
        // Legacy api/me/* endpoints don't exist on the new Worker. Until
        // /v1/me/profile lands this view falls back to AccountStore for
        // display name + email.
        self.profile = nil
    }

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
            // RPC wipes everything (messages, convs, participants, handles,
            // contacts, picks, devices, …) and drops the auth.users row,
            // which cascades the rest. After it returns the JWT is dead;
            // local signOut clears the keychain + the SQLite cache so the
            // next launch lands on WelcomeView.
            try await SupabaseStack.shared.database
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

// ── Sub-sheets ──────────────────────────────────────────────────────────────

/// Same card-styled chrome used by the main `MeTabView`. Applied to each
/// of the editing sheets (profile / pick / new portrait) so the look stays
/// consistent across the whole 我 surface.
private struct CardChrome<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.serif(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.leading, 4)
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.inkMuted)
            content()
        }
    }
}

private func styledField(placeholder: String, text: Binding<String>,
                         keyboard: UIKeyboardType = .default,
                         monospaced: Bool = false) -> some View {
    TextField(placeholder, text: text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .keyboardType(keyboard)
        .font(monospaced ? .system(size: 15, design: .monospaced)
                         : Theme.Fonts.rounded(size: 15, weight: .regular))
        .foregroundStyle(Theme.Palette.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
}

// ── Profile edit ───────────────────────────────────────────────────────────

private struct ProfileEditView: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    let profile: MeProfile?
    var onSaved: () -> Void
    @State private var name = ""
    @State private var bio = ""
    @State private var saving = false
    @State private var showHandles = false
    @State private var showRandomize = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        CardChrome(title: "基本资料", footer: "AI 会读到这些 — 写得越具体，Ta 越懂你。") {
                            VStack(alignment: .leading, spacing: 14) {
                                LabeledField(title: "昵称") {
                                    styledField(placeholder: "你叫什么", text: $name)
                                }
                                LabeledField(title: "简介") {
                                    TextEditor(text: $bio)
                                        .textInputAutocapitalization(.sentences)
                                        .font(Theme.Fonts.rounded(size: 15, weight: .regular))
                                        .foregroundStyle(Theme.Palette.ink)
                                        .scrollContentBackground(.hidden)
                                        .padding(10)
                                        .frame(minHeight: 120)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Theme.Palette.canvas)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                        CardChrome(
                            title: "随机一键换装",
                            footer: "重新随机生成一个名字 + 头像。"
                        ) {
                            Button {
                                showRandomize = true
                                Haptics.tap()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Theme.Palette.accent)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Theme.Palette.accentBg))
                                    Text("再来一次随机生成")
                                        .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.Palette.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                                }
                            }
                            .contentShape(Rectangle())
                            .buttonStyle(.plain)
                        }

                        CardChrome(
                            title: "号码 / 二维码",
                            footer: "号码可生成多个，分别备注，随时撤销。别人通过任意有效号码加你时你都能看到他用了哪个。"
                        ) {
                            Button {
                                showHandles = true
                                Haptics.tap()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "number")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Theme.Palette.accent)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Theme.Palette.accentBg))
                                    Text("管理我的号码")
                                        .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.Palette.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                                }
                            }
                            .contentShape(Rectangle())
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .sheet(isPresented: $showHandles) {
                MyHandlesSheet()
                    .tint(Theme.Palette.accent)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showRandomize) {
                ProfileBootstrapView(allowsBack: true)
                    .environmentObject(AccountStore.shared)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("编辑资料")
                        .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().tint(Theme.Palette.accent)
                    } else {
                        Button("保存") { Task { await save() } }
                            .foregroundStyle(Theme.Palette.accent)
                            .fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                name = profile?.display_name ?? ""
                bio = profile?.bio ?? ""
            }
        }
    }

    private func save() async {
        // Profile edit endpoint not yet on the new Worker; saving is a
        // no-op placeholder. Lands when /v1/me/profile arrives.
        saving = true; defer { saving = false }
        Haptics.success()
        onSaved()
        dismiss()
    }
}
