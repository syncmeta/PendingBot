import SwiftUI

/// Keyboard hint for `platformKeyboard(_:)`. Top-level (not nested in the
/// `View` extension) because Swift disallows declaring an enum inside an
/// extension that also adds methods referencing it.
enum PlatformKeyboard { case url, number, `default` }

extension ToolbarItemPlacement {
    /// Leading nav-bar slot on iOS; cancellation slot on macOS.
    static var platformLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .cancellationAction
        #endif
    }
    /// Trailing nav-bar slot on iOS; primary-action slot on macOS.
    static var platformTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

/// Cross-platform View modifier shims. On iOS each forwards to the real
/// iOS-only modifier; on macOS it's a no-op so shared `Features/*` views
/// compile on both platforms without `#if os` at every call site.
extension View {
    @ViewBuilder func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func platformAutocapitalization(_ never: Bool = true) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(never ? .never : .sentences)
        #else
        self
        #endif
    }

    @ViewBuilder func platformKeyboard(_ kind: PlatformKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .url: self.keyboardType(.URL)
        case .number: self.keyboardType(.numberPad)
        case .default: self
        }
        #else
        self
        #endif
    }

    @ViewBuilder func platformDetents(_ detents: Set<PresentationDetent>) -> some View {
        #if os(iOS)
        self.presentationDetents(detents)
        #else
        self
        #endif
    }

    @ViewBuilder func platformDragIndicator() -> some View {
        #if os(iOS)
        self.presentationDragIndicator(.visible)
        #else
        self
        #endif
    }

    /// macOS sheets size to fit their content, so a sheet whose body is a
    /// greedy `List` collapses that list to ~0 height — the rows vanish and
    /// only the header/toolbar show. Give such sheets an explicit min size
    /// on macOS so the List has room to render. No-op on iOS, where sheets
    /// already get a full/detented height. Apply to the sheet's root
    /// content (the NavigationStack inside the `.sheet { }` builder).
    @ViewBuilder func macSheetMinSize(
        minWidth: CGFloat = 560, minHeight: CGFloat = 640
    ) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }

    @ViewBuilder func platformListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    @ViewBuilder func platformTabBarVisibility(_ visible: Bool) -> some View {
        #if os(iOS)
        self.toolbar(visible ? .visible : .hidden, for: .tabBar)
        #else
        self
        #endif
    }

    @ViewBuilder func platformScrollKeyboardDismiss() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }

    @ViewBuilder func platformToolbarColorScheme(_ scheme: ColorScheme) -> some View {
        #if os(iOS)
        self.toolbarColorScheme(scheme, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder func platformFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        self.sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}
