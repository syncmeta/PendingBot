import SwiftUI
import Supabase

/// Loads an auth-gated image from the Worker (`/v1/uploads/<id>`). Cross-platform
/// (iOS + macOS) — pure Foundation fetch + `PlatformImage` decode, no UIKit.
///
/// That endpoint sits behind `requireSession()` — it only honours an
/// `Authorization: Bearer <jwt>` header. A bare `AsyncImage` can't carry
/// headers, so it always gets a 401 and renders blank; we fetch the bytes
/// ourselves with the JWT attached. URLSession's HTTP cache honours the
/// response's `immutable, max-age=1y`, so each id only hits the wire once.
struct ServerImage: View {
    let path: String
    let serverURL: URL
    var contentMode: ContentMode = .fit

    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        image = nil
        failed = false
        let absolute = serverURL.appendingPathComponent(path.trimmingPrefixSlash())
        guard let token = try? await SupabaseStack.shared.auth.session.accessToken else {
            failed = true
            return
        }
        var req = URLRequest(url: absolute)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let decoded = PlatformImage(data: data) else {
                failed = true
                return
            }
            image = decoded
        } catch {
            failed = true
        }
    }
}

private extension String {
    /// Strip a single leading slash so .appendingPathComponent doesn't end
    /// up with a doubled-up `//uploads/…`.
    func trimmingPrefixSlash() -> String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}

#if os(iOS)
/// Full-screen viewer for a tapped attachment image — pinch to zoom,
/// drag to pan when zoomed, double-tap to toggle 1×/2×. Tapping the
/// backdrop or the close button dismisses. iOS-only (uses `Theme` + touch
/// gestures); Mac doesn't surface a full-screen pinch viewer yet.
struct ImageViewer: View {
    let path: String
    let serverURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { dismiss() }
            ServerImage(path: path, serverURL: serverURL, contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = min(max(steadyScale * v, 1), 5) }
                        .onEnded { _ in
                            steadyScale = scale
                            if scale <= 1 { resetPan() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(
                                width: steadyOffset.width + v.translation.width,
                                height: steadyOffset.height + v.translation.height)
                        }
                        .onEnded { _ in steadyOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 {
                            scale = 1; steadyScale = 1; resetPan()
                        } else {
                            scale = 2; steadyScale = 2
                        }
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(Theme.Fonts.glyph(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
    }

    private func resetPan() {
        offset = .zero
        steadyOffset = .zero
    }
}
#endif
