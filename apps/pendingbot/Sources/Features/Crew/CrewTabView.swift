import SwiftUI

/// The 机组 tab — a coding-session remote control. PendingBot lists crew
/// sessions running on runners (PendingCrew Mac), watches their progress,
/// approves permission requests, steers them, and launches new tasks.
/// Execution never happens here (see the spec).
///
/// Structure mirrors the other tabs' `FeatureSurface` shape:
///   * compact (iPhone): a `NavigationStack` list → detail push,
///   * wide (iPad/Mac): the `WideRootView` three-column shell drives
///     `listColumn` + `detailColumn` off a shared `Selection` (session id).
struct CrewTabView: View {
    @Environment(\.api) private var api

    /// Wide-shell injection: the list column writes selection here, the detail
    /// column reads it. nil in compact mode (own NavigationStack path).
    var externalSelection: Binding<String?>? = nil
    /// Render only the bare list body (no chrome / NavigationStack) — set by
    /// `listColumn(...)` so it slots into the shell's middle column.
    var renderAsMacListColumn = false

    var body: some View {
        compactRoot()
    }
}

// MARK: - FeatureSurface (wide shell)

extension CrewTabView: FeatureSurface {
    typealias Selection = String

    func listColumn(selection: Binding<String?>) -> some View {
        var view = self
        view.externalSelection = selection
        view.renderAsMacListColumn = true
        return view
    }

    func detailColumn(selection: String?) -> some View {
        Group {
            if let sessionId = selection {
                NavigationStack {
                    CrewSessionDetailView(sessionId: sessionId)
                }
                .id(sessionId)
            } else {
                EmptyDetailHint(systemImage: "person.3.sequence")
            }
        }
    }

    func compactRoot() -> some View {
        CrewListView(
            externalSelection: externalSelection,
            embedInNavigationStack: !renderAsMacListColumn
        )
    }
}
