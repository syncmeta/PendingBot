import Foundation
import Combine

/// Client-side cache of the model catalog (`/v1/models`).
///
/// Bots store a bare slug (`z-ai/glm-5.1`) in `model_id`; the UI wants the
/// friendly `display_name` ("GLM 5.1") and the blended price multiplier.
/// This store fetches the catalog once per launch and resolves both — views
/// observe it so labels upgrade from the slug fallback once the fetch lands.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    /// Catalog rows keyed by every slug they can be referenced under —
    /// the OpenRouter id and, when curated, our local slug.
    @Published private(set) var bySlug: [String: OpenRouterModel] = [:]
    /// Full row list in server order — the model-pool editor builds its
    /// browse list from this (single source of truth, no second fetch).
    @Published private(set) var models: [OpenRouterModel] = []

    private var loaded = false
    private var inFlight: Task<Void, Never>?

    /// Disk cache of the last successful catalog fetch. Read on first
    /// `loadIfNeeded()` for an instant (offline-tolerant) paint, then
    /// refreshed from the network in the background.
    private static let cacheURL: URL? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent("model_catalog.json")
    }()

    private init() {}

    /// Fetch the catalog once. Safe to call from every view's `.task` —
    /// later calls join the in-flight task or no-op once loaded. A failed
    /// fetch leaves `loaded` false so the next caller retries. On the first
    /// call the disk cache is painted synchronously-fast before the network
    /// refresh lands.
    func loadIfNeeded() {
        guard !loaded, inFlight == nil else { return }
        // Instant paint from disk while the network fetch is in flight.
        // Only seeds when empty so a fresher in-memory map is never clobbered.
        if bySlug.isEmpty, let cached = Self.readDiskCache() {
            apply(cached)
        }
        inFlight = Task {
            defer { inFlight = nil }
            do {
                let fetched: [OpenRouterModel] = try await APIClient().get("v1/models")
                apply(fetched)
                loaded = true
                Self.writeDiskCache(fetched)
            } catch {
                // Leave `loaded` false — a later view appearance retries.
                // The disk-cache paint (if any) keeps the UI usable offline.
            }
        }
    }

    /// Build the slug map + ordered list from a row array.
    private func apply(_ rows: [OpenRouterModel]) {
        var map: [String: OpenRouterModel] = [:]
        for m in rows {
            map[m.slug] = m
            if let local = m.local_slug { map[local] = m }
        }
        bySlug = map
        models = rows
    }

    private static func readDiskCache() -> [OpenRouterModel]? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([OpenRouterModel].self, from: data),
              !rows.isEmpty else { return nil }
        return rows
    }

    private static func writeDiskCache(_ rows: [OpenRouterModel]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Friendly model name for a stored slug. Falls back to the slug's tail
    /// segment when the catalog hasn't loaded or doesn't know the model.
    func displayName(for slug: String) -> String {
        if let m = bySlug[slug] { return m.display_name }
        return slug.split(separator: "/").last.map(String.init) ?? slug
    }

    /// Blended price multiplier (USD per 1M tokens, 7:2:1) for a slug.
    /// nil when the model is unknown or unpriced.
    func priceMultiplier(for slug: String) -> Double? {
        bySlug[slug]?.blended_usd_per_million
    }

    /// "1x" / "0.5x" / "12x" — blended USD per 1M rendered as a multiplier.
    /// $1 / 1M tokens reads as `1x`.
    static func formatMultiplier(_ value: Double) -> String {
        if value >= 10 { return "\(Int(value.rounded()))x" }
        let s = String(format: "%.1f", value)
        let trimmed = s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        return "\(trimmed)x"
    }
}
