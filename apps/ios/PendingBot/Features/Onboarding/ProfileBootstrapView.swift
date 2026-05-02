import SwiftUI
import PhotosUI

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
    /// Once the user picks a custom photo we hold its bytes here. Set
    /// trumps the BotAvatar — both for the front card preview and the
    /// final commit (we upload then store the attachment id).
    @State private var customImageData: Data?
    /// Server-assigned attachment id once we've uploaded the custom
    /// image. Persists across "再来一次" rolls inside this view.
    @State private var customAttachmentId: String?
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
                Spacer(minLength: 12)
                headerCopy

                // Two flex spacers around the card centre it vertically
                // between the header copy above and the caption below.
                Spacer(minLength: 0)
                cardCarousel
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 10) {
                    swipeCaption
                    if let error {
                        Text(error)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(.red)
                    }
                    customizeRow
                }
                Spacer(minLength: 18)
                confirmRow
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            if allowsBack {
                // Re-entry from profile sub-page: pre-fill the current
                // profile so the user can keep / tweak it instead of
                // landing on a fresh random pair.
                if name.isEmpty {
                    name = store.profileDisplayName
                        ?? store.current?.displayName ?? NameCorpus.shared.random()
                }
                if let seed = store.avatarSeed, !seed.isEmpty {
                    avatarSeed = seed
                }
                if let aid = store.avatarAttachmentId, !aid.isEmpty {
                    customAttachmentId = aid
                    // customImageData stays nil — UserAvatar will lazy-
                    // load the existing upload via /v1/uploads/<id>.
                }
            } else {
                if name.isEmpty { name = NameCorpus.shared.random() }
            }
            if nextName.isEmpty { nextName = NameCorpus.shared.random() }
        }
        .sheet(isPresented: $editing) {
            CustomizeSheet(
                name: $name,
                avatarSeed: $avatarSeed,
                customImageData: $customImageData,
                customAttachmentId: $customAttachmentId
            )
            .presentationDetents([.medium, .large])
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
                        .frame(width: 40, height: 40)
                        // Native iOS "glass" — ultraThinMaterial circle
                        // with a subtle inner stroke. Same idiom Apple
                        // uses for nav-bar back chips on translucent
                        // chrome (Maps, Photos, etc).
                        .background(
                            Circle().fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(height: 40)
        .padding(.top, 8)
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
                // Next card (peek on the right of current). Always uses
                // a generated avatar — the custom image only sticks to
                // the current card.
                nameCardView(seed: nextAvatarSeed, name: nextName,
                             customImage: nil, attachmentId: nil)
                    .frame(width: cardWidth)
                    .scaleEffect(0.95)
                    .opacity(0.6)
                    .offset(x: cardWidth + cardGap + dragOffset)

                // Current card.
                nameCardView(seed: avatarSeed, name: name,
                             customImage: customImageData,
                             attachmentId: customAttachmentId)
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
                Text("我不懒 我就要自己填名字和头像")
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
    /// breathing room between them. Avatar source priority:
    /// `customImage` (locally just-picked bytes) → `attachmentId`
    /// (server-side existing upload) → BotAvatar(seed).
    private func nameCardView(seed: String, name: String,
                              customImage: Data?,
                              attachmentId: String?) -> some View {
        HStack(spacing: 28) {
            if let data = customImage, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            } else if let aid = attachmentId, !aid.isEmpty {
                UserAvatar(seed: seed, attachmentId: aid, size: 76)
            } else {
                BotAvatar(seed: seed, size: 76)
            }
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
                // Swipe = "give me a fresh pair" — drop any custom
                // image the user had set on the previous card.
                customImageData = nil
                customAttachmentId = nil
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
        var fields: [String: String] = [
            "avatar_seed": avatarSeed,
            "bootstrapped": "1",
        ]
        if let aid = customAttachmentId, !aid.isEmpty {
            fields["avatar_attachment_id"] = aid
        }
        do {
            try await SupabaseStack.shared.database
                .from("users")
                .update(Patch(display_name: trimmed, custom_fields: fields))
                .eq("id", value: userId)
                .execute()
            store.markBootstrapped(displayName: trimmed,
                                   avatarSeed: avatarSeed,
                                   attachmentId: customAttachmentId)
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

/// Manual edit: type a name + pick a photo (or reroll the avatar seed)
/// for a fully custom profile. Photo upload goes through /v1/upload;
/// the resulting attachment id is held by the parent until commit.
private struct CustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @Binding var avatarSeed: String
    @Binding var customImageData: Data?
    @Binding var customAttachmentId: String?

    @State private var pickerItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        Spacer(minLength: 12)

                        avatarPreview
                        photoActions

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

                        if let uploadError {
                            Text(uploadError)
                                .font(Theme.Fonts.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 22)
                        }

                        Spacer(minLength: 12)
                    }
                }
            }
            .navigationTitle("自定义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Palette.accent)
                        .disabled(uploading)
                }
            }
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        Group {
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
        .overlay(alignment: .bottomTrailing) {
            if uploading {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(Circle().fill(.ultraThinMaterial))
            }
        }
    }

    private var photoActions: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                actionChip(systemImage: "photo", label: "上传图片")
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
                actionChip(systemImage: "shuffle", label: "随机生成")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionChip(systemImage: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
            Text(label)
                .font(Theme.Fonts.rounded(size: 13, weight: .medium))
        }
        .foregroundStyle(Theme.Palette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.Palette.accentBg))
    }

    /// Decode the picked photo into raw Data for instant local preview,
    /// then upload to the Worker so we have an attachment id to persist.
    private func loadPicked(_ item: PhotosPickerItem) async {
        uploadError = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            uploadError = "读取图片失败"
            return
        }
        customImageData = data
        await uploadAvatar(data: data, mime: "image/jpeg")
    }

    /// POST /v1/upload (no conversationId — avatar isn't tied to a conv).
    /// Stores the returned id in the binding so the parent's save() can
    /// stamp it into pendingbot.users.custom_fields.
    private func uploadAvatar(data: Data, mime: String) async {
        uploading = true; defer { uploading = false }
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
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
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
            uploadError = "上传失败：\(error.localizedDescription)"
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
