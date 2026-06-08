import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#endif

/// Cross-platform QR bitmap generation via CoreImage, returning the
/// platform-native `PlatformImage` (`UIImage` / `NSImage`).
enum QRCode {
    static func image(_ payload: String, scale: CGFloat = 10) -> PlatformImage? {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        guard let cg = ctx.createCGImage(output, from: output.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #elseif os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
        #endif
    }
}
