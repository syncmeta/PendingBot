import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import CoreGraphics
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

private struct PickedImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedImageData(data: data)
        }
    }
}

extension ConversationView {

    /// Add a local placeholder before the network upload starts so the
    /// composer reflects the user's selection immediately.
    private func startUploadPlaceholder(
        mime: String,
        size: Int,
        filename: String? = nil,
        previewData: Data? = nil
    ) -> String {
        let localId = "local-upload-\(UUID().uuidString)"
        pendingAttachments.append(PendingAttachment(
            id: localId,
            mime: mime,
            size: size,
            filename: filename,
            uploadState: .uploading,
            localPreviewData: previewData
        ))
        return localId
    }

    /// Record an uploaded attachment: replace its local placeholder (if any)
    /// and stash metadata so AttachmentGrid can render loaded/realtime copies.
    private func registerUpload(_ pending: PendingAttachment, replacing localId: String? = nil) {
        if let localId, let idx = pendingAttachments.firstIndex(where: { $0.id == localId }) {
            pendingAttachments[idx] = pending
        } else {
            pendingAttachments.append(pending)
        }
        if let remoteId = pending.uploadedAttachmentId {
            attachmentMetaById[remoteId] = pending.asAttachment()
        }
    }

    private func markUploadFailed(_ localId: String, message: String) {
        guard let idx = pendingAttachments.firstIndex(where: { $0.id == localId }) else { return }
        pendingAttachments[idx].uploadState = .failed
        pendingAttachments[idx].errorMessage = message
    }

    /// Downscale to a 2048 px long edge and JPEG-encode at 0.85. Full-res
    /// library/camera photos run 10–48 MP — uploading them whole is slow
    /// and can push past the edge's 5 MB inline-vision cap. 2048 px keeps
    /// ample detail for the model while landing well under 1 MB.
    ///
    /// Cross-platform: the downscale runs through CoreGraphics on the
    /// underlying CGImage (works identically on iOS/macOS), and the final
    /// JPEG encode goes through `PlatformImage.jpegData` (UIImage.jpegData on
    /// iOS, NSBitmapImageRep on macOS).
    private func encodeImageForUpload(_ image: PlatformImage) -> Data? {
        let maxEdge: CGFloat = 2048
        guard let cg = image.uploadCGImage else { return nil }
        let pxWidth = CGFloat(cg.width)
        let pxHeight = CGFloat(cg.height)
        let longEdge = max(pxWidth, pxHeight)
        guard longEdge > 0 else { return nil }

        if longEdge <= maxEdge {
            // No downscale needed — encode the original bitmap straight.
            return image.jpegData(quality: 0.85)
        }

        let factor = maxEdge / longEdge
        let newW = Int((pxWidth * factor).rounded())
        let newH = Int((pxHeight * factor).rounded())
        guard newW > 0, newH > 0,
              let ctx = CGContext(
                data: nil,
                width: newW,
                height: newH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image.jpegData(quality: 0.85) }

        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaledCG = ctx.makeImage() else {
            return image.jpegData(quality: 0.85)
        }
        return PlatformImage.fromCGImage(scaledCG).jpegData(quality: 0.85)
    }

    /// PhotosPicker callback. Each picked item is loaded as raw Data,
    /// uploaded to /v1/upload, and the returned id added to
    /// `pendingAttachments`. Errors surface via `self.error`.
    func ingestPhotos(_ items: [PhotosPickerItem]) async {
        guard let api else { return }
        for item in items {
            let data: Data?
            if let imageData = try? await item.loadTransferable(type: PickedImageData.self) {
                data = imageData.data
            } else if let raw = try? await item.loadTransferable(type: Data.self) {
                data = raw
            } else if let url = try? await item.loadTransferable(type: URL.self),
                      let raw = try? Data(contentsOf: url) {
                data = raw
            } else {
                data = nil
            }
            guard let data else {
                let localId = startUploadPlaceholder(
                    mime: "image/jpeg",
                    size: 0,
                    filename: "图片"
                )
                markUploadFailed(localId, message: "读取图片失败")
                self.error = "读取图片失败"
                Haptics.error()
                continue
            }
            // Library photos are typically HEIC. The edge attachment
            // classifier and the vision models only handle jpeg/png/gif/
            // webp — a HEIC upload lands as a generic 'file', so the bot
            // can't see it and the bubble renders no image. Re-encode to
            // JPEG up-front (same as the camera path); this also shrinks
            // the payload so the upload doesn't crawl on a mobile link.
            let uploadData: Data
            let mime: String
            let ext: String
            if let image = PlatformImage.decode(data),
               let jpeg = encodeImageForUpload(image) {
                uploadData = jpeg
                mime = "image/jpeg"
                ext = "jpg"
            } else {
                uploadData = data
                mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
            }
            let localId = startUploadPlaceholder(
                mime: mime,
                size: uploadData.count,
                previewData: uploadData
            )
            do {
                let response: UploadResponse = try await api.upload(
                    "v1/upload",
                    fileData: uploadData,
                    fileName: "image-\(UUID().uuidString.prefix(8)).\(ext)",
                    mime: mime,
                    extraFields: ["conversationId": conversation.id]
                )
                registerUpload(PendingAttachment(
                    id: localId,
                    remoteId: response.id,
                    mime: response.mime,
                    size: response.size,
                    uploadState: .uploaded
                ), replacing: localId)
                Haptics.tap()
            } catch {
                let message = "上传失败: \(error.localizedDescription)"
                markUploadFailed(localId, message: message)
                self.error = message
                Haptics.error()
            }
        }
        photoPickerItems = []
    }

    #if os(iOS)
    /// Same upload flow as `ingestPhotos`, but for one-shot camera captures.
    /// JPEG-encode at 0.85 (same balance the rest of the app uses) so the
    /// upload size matches what users get from the library picker. iOS-only —
    /// camera capture (CameraPicker / UIImagePickerController) doesn't exist
    /// on macOS.
    func ingestCameraImage(_ image: UIImage) async {
        defer { cameraImage = nil }
        guard let api, let data = encodeImageForUpload(image) else { return }
        let localId = startUploadPlaceholder(
            mime: "image/jpeg",
            size: data.count,
            previewData: data
        )
        do {
            let response: UploadResponse = try await api.upload(
                "v1/upload",
                fileData: data,
                fileName: "camera-\(UUID().uuidString.prefix(8)).jpg",
                mime: "image/jpeg",
                extraFields: ["conversationId": conversation.id]
            )
            registerUpload(PendingAttachment(
                id: localId,
                remoteId: response.id,
                mime: response.mime,
                size: response.size,
                uploadState: .uploaded
            ), replacing: localId)
            Haptics.tap()
        } catch {
            let message = "上传失败: \(error.localizedDescription)"
            markUploadFailed(localId, message: message)
            self.error = message
            Haptics.error()
        }
    }
    #endif

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
            let localId = startUploadPlaceholder(
                mime: mime,
                size: data.count,
                filename: filename
            )
            do {
                let response: UploadResponse = try await api.upload(
                    "v1/upload",
                    fileData: data,
                    fileName: filename,
                    mime: mime,
                    extraFields: ["conversationId": conversation.id]
                )
                registerUpload(PendingAttachment(
                    id: localId,
                    remoteId: response.id,
                    mime: response.mime,
                    size: response.size,
                    filename: response.filename ?? filename,
                    uploadState: .uploaded
                ), replacing: localId)
                Haptics.tap()
            } catch {
                let message = "上传失败: \(error.localizedDescription)"
                markUploadFailed(localId, message: message)
                self.error = message
                Haptics.error()
            }
        }
    }
}
