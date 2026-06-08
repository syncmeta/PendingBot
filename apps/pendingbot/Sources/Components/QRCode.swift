import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#endif

/// Cross-platform QR bitmap generation via CoreImage, returning the
/// platform-native `PlatformImage` (`UIImage` / `NSImage`).
///
/// Supports an optional false-color tint (dark/light modules) and a
/// quiet-zone border, all done in CoreImage so the same code path runs on
/// iOS and macOS (the old iOS-only `UIGraphicsImageRenderer` quiet-zone is
/// reproduced via a CIImage composite). Defaults reproduce the original
/// plain black/white behavior so existing callers are unaffected.
enum QRCode {
    static func image(_ payload: String,
                      scale: CGFloat = 10,
                      correctionLevel: String = "M",
                      dark: CIColor = .black,
                      light: CIColor = .white,
                      quietModules: CGFloat = 0) -> PlatformImage? {
        let ctx = CIContext()

        // 1. Generate the QR matrix at the requested correction level.
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let qr = filter.outputImage else { return nil }

        // 2. Recolour modules (dark) / background (light) via falseColor.
        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = qr
        colorFilter.color0 = dark
        colorFilter.color1 = light
        guard let colored = colorFilter.outputImage else { return nil }

        // 3. Scale up so each module is `scale` points.
        let scaled = colored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 4. Optional quiet zone: composite the scaled QR centered over a
        //    solid `light` background sized `inner + 2*quiet` on each axis.
        let finalImage: CIImage
        let finalExtent: CGRect
        if quietModules > 0 {
            let quiet = scale * quietModules
            let inner = scaled.extent
            let total = CGRect(x: 0, y: 0,
                               width: inner.width + 2 * quiet,
                               height: inner.height + 2 * quiet)
            let background = CIImage(color: light).cropped(to: total)
            // Re-origin the scaled QR to (0,0), then offset by the quiet margin.
            let centered = scaled
                .transformed(by: CGAffineTransform(translationX: -inner.origin.x,
                                                   y: -inner.origin.y))
                .transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            finalImage = centered.composited(over: background)
            finalExtent = total
        } else {
            finalImage = scaled
            finalExtent = scaled.extent
        }

        guard let cg = ctx.createCGImage(finalImage, from: finalExtent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #elseif os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: finalExtent.width, height: finalExtent.height))
        #endif
    }
}
