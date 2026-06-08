import SwiftUI
#if os(iOS)
import UIKit
/// The platform's bitmap image type — `UIImage` on iOS, `NSImage` on macOS.
/// Lets cross-platform views (e.g. `ServerImage`) decode + hold an image without
/// `#if` at every call site.
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Build a SwiftUI `Image` from a platform bitmap, hiding the
    /// `uiImage:` / `nsImage:` split.
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Decode raw image bytes into a platform bitmap, hiding the
    /// `UIImage(data:)` / `NSImage(data:)` split.
    static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }
}
