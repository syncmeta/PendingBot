import Foundation

/// Pending (not-yet-uploaded) composer attachment. Source-of-truth type held by
/// `CrewChatView` (the send path uploads from these, then clears them). Bridged
/// to the vendored `ComposerView`'s `PendingAttachment` for tray display.
///
/// Extracted from the now-deleted `CrewComposer.swift` (A11) so it stays
/// available cross-platform once the chat views are un-gated (A12).
struct PendingComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let mime: String
    let data: Data

    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
    var byteSize: Int { data.count }
}
