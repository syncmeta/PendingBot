import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Random-name + random-avatar onboarding step. Shown right after first
/// sign-in (when the user hasn't set a profile yet) and re-openable from
/// the profile sub-page. Cross-platform (iOS gate `RootView` + macOS gate
/// `MacRootGate`) — platform-specific bits (`UIImage`/`NSImage`, sheet
/// detents, nav-title display mode) go through the repo's platform shims
/// (`PlatformImage`, `PlatformModifiers`) so one implementation serves both.
///
/// Swiping is a real horizontal-paging ScrollView (iOS-home-screen feel)
/// — each card is one entry in `pages`, and reaching the last card lazily
/// rolls a fresh one behind it. The user commits the *currently visible*
/// card by tapping the forward arrow.
struct ProfileBootstrapView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore
    var onDone: (() -> Void)?
    /// True when launched from the profile sub-page (re-roll mode) — adds
    /// a back chevron and lets the user bail without committing. Default
    /// false for first-launch flow where committing is required.
    var allowsBack: Bool = false

    /// One swipeable card. Custom image bytes / attachment id live on the
    /// page itself so a customised card sticks around even after the user
    /// swipes past it and back.
    private struct Page: Identifiable, Equatable {
        let id = UUID()
        var seed: String
        var name: String
        var customImageData: Data? = nil
        var customAttachmentId: String? = nil
    }

    @State private var pages: [Page] = []
    @State private var visibleId: UUID?
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
                .padding(.horizontal, 28)
                Spacer(minLength: 18)
                confirmRow
                    .padding(.horizontal, 28)
                Spacer(minLength: 8)
            }
        }
        .onAppear {
            seedPagesIfNeeded()
        }
        .sheet(isPresented: $editing) {
            if let idx = currentIndex {
                CustomizeSheet(
                    name: Binding(
                        get: { pages[idx].name },
                        set: { pages[idx].name = $0 }
                    ),
                    avatarSeed: Binding(
                        get: { pages[idx].seed },
                        set: { pages[idx].seed = $0 }
                    ),
                    customImageData: Binding(
                        get: { pages[idx].customImageData },
                        set: { pages[idx].customImageData = $0 }
                    ),
                    customAttachmentId: Binding(
                        get: { pages[idx].customAttachmentId },
                        set: { pages[idx].customAttachmentId = $0 }
                    )
                )
                .platformDetents([.medium, .large])
                .platformDragIndicator()
                // macOS sheets size to content; give the customise sheet a
                // sensible floor so its ScrollView isn't collapsed. No-op iOS.
                .macSheetMinSize(minWidth: 460, minHeight: 560)
            }
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
                        .font(Theme.Fonts.glyph(size: 17, weight: .semibold))
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
        .padding(.horizontal, 28)
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
        .padding(.horizontal, 28)
    }

    /// Horizontal paging ScrollView. `.scrollTargetBehavior(.viewAligned)`
    /// snaps to the nearest card after each flick — same momentum + snap
    /// curve UIKit gives the iOS home-screen pager. `contentMargins`
    /// centres the focused card while leaving a peek of the next one.
    private var cardCarousel: some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width * cardWidthFraction
            let sideMargin = max(0, (geo.size.width - cardWidth) / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardGap) {
                    ForEach(pages) { page in
                        nameCardView(seed: page.seed, name: page.name,
                                     customImage: page.customImageData,
                                     attachmentId: page.customAttachmentId)
                            .frame(width: cardWidth)
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, sideMargin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $visibleId)
            .onChange(of: visibleId) { _, newId in
                ensureLookahead(after: newId)
            }
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
                    .font(Theme.Fonts.glyph(size: 13, weight: .medium))
                Text("我不懒 我就要自己填名字和头像")
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.Palette.accentBg))
        }
        .buttonStyle(.plain)
        .disabled(currentIndex == nil)
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
                            .font(Theme.Fonts.glyph(size: 22, weight: .semibold))
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
            if let data = customImage, let img = PlatformImage.decode(data) {
                Image(platformImage: img)
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

    // ── Page bookkeeping ───────────────────────────────────────────────

    private var currentIndex: Int? {
        guard let visibleId else { return pages.indices.first }
        return pages.firstIndex { $0.id == visibleId }
    }

    private var current: Page? {
        guard let idx = currentIndex else { return nil }
        return pages[idx]
    }

    private var canSave: Bool {
        guard let c = current else { return false }
        return !c.name.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    private func seedPagesIfNeeded() {
        guard pages.isEmpty else { return }
        if allowsBack {
            // Re-entry from profile sub-page: pre-fill the current
            // profile so the user can keep / tweak it instead of
            // landing on a fresh random pair.
            let storedName = (store.profileDisplayName
                ?? store.current?.displayName ?? "").trimmingCharacters(in: .whitespaces)
            let firstName = storedName.isEmpty ? NameCorpus.shared.random() : storedName
            let firstSeed = (store.avatarSeed?.isEmpty == false
                ? store.avatarSeed! : UUID().uuidString)
            let firstAid = (store.avatarAttachmentId?.isEmpty == false
                ? store.avatarAttachmentId : nil)
            let first = Page(seed: firstSeed, name: firstName,
                             customImageData: nil, customAttachmentId: firstAid)
            pages = [first, freshPage()]
            visibleId = first.id
        } else {
            let first = freshPage()
            pages = [first, freshPage()]
            visibleId = first.id
        }
    }

    private func freshPage() -> Page {
        Page(seed: UUID().uuidString, name: NameCorpus.shared.random())
    }

    /// When the focused card is the last one we've generated, append a
    /// fresh one so there's always a peek-of-next on the right edge —
    /// mirrors the infinite-forward feel of paging through cards.
    private func ensureLookahead(after id: UUID?) {
        guard let id, let idx = pages.firstIndex(where: { $0.id == id }) else { return }
        if idx >= pages.count - 1 {
            pages.append(freshPage())
        }
    }

    private func save() async {
        guard let c = current, let userId = store.current?.id else { return }
        let trimmed = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true; defer { saving = false }
        do {
            // Shared profile write seam (§10) — same `users` UPDATE Mac runs.
            try await ProfileDataSource.updateProfile(
                userId: userId,
                displayName: trimmed,
                avatarSeed: c.seed,
                attachmentId: c.customAttachmentId
            )
            store.markBootstrapped(displayName: trimmed,
                                   avatarSeed: c.seed,
                                   attachmentId: c.customAttachmentId)
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
    #if os(macOS)
    /// macOS 额外的「选择文件」路径 —— PhotosPicker 只见 Photos 图库,Mac 用户
    /// 的图多在文件系统里,补一个 .fileImporter 入口(同消息 tab 发文件的做法)。
    @State private var showFileImporter = false
    #endif

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
                                .platformAutocapitalization()
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
            .inlineNavTitle()
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
            if let data = customImageData, let img = PlatformImage.decode(data) {
                Image(platformImage: img)
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
            #if os(macOS)
            Button {
                showFileImporter = true
            } label: {
                actionChip(systemImage: "folder", label: "选择文件")
            }
            .buttonStyle(.plain)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image]
            ) { result in
                if case .success(let url) = result {
                    Task { await loadFile(url) }
                }
            }
            #endif
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
                .font(Theme.Fonts.glyph(size: 13, weight: .medium))
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

    #if os(macOS)
    /// File-importer path (macOS): read the security-scoped URL into Data
    /// for instant preview, then upload — same seam as `loadPicked`. MIME
    /// derived from the extension, mirroring the chat file-ingest path.
    private func loadFile(_ url: URL) async {
        uploadError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            uploadError = "读取图片失败"
            return
        }
        customImageData = data
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "image/jpeg"
        await uploadAvatar(data: data, mime: mime)
    }
    #endif

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
