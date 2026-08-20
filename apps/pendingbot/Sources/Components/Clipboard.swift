import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform clipboard write, hiding the `UIPasteboard` / `NSPasteboard`
/// split so shared views can copy text without `#if os` at the call site.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
