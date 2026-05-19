import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Attachment upload helpers extracted from ConversationView. Photos,
// camera captures and arbitrary files all end at the same place: append
// a PendingAttachment for the composer to hand to the next send, and
// record per-id metadata so loaded/realtime bubbles can re-hydrate.
// Kept together because they share the multipart-upload call shape and
// error UX.

/// Single-file upload cap — mirrors MAX_UPLOAD_BYTES on the edge worker.
/// Pre-checked client-side only to give a friendlier message than the
/// server's 413.
private let maxUploadBytes = 25 * 1024 * 1024

extension ConversationView {

    /// Record an uploaded attachment: append it to the composer tray and
    /// stash its metadata so AttachmentGrid can render loaded/realtime
    /// copies of the message later.
    private func registerUpload(_ pending: PendingAttachment) {
        pendingAttachments.append(pending)
        attachmentMetaById[pending.id] = pending.asAttachment()
    }

    /// PhotosPicker callback. Each picked item is loaded as raw Data,
    /// uploaded to /v1/upload, and the returned id added to
    /// `pendingAttachments`. Errors surface via `self.error`.
    func ingestPhotos(_ items: [PhotosPickerItem]) async {
        guard let api else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
            do {
                let response: UploadResponse = try await api.upload(
                    "v1/upload",
                    fileData: data,
                    fileName: "image-\(UUID().uuidString.prefix(8)).\(ext)",
                    mime: mime,
                    extraFields: ["conversationId": conversation.id]
                )
                registerUpload(PendingAttachment(
                    id: response.id, mime: response.mime, size: response.size
                ))
                Haptics.tap()
            } catch {
                self.error = "上传失败: \(error.localizedDescription)"
                Haptics.error()
            }
        }
        photoPickerItems = []
    }

    /// Same upload flow as `ingestPhotos`, but for one-shot camera captures.
    /// JPEG-encode at 0.85 (same balance the rest of the app uses) so the
    /// upload size matches what users get from the library picker.
    func ingestCameraImage(_ image: UIImage) async {
        defer { cameraImage = nil }
        guard let api, let data = image.jpegData(compressionQuality: 0.85) else { return }
        do {
            let response: UploadResponse = try await api.upload(
                "v1/upload",
                fileData: data,
                fileName: "camera-\(UUID().uuidString.prefix(8)).jpg",
                mime: "image/jpeg",
                extraFields: ["conversationId": conversation.id]
            )
            registerUpload(PendingAttachment(
                id: response.id, mime: response.mime, size: response.size
            ))
            Haptics.tap()
        } catch {
            self.error = "上传失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    /// Document-picker callback — uploads arbitrary files (any type). The
    /// picked URLs are security-scoped, so each read is bracketed by
    /// start/stopAccessingSecurityScopedResource. MIME is derived from
    /// the extension; the original filename rides along so the bubble
    /// can render an icon+name chip.
    func ingestFiles(_ urls: [URL]) async {
        guard let api else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let filename = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                self.error = "无法读取文件: \(filename)"
                Haptics.error()
                continue
            }
            if data.count > maxUploadBytes {
                self.error = "文件过大（上限 25 MB）: \(filename)"
                Haptics.error()
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            do {
                let response: UploadResponse = try await api.upload(
                    "v1/upload",
                    fileData: data,
                    fileName: filename,
                    mime: mime,
                    extraFields: ["conversationId": conversation.id]
                )
                registerUpload(PendingAttachment(
                    id: response.id,
                    mime: response.mime,
                    size: response.size,
                    filename: response.filename ?? filename
                ))
                Haptics.tap()
            } catch {
                self.error = "上传失败: \(error.localizedDescription)"
                Haptics.error()
            }
        }
    }
}
