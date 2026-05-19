import SwiftUI
import UIKit
import Supabase

/// Loads an auth-gated image from the Worker (`/v1/uploads/<id>`).
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

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
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
                  let ui = UIImage(data: data) else {
                failed = true
                return
            }
            image = ui
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
