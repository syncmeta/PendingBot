import Foundation

// Replaces URLCache.shared with one whose backing directory is
// attribute-marked NSFileProtectionComplete, so cached HTTP response
// bodies (mainly attachment images served by /v1/uploads/:id) sit
// encrypted at rest while the device is locked. Default app-sandbox
// protection is NSFileProtectionCompleteUntilFirstUserAuthentication —
// good enough vs. a powered-off device, but not vs. brief device
// access after first-unlock. The recall path already scrubs URLCache
// for recalled attachments; this guards the bytes during the window
// between when they're cached and when (or if) recall fires.
//
// We use `CompleteUnlessOpen` rather than full `Complete` because
// URLCache keeps `Cache.db` open while the URLSession backing it is
// live — full `Complete` would make the cache unreadable during
// background tasks. `CompleteUnlessOpen` is the documented Apple
// recommendation for files that need to outlive lock events.
enum ProtectedURLCache {

    /// Call once at app launch, BEFORE the first URLSession.shared
    /// request. Idempotent. Disk failures fall back to a default
    /// shared cache (i.e. unchanged behavior) — never crashes the app.
    static func install() {
        let fm = FileManager.default
        guard let cachesRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = cachesRoot.appendingPathComponent("ProtectedURLCache", isDirectory: true)

        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
                )
            } else {
                // Re-apply on every launch in case the user upgraded from
                // an older build that used the default protection class.
                try fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: dir.path
                )
            }
        } catch {
            // Couldn't create / re-attribute — leave URLCache.shared as-is.
            return
        }

        // Sizes match URLSessionConfiguration.default defaults: 4 MB RAM,
        // 20 MB disk. Image bodies served by /v1/uploads/:id are <= 10
        // MB each, so 20 MB holds 2-3 in-flight bubbles; the auth-gated
        // serving means a cache miss costs a Worker round-trip per image,
        // so we want some disk capacity.
        let memCapacityBytes = 4 * 1024 * 1024
        let diskCapacityBytes = 20 * 1024 * 1024
        URLCache.shared = URLCache(
            memoryCapacity: memCapacityBytes,
            diskCapacity: diskCapacityBytes,
            directory: dir,
        )
    }
}
