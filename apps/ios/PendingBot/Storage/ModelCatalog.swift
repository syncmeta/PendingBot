import Foundation
import Combine

/// Client-side cache of the model catalog (`/v1/openrouter/models`).
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

    private var loaded = false
    private var inFlight: Task<Void, Never>?

    private init() {}

    /// Fetch the catalog once. Safe to call from every view's `.task` —
    /// later calls join the in-flight task or no-op once loaded. A failed
    /// fetch leaves `loaded` false so the next caller retries.
    func loadIfNeeded() {
        guard !loaded, inFlight == nil else { return }
        inFlight = Task {
            defer { inFlight = nil }
            do {
                let models: [OpenRouterModel] = try await APIClient().get("v1/openrouter/models")
                var map: [String: OpenRouterModel] = [:]
                for m in models {
                    map[m.slug] = m
                    if let local = m.local_slug { map[local] = m }
                }
                bySlug = map
                loaded = true
            } catch {
                // Leave `loaded` false — a later view appearance retries.
            }
        }
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
