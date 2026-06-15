import Foundation

// Model-preset catalog API. The edge endpoint `GET /v1/model-presets` reads
// the board-managed `model_presets` rules and resolves each against the live
// OpenRouter catalog (旗舰 / 各家最新 / 最热门 / 速度快 …), returning the
// already-resolved model sets the 新建机器人 first screen renders. Bots store
// only the selected slugs; the union is re-resolved server-side per turn.
// See apps/edge/src/routes/model-presets.ts.
extension APIClient {
    /// Fetch the enabled model presets (sorted by the board's sort_order).
    func modelPresets() async throws -> [ModelPreset] {
        try await get("v1/model-presets")
    }
}
