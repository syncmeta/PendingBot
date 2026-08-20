import SwiftUI

/// Avatar view that prefers an uploaded image (`/v1/uploads/<id>`) when
/// the user has set one, falling back to the deterministic `BotAvatar`
/// keyed off `seed` otherwise.
///
/// `/v1/uploads/<id>` is auth-gated, so we can't use `AsyncImage`
/// directly — there's no way to inject the Authorization header. The
/// loader fetches once with the current JWT, caches the bytes in a
/// process-lifetime dictionary keyed by id, and renders the resulting
/// `PlatformImage`.
struct UserAvatar: View {
    let seed: String
    let attachmentId: String?
    var size: CGFloat = 36

    @State private var image: PlatformImage?

    init(seed: String, attachmentId: String?, size: CGFloat = 36) {
        self.seed = seed
        self.attachmentId = attachmentId
        self.size = size
        // Seed the image synchronously from the process-lifetime cache so a
        // warm hit paints the real avatar on the FIRST frame. Without this the
        // cache read happens inside `.task` (which SwiftUI runs *after* the
        // first paint), so every appearance — including tab switches that
        // recreate the view — flashed the `BotAvatar` fallback for a frame
        // before the photo swapped in.
        if let id = attachmentId, !id.isEmpty {
            _image = State(initialValue: AvatarCache.shared.image(for: id))
        } else {
            _image = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            } else {
                BotAvatar(seed: seed, size: size)
            }
        }
        .task(id: attachmentId ?? "") {
            await reloadIfNeeded()
        }
    }

    private func reloadIfNeeded() async {
        guard let id = attachmentId, !id.isEmpty else {
            image = nil
            return
        }
        if let cached = AvatarCache.shared.image(for: id) {
            image = cached
            return
        }
        do {
            let workerURL = HostedConfig.environment.workerURL
            var req = URLRequest(url: workerURL.appendingPathComponent("v1/uploads/\(id)"))
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            guard let img = PlatformImage.decode(data) else { return }
            AvatarCache.shared.store(img, for: id)
            image = img
        } catch {
            // Silent — fallback BotAvatar already on screen.
        }
    }
}

/// Process-lifetime cache so swapping between tabs / scrolling doesn't
/// re-fetch the same blob. The endpoint is immutable so first byte is
/// the only one we ever need; URLSession's HTTP cache could handle this
/// too, but keeping a PlatformImage map skips re-decoding.
final class AvatarCache: @unchecked Sendable {
    static let shared = AvatarCache()
    private let lock = NSLock()
    private var store: [String: PlatformImage] = [:]

    func image(for id: String) -> PlatformImage? {
        lock.lock(); defer { lock.unlock() }
        return store[id]
    }

    func store(_ image: PlatformImage, for id: String) {
        lock.lock(); defer { lock.unlock() }
        store[id] = image
    }

    /// Wipe — call from sign-out so a different account can't see the
    /// previous user's avatar bytes.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}
