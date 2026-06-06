#if os(macOS)
import SwiftUI
import AppKit
import OSLog

private let log = Logger.category("profile-edit")

/// 资料编辑 (Mac) — native re-draw of iOS `ProfileBootstrapView`'s editing
/// surface (`CustomizeSheet` + the random-roll logic), collapsed into one
/// sheet that fits the Mac idiom.
///
/// Reuses the same cross-platform persistence the iOS flow uses:
///   - display name + avatar attachment → `SupabaseStack.from("users").update`
///   - avatar seed → `custom_fields.avatar_seed`
///   - `AccountStore.markBootstrapped(...)` to update the in-memory mirror
///   - `/v1/upload` multipart for custom-image upload (NSOpenPanel picks the
///     file; iOS uses PhotosUI which doesn't exist on Mac)
///
/// Avatar preview mirrors `MacContactAvatar`: uploaded image via `ServerImage`
/// when an attachment id is set, else the deterministic `BrandAvatar(seed:)`.
struct MacProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AccountStore

    @State private var name: String = ""
    @State private var avatarSeed: String = UUID().uuidString
    /// Locally-picked image bytes for instant preview before/while uploading.
    @State private var customImageData: Data?
    /// Server attachment id once `/v1/upload` returns (persisted to users.avatar_path).
    @State private var customAttachmentId: String?

    @State private var saving = false
    @State private var uploading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 12)
                    avatarPreview
                    photoActions
                    nameField
                    if let error {
                        Text(error)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 22)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 460, minHeight: 460)
        .background(Theme.Palette.canvas)
        .tint(Theme.Palette.accent)
        .onAppear { prefillFromStore() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text("自定义")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.Palette.ink)
            Spacer()
            Button("取消") { dismiss() }
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().controlSize(.small) }
                else { Text("完成") }
            }
            .keyboardShortcut(.defaultAction)
            .tint(Theme.Palette.accent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var avatarPreview: some View {
        Group {
            if let data = customImageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            } else if let aid = customAttachmentId, !aid.isEmpty {
                ServerImage(path: aid,
                            serverURL: HostedConfig.environment.workerURL,
                            contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            } else {
                BrandAvatar(seed: avatarSeed, size: 120)
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
            Button {
                pickImage()
            } label: {
                actionChip(systemImage: "photo", label: "上传图片")
            }
            .buttonStyle(.plain)
            .disabled(uploading)

            Button {
                customImageData = nil
                customAttachmentId = nil
                avatarSeed = UUID().uuidString
            } label: {
                actionChip(systemImage: "shuffle", label: "随机生成")
            }
            .buttonStyle(.plain)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("昵称")
                    .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkMuted)
                Spacer()
                Button {
                    name = MacNameCorpus.shared.random()
                } label: {
                    Label("随机名字", systemImage: "die.face.5")
                        .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                }
                .buttonStyle(.link)
                .tint(Theme.Palette.accent)
            }
            TextField("起一个吧", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
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

    // MARK: - State

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving && !uploading
    }

    private func prefillFromStore() {
        let storedName = (store.profileDisplayName
            ?? store.current?.displayName ?? "").trimmingCharacters(in: .whitespaces)
        name = storedName.isEmpty ? MacNameCorpus.shared.random() : storedName
        avatarSeed = (store.avatarSeed?.isEmpty == false)
            ? store.avatarSeed! : (store.current?.id ?? UUID().uuidString)
        customAttachmentId = (store.avatarAttachmentId?.isEmpty == false)
            ? store.avatarAttachmentId : nil
    }

    // MARK: - Image picking (NSOpenPanel, AppKit)

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            error = "读取图片失败"
            return
        }
        customImageData = data
        Task { await uploadAvatar(data: data, mime: mimeType(for: url)) }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":  return "image/png"
        case "gif":  return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        default:     return "image/jpeg"
        }
    }

    // MARK: - Upload + save (cross-platform channels)

    /// POST /v1/upload (multipart). Same wire shape iOS uses; stores the
    /// returned attachment id so `save()` can stamp it into users.avatar_path.
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
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"avatar\"\r\n"
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
        } catch {
            self.error = "上传失败：\(error.localizedDescription)"
            log.warning("avatar upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mirror of iOS `ProfileBootstrapView.save()` — same `users` row update
    /// and `markBootstrapped` mirror refresh.
    private func save() async {
        guard let userId = store.current?.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true; defer { saving = false }
        struct Patch: Encodable {
            let display_name: String
            let avatar_path: String?
            let custom_fields: [String: String]
        }
        let fields: [String: String] = [
            "avatar_seed": avatarSeed,
            "bootstrapped": "1",
        ]
        let aid = (customAttachmentId?.isEmpty == false) ? customAttachmentId : nil
        do {
            try await SupabaseStack.shared
                .from("users")
                .update(Patch(display_name: trimmed,
                              avatar_path: aid,
                              custom_fields: fields))
                .eq("id", value: userId)
                .execute()
            store.markBootstrapped(displayName: trimmed,
                                   avatarSeed: avatarSeed,
                                   attachmentId: customAttachmentId)
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
            log.warning("profile save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Mac-side names corpus reader. The iOS `NameCorpus` lives inside the
/// `#if os(iOS)` ProfileBootstrapView file, so Mac needs its own loader
/// against the same bundled `Resources/names.txt` (one name per line).
final class MacNameCorpus {
    static let shared = MacNameCorpus()
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
    func random() -> String { names.randomElement() ?? "你" }
}
#endif
