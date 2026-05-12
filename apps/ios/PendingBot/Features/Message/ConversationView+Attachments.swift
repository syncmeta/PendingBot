import PhotosUI
import SwiftUI
import UIKit

// Image upload helpers extracted from ConversationView. Both end at the
// same place: append a PendingAttachment for the composer to hand to the
// next send. Kept together because they share the multipart-upload call
// shape and error UX.

extension ConversationView {

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
                pendingAttachments.append(PendingAttachment(
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
            pendingAttachments.append(PendingAttachment(
                id: response.id, mime: response.mime, size: response.size
            ))
            Haptics.tap()
        } catch {
            self.error = "上传失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}
