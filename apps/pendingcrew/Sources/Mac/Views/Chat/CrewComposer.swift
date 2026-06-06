#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One file the user picked but hasn't sent yet. Held in the composer tray
/// until send, when each is uploaded (`uploadAttachment`) → its returned id is
/// collected into `postCrewMessage(attachmentIds:)`. `data` is read eagerly at
/// pick time so the security-scoped file URL doesn't have to stay open.
struct PendingComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let mime: String
    let data: Data

    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
    var byteSize: Int { data.count }
}

/// 中栏底部输入条：`+` 附件钮 + 胶囊 TextField + 圆形发送钮。对齐 PendingBot
/// iOS Composer。附件托盘（缩略图 / 文件 chip）渲染在输入行上方，镜像
/// `CrewAttachmentView` 风格但更小。
struct CrewComposer: View {
    @Binding var draft: String
    @Binding var attachments: [PendingComposerAttachment]
    let sending: Bool
    let errorText: String?
    let onSend: () -> Void

    @State private var importing = false

    private var canSend: Bool {
        guard !sending else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if let errorText {
                Text(errorText).font(CrewTheme.Fonts.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.isEmpty {
                tray
            }
            HStack(spacing: 8) {
                Button {
                    importing = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CrewTheme.Palette.inkMuted)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(CrewTheme.Palette.surface))
                        .overlay(Circle().strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .help("添加附件")

                TextField("发消息…（不 @ = 广播给所有 session）", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(CrewTheme.Fonts.body)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(CrewTheme.Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5))
                    .onSubmit { if canSend { onSend() } }

                Button(action: onSend) {
                    ZStack {
                        Circle().fill(canSend ? CrewTheme.Palette.accent : CrewTheme.Palette.surfaceMuted)
                            .frame(width: 30, height: 30)
                        if sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canSend ? .white : CrewTheme.Palette.inkMuted)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(CrewTheme.Palette.canvas)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.image, .pdf, .plainText, .data],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - Pending tray

    private var tray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    pendingChip(att)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pendingChip(_ att: PendingComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if att.isImage, let nsImage = NSImage(data: att.data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    fileChip(att)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5)
            )

            Button {
                attachments.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .disabled(sending)
        }
    }

    private func fileChip(_ att: PendingComposerAttachment) -> some View {
        VStack(spacing: 4) {
            Image(systemName: iconName(for: att.mime))
                .font(.system(size: 20))
                .foregroundStyle(CrewTheme.Palette.accent)
            Text(att.filename)
                .font(CrewTheme.Fonts.system(10))
                .foregroundStyle(CrewTheme.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 56)
        }
        .frame(width: 64, height: 64)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CrewTheme.Palette.surface))
    }

    private func iconName(for mime: String) -> String {
        let m = mime.lowercased()
        if m == "application/pdf" { return "doc.richtext" }
        if m.hasPrefix("audio/") { return "waveform" }
        if m.hasPrefix("video/") { return "film" }
        if m.hasPrefix("text/") { return "doc.text" }
        if m.contains("zip") || m.contains("compressed") || m.contains("archive") { return "doc.zipper" }
        return "doc.fill"
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            // Picked files are security-scoped — read bytes inside the access
            // window, then drop the URL (we keep the Data, not the handle).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            attachments.append(PendingComposerAttachment(
                filename: url.lastPathComponent,
                mime: mime,
                data: data
            ))
        }
    }
}
#endif
