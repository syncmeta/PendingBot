#if os(macOS)
import SwiftUI

/// Renders a crew message's attachments below the bubble text — an image grid
/// (up to 3 per row) + file chips. macOS native port of PendingBot iOS
/// `AttachmentGrid` / `FileAttachmentChip`, styled with `CrewTheme` tokens so
/// it sits flush with the bubbles. Render-only (the compose / upload / send
/// half lands in a later pass).
struct CrewAttachmentView: View {
    let attachments: [CrewAttachment]
    /// Side the owning bubble sits on — own messages pass `.trailing` so the
    /// grid hugs the right edge like the text bubble; peers leave `.leading`.
    var alignment: HorizontalAlignment = .leading

    private var images: [CrewAttachment] { attachments.filter(\.isImage) }
    private var files: [CrewAttachment] { attachments.filter { !$0.isImage } }

    /// Fixed thumbnail edge. Fixed-size cells keep the grid intrinsically
    /// sized so the parent VStack's alignment can position it (a flexible grid
    /// would stretch full-width and float the image).
    private let cell: CGFloat = 110

    /// Images chunked into rows of up to 3.
    private var imageRows: [[CrewAttachment]] {
        stride(from: 0, to: images.count, by: 3).map {
            Array(images[$0 ..< min($0 + 3, images.count)])
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(imageRows.indices, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(imageRows[row]) { att in
                        CrewRemoteImage(path: att.url, contentMode: .fill)
                            .frame(width: cell, height: cell)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5)
                            )
                    }
                }
            }
            ForEach(files) { att in
                CrewFileAttachmentChip(attachment: att)
            }
        }
    }
}

/// A non-image attachment rendered as an icon + filename + size chip. macOS
/// native port of PendingBot iOS `FileAttachmentChip` (render-only — open /
/// share comes with the compose pass).
struct CrewFileAttachmentChip: View {
    let attachment: CrewAttachment

    private var displayName: String { attachment.filename ?? "文件" }

    private var sizeText: String? {
        guard let size = attachment.size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// SF Symbol picked from the MIME so the chip reads at a glance.
    private var iconName: String {
        let mime = attachment.mime.lowercased()
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("text/") { return "doc.text" }
        if mime.contains("zip") || mime.contains("compressed") || mime.contains("archive") {
            return "doc.zipper"
        }
        return "doc.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(CrewTheme.Fonts.system(22))
                .foregroundStyle(CrewTheme.Palette.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(CrewTheme.Fonts.system(14, weight: .medium))
                    .foregroundStyle(CrewTheme.Palette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let sizeText {
                    Text(sizeText)
                        .font(CrewTheme.Fonts.system(11))
                        .foregroundStyle(CrewTheme.Palette.inkMuted)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(CrewTheme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CrewTheme.Palette.hairline, lineWidth: 0.5)
        )
    }
}
#endif
