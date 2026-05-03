import SwiftUI
import PhotosUI

/// 我 — header (avatar + name + chevron-to-account-settings) and a thin
/// stack of action rows (号码 / 二维码 / 技能). 退出登录 sits at the bottom.
/// Tap the avatar to change avatar, tap the name to change nickname; the
/// chevron pushes into `AccountSettingsView` (login email, 头像/用户名生成,
/// 注销账号).
struct MeTabView: View {
    @EnvironmentObject private var store: AccountStore

    @State private var confirmingSignOut = false
    @State private var error: String?
    @State private var editingAvatar = false
    @State private var editingNickname = false
    @State private var showHandles = false
    @State private var showQR = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        profileHeader
                        rowCard(icon: "number", label: "号码") { showHandles = true }
                        rowCard(icon: "qrcode", label: "二维码") { showQR = true }
                        NavigationLink {
                            SkillsView().toolbar(.hidden, for: .tabBar)
                        } label: {
                            rowContent(icon: "puzzlepiece.extension", label: "技能")
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 8)
                        signOutRow
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                    .readableColumnWidth()
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $editingAvatar) {
            AvatarEditSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $editingNickname) {
            NicknameEditSheet()
                .presentationDetents([.fraction(0.32)])
                .presentationDragIndicator(.visible)
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
    }

    // ── Header ─────────────────────────────────────────────────────────────

    /// Avatar (left, tap → AvatarEditSheet), name (middle, tap → nickname
    /// edit), chevron (right, push → AccountSettingsView). Three discrete
    /// tap targets in one card.
    private var profileHeader: some View {
        HStack(spacing: 14) {
            Button {
                editingAvatar = true
                Haptics.tap()
            } label: {
                profileAvatar
            }
            .buttonStyle(.plain)

            Button {
                editingNickname = true
                Haptics.tap()
            } label: {
                Text(displayLabel)
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            NavigationLink {
                AccountSettingsView()
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var profileAvatar: some View {
        let seed = store.avatarSeed ?? store.current?.id ?? "?"
        UserAvatar(seed: seed,
                   attachmentId: store.avatarAttachmentId,
                   size: 56)
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

    // ── Action rows ────────────────────────────────────────────────────────

    private func rowCard(icon: String, label: String,
                         action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            rowContent(icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }

    private func rowContent(icon: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Palette.accentBg))
            Text(label)
                .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
        }
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
    }

    private var signOutRow: some View {
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
        }
        .buttonStyle(.plain)
        .disabled(store.current == nil)
    }

    // ── Actions ────────────────────────────────────────────────────────────

    private func signOut() {
        Task {
            await store.signOut()
            Haptics.success()
        }
    }
}

// ── Avatar edit sheet ───────────────────────────────────────────────────────

/// Tap-the-avatar surface. Pick a photo from Photos or roll a fresh
/// deterministic seed; either way we persist via the same path the
/// onboarding bootstrap uses (UPDATE pendingbot.users + AccountStore
/// markBootstrapped) so every avatar-rendering call site picks it up.
private struct AvatarEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore

    @State private var avatarSeed: String = UUID().uuidString
    @State private var customImageData: Data?
    @State private var customAttachmentId: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                VStack(spacing: 22) {
                    Spacer(minLength: 8)
                    avatarPreview
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            chip(icon: "photo", label: "上传图片")
                        }
                        .onChange(of: pickerItem) { _, item in
                            guard let item else { return }
                            Task { await loadPicked(item) }
                        }
                        Button {
                            customImageData = nil
                            customAttachmentId = nil
                            avatarSeed = UUID().uuidString
                            Haptics.tap()
                        } label: {
                            chip(icon: "shuffle", label: "随机生成")
                        }
                        .buttonStyle(.plain)
                    }
                    if let error {
                        Text(error)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
            }
            .navigationTitle("头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView().tint(Theme.Palette.accent)
                    } else {
                        Button("完成") { Task { await save() } }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }
            .onAppear {
                if let seed = store.avatarSeed, !seed.isEmpty { avatarSeed = seed }
                if let aid = store.avatarAttachmentId, !aid.isEmpty {
                    customAttachmentId = aid
                }
            }
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let data = customImageData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        } else if let aid = customAttachmentId, !aid.isEmpty {
            UserAvatar(seed: avatarSeed, attachmentId: aid, size: 120)
        } else {
            BotAvatar(seed: avatarSeed, size: 120)
        }
    }

    private func chip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
            Text(label)
                .font(Theme.Fonts.rounded(size: 13, weight: .medium))
        }
        .foregroundStyle(Theme.Palette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.Palette.accentBg))
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        error = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            error = "读取图片失败"
            return
        }
        customImageData = data
        await uploadAvatar(data: data)
    }

    private func uploadAvatar(data: Data) async {
        working = true; defer { working = false }
        do {
            let workerURL = HostedConfig.environment.workerURL
            var req = URLRequest(url: workerURL.appendingPathComponent("v1/upload"))
            req.httpMethod = "POST"
            let boundary = "----PendingBot\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n"
                .data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body

            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            struct R: Decodable { let id: String }
            let r = try JSONDecoder().decode(R.self, from: respData)
            customAttachmentId = r.id
            Haptics.success()
        } catch {
            self.error = "上传失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func save() async {
        guard let userId = store.current?.id else { return }
        working = true; defer { working = false }
        struct Patch: Encodable { let custom_fields: [String: String] }
        var fields: [String: String] = [
            "avatar_seed": avatarSeed,
            "bootstrapped": "1",
        ]
        if let aid = customAttachmentId, !aid.isEmpty {
            fields["avatar_attachment_id"] = aid
        }
        do {
            try await SupabaseStack.shared
                .from("users")
                .update(Patch(custom_fields: fields))
                .eq("id", value: userId)
                .execute()
            // Keep the existing display_name; only refresh avatar bits.
            store.markBootstrapped(
                displayName: store.profileDisplayName
                    ?? store.current?.displayName ?? "",
                avatarSeed: avatarSeed,
                attachmentId: customAttachmentId
            )
            Haptics.success()
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}

// ── Nickname edit sheet ─────────────────────────────────────────────────────

/// Tap-the-name surface. One TextField, save on 完成.
private struct NicknameEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore

    @State private var name: String = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    TextField("起一个吧", text: $name)
                        .focused($focused)
                        .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
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
                    if let error {
                        Text(error)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
            }
            .navigationTitle("昵称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().tint(Theme.Palette.accent)
                    } else {
                        Button("完成") { Task { await save() } }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Palette.accent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear {
                name = store.profileDisplayName
                    ?? store.current?.displayName ?? ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    focused = true
                }
            }
        }
    }

    private func save() async {
        guard let userId = store.current?.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true; defer { saving = false }
        struct Patch: Encodable { let display_name: String }
        do {
            try await SupabaseStack.shared
                .from("users")
                .update(Patch(display_name: trimmed))
                .eq("id", value: userId)
                .execute()
            store.markBootstrapped(
                displayName: trimmed,
                avatarSeed: store.avatarSeed ?? UUID().uuidString,
                attachmentId: store.avatarAttachmentId
            )
            Haptics.success()
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}

// ── Account settings (sub-page pushed by the chevron) ───────────────────────

/// Pushed from the 我 tab header chevron. Holds the lower-frequency
/// account-level controls — login email, full 头像/用户名生成 (welcome
/// page), and 注销账号 with the strict warning copy.
private struct AccountSettingsView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var showRandomize = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    emailRow
                    Button {
                        showRandomize = true
                        Haptics.tap()
                    } label: {
                        actionRow(icon: "shuffle", label: "头像 / 用户名生成")
                    }
                    .buttonStyle(.plain)
                    deleteRow
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .readableColumnWidth()
            }
        }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showRandomize) {
            ProfileBootstrapView(allowsBack: true)
                .environmentObject(AccountStore.shared)
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(
            "删除你在服务器上的所有数据 就像你没来过一样 不可撤销 无法恢复 数据无价 谨慎操作",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { Task { await deleteAccount() } }
            Button("取消", role: .cancel) {}
        }
    }

    private var emailRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Palette.accentBg))
            Text("登录邮箱")
                .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 8)
            Text(store.current?.email ?? "—")
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
    }

    private func actionRow(icon: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.Palette.accentBg))
            Text(label)
                .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
        }
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
    }

    private var deleteRow: some View {
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
        }
        .buttonStyle(.plain)
        .disabled(deleting || store.current == nil)
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
