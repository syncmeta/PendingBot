import SwiftUI

/// Pill button that surfaces the currently-selected model. Tap opens
/// `ModelPickerSheet` to browse the OpenRouter catalog. `slug` empty means
/// "use the bot's default" — rendered as a muted placeholder.
struct ModelPickerButton: View {
    @Binding var slug: String
    /// Optional companion binding for the bot's API route pin. When set,
    /// picking a model from a non-default catalog section (e.g. the
    /// OpenAI-native list) writes that model's `model_provider` here.
    /// Surfaces that only pick a model (envelope/vision) leave this nil.
    var modelProvider: Binding<String?>? = nil
    var placeholder: String = "模型选择"

    @EnvironmentObject private var catalog: ModelCatalog
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
            Haptics.tap()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cube.transparent")
                    .font(Theme.Fonts.glyph(size: 11, weight: .semibold))
                    .foregroundStyle(slug.isEmpty ? Theme.Palette.inkMuted : Theme.Palette.accent)
                Text(slug.isEmpty ? placeholder : catalog.displayName(for: slug))
                    .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                    .foregroundStyle(slug.isEmpty ? Theme.Palette.inkMuted : Theme.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Fonts.glyph(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.Palette.surfaceMuted))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            ModelPickerSheet(initial: slug,
                             showLegend: true,
                             onPick: { picked in
                slug = picked?.slug ?? ""
                modelProvider?.wrappedValue = picked?.model_provider
                showSheet = false
            })
            .presentationDragIndicator(.visible)
            .tint(Theme.Palette.accent)
        }
    }
}

/// Sheet that lists every OpenRouter model. Search filters slug / name /
/// provider. Picking a row dismisses; an optional "use default" row clears
/// the binding.
struct ModelPickerSheet: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    let initial: String
    var allowsClear: Bool = false
    /// Label shown on the "clear selection" row when `allowsClear` is on.
    /// Only the envelope collaborator picker uses this today ("无协作者");
    /// the bot model picker dropped its clear row in favour of `showLegend`.
    var clearLabel: String = "无协作者"
    /// When true, only show models whose server-side `supports_vision` is
    /// true. Used by the per-conv vision-model picker — picking a non-
    /// vision model there would just route into a runtime error at the
    /// upstream provider, so filtering up front is the right move.
    var visionOnly: Bool = false
    /// When true, the picker leads with a non-interactive legend row that
    /// labels what each column means (name / slug / 价格倍率) using
    /// placeholder text. Used by the bot model picker, which replaced its
    /// old "跟随机器人默认" clear row with this explainer.
    var showLegend: Bool = false
    var onPick: (OpenRouterModel?) -> Void

    @State private var allModels: [OpenRouterModel] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query: String = ""
    @State private var expandedProviders: Set<String> = []

    private var catalogModels: [OpenRouterModel] {
        allModels.filter { !ModelCatalogFilters.isNativeBackedOpenRouterRow($0) }
    }

    private var filtered: [OpenRouterModel] {
        let visionFiltered = visionOnly
            ? catalogModels.filter { $0.supports_vision == true }
            : catalogModels
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return visionFiltered }
        return visionFiltered.filter {
            $0.slug.lowercased().contains(q)
            || $0.display_name.lowercased().contains(q)
            || $0.provider.lowercased().contains(q)
        }
    }

    /// Synthetic group keys for the native catalogs — kept distinct from
    /// their OpenRouter vendor counterparts so each native route is its
    /// own collapsible section. The three native sections sort to the
    /// TOP of the picker (see `vendorPriority`).
    private static let nativeAnthropicKey = "__native_anthropic__"
    private static let nativeGeminiKey = "__native_gemini__"
    private static let nativeOpenAIKey = "__native_openai__"

    /// The group a model belongs to: its own collapsible section for any
    /// of the native catalogs, otherwise its OpenRouter vendor.
    private func groupKey(_ m: OpenRouterModel) -> String {
        switch m.source {
        case "anthropic": return Self.nativeAnthropicKey
        case "google-ai-studio": return Self.nativeGeminiKey
        case "openai": return Self.nativeOpenAIKey
        default: return m.provider
        }
    }

    /// Groups from the (already filtered) model list, ordered by
    /// `Self.vendorPriority` (native catalogs first, then most popular
    /// OpenRouter vendors); unknown vendors trail alphabetically.
    private var groupedFiltered: [(provider: String, models: [OpenRouterModel])] {
        let buckets = Dictionary(grouping: filtered, by: { groupKey($0) })
        let priorityIndex = Dictionary(uniqueKeysWithValues: Self.vendorPriority.enumerated().map { ($1, $0) })
        return buckets.keys.sorted { a, b in
            switch (priorityIndex[a], priorityIndex[b]) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }.map { ($0, buckets[$0] ?? []) }
    }

    /// Vendor order. The three native catalogs sort to the top so the
    /// user sees them before the (much larger) OpenRouter long tail.
    /// OpenRouter vendor order is based on its rankings page (most-used
    /// first); anything not listed sorts alphabetically after these.
    private static let vendorPriority: [String] = [
        nativeAnthropicKey, nativeGeminiKey, nativeOpenAIKey,
        "google", "anthropic", "openai", "x-ai", "deepseek",
        "qwen", "moonshotai", "meta-llama", "mistralai", "z-ai",
    ]

    private static let vendorDisplayName: [String: String] = [
        "google": "Google",
        "anthropic": "Anthropic",
        "openai": "OpenAI",
        "x-ai": "xAI",
        "deepseek": "DeepSeek",
        "qwen": "Qwen",
        "moonshotai": "Moonshot",
        "meta-llama": "Meta",
        "mistralai": "Mistral",
        "z-ai": "Z.AI",
        nativeAnthropicKey: "Claude",
        nativeGeminiKey: "Gemini",
        nativeOpenAIKey: "GPT",
    ]

    private func vendorLabel(_ provider: String) -> String {
        Self.vendorDisplayName[provider] ?? provider
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, Theme.Metrics.gutter)
                        .padding(.top, 6)
                        .padding(.bottom, 10)

                    if loading && allModels.isEmpty {
                        Spacer()
                        ProgressView().tint(Theme.Palette.accent)
                        Spacer()
                    } else if let error, allModels.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("加载模型列表失败")
                                .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.ink)
                            Text(error)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.inkMuted)
                            Button("重试") { Task { await load() } }
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        Spacer()
                    } else {
                        list
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("选择模型")
                        .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
        .task { await load() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Fonts.glyph(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.inkMuted)
            TextField("搜索 slug / 名字 / 厂商", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(Theme.Fonts.rounded(size: 14, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        )
    }

    private var list: some View {
        List {
            if allowsClear && query.isEmpty {
                Section {
                    Button {
                        onPick(nil)
                        Haptics.success()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(Theme.Fonts.glyph(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.Palette.accent)
                            Text(clearLabel)
                                .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.ink)
                            Spacer(minLength: 8)
                            if initial.isEmpty {
                                Image(systemName: "checkmark")
                                    .font(Theme.Fonts.glyph(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Theme.Palette.surface)
            }
            if showLegend && query.isEmpty {
                legendSection
            }
            // While searching, force every group expanded so matches are
            // visible without the user having to tap each header.
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            let groups = groupedFiltered
            ForEach(Array(groups.enumerated()), id: \.element.provider) { item in
                let group = item.element
                let expanded = searching || expandedProviders.contains(group.provider)
                Section {
                    if expanded {
                        ForEach(group.models) { m in
                            Button {
                                onPick(m)
                                Haptics.success()
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.display_name)
                                            .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                                            .foregroundStyle(Theme.Palette.ink)
                                            .lineLimit(1)
                                        Text(m.slug)
                                            .font(Theme.Fonts.monoSmall)
                                            .foregroundStyle(Theme.Palette.inkMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    if let mult = m.blended_usd_per_million {
                                        Text(ModelCatalog.formatMultiplier(mult))
                                            .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                                            .foregroundStyle(Theme.Palette.inkMuted)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(Theme.Palette.surfaceMuted))
                                    }
                                    if m.slug == initial {
                                        Image(systemName: "checkmark")
                                            .font(Theme.Fonts.glyph(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.Palette.accent)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Button {
                        if searching { return }
                        if expandedProviders.contains(group.provider) {
                            expandedProviders.remove(group.provider)
                        } else {
                            expandedProviders.insert(group.provider)
                        }
                        Haptics.tap()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(Theme.Fonts.glyph(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.Palette.inkMuted)
                            Text(vendorLabel(group.provider))
                                .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                            Text("\(group.models.count)")
                                .font(Theme.Fonts.rounded(size: 11, weight: .regular))
                                .foregroundStyle(Theme.Palette.inkMuted)
                            Spacer()
                        }
                        .textCase(nil)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Theme.Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
    }

    /// Non-interactive sample row that names each column of a model row so
    /// the placeholder copy itself spells out the layout.
    private var legendSection: some View {
        Section {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("示例 模型名称")
                        .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Text("模型标识名")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("参考价格倍率")
                    .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.Palette.surfaceMuted))
            }
            .padding(.vertical, 4)
        } footer: {
            Text("每行就是一个模型：上面是名称，下面是模型标识名，右边是参考价格倍率。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .listRowBackground(Theme.Palette.surface)
    }

    private func load() async {
        guard let api else { return }
        loading = true; defer { loading = false }
        do {
            allModels = try await api.get("v1/models")
            error = nil
            // Auto-expand the group containing the currently-selected model
            // so the user lands on something visible instead of an all-collapsed
            // wall.
            if !initial.isEmpty,
               let match = catalogModels.first(where: { $0.slug == initial }) {
                expandedProviders.insert(groupKey(match))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// UI-only draft for the bot arena picker. It mirrors the persisted
/// `RandomModelConfig`, plus a concrete fallback model_id and the currently
/// resolved pool size so creation/settings screens can validate the choice.
struct ArenaModelSelection: Equatable, Hashable {
    var priceMin: Double?
    var priceMax: Double?
    var models: [String] = []
    var exclude: [String] = []
    var fallbackModel: String?
    var resolvedCount: Int = 0

    static func single(_ slug: String) -> ArenaModelSelection {
        ArenaModelSelection(models: slug.isEmpty ? [] : [slug],
                            fallbackModel: slug.isEmpty ? nil : slug,
                            resolvedCount: slug.isEmpty ? 0 : 1)
    }

    static func arena(_ config: RandomModelConfig?, fallbackModel: String?) -> ArenaModelSelection {
        guard let config else {
            return ArenaModelSelection(
                models: fallbackModel.map { [$0] } ?? [],
                fallbackModel: fallbackModel,
                resolvedCount: fallbackModel == nil ? 0 : 1)
        }
        return ArenaModelSelection(
            priceMin: config.price_min,
            priceMax: config.price_max,
            models: config.models ?? [],
            exclude: config.exclude ?? [],
            fallbackModel: fallbackModel,
            resolvedCount: 0)
    }

    var hasPriceRange: Bool {
        priceMin != nil || priceMax != nil
    }

    var isArenaReady: Bool {
        hasPriceRange || models.count >= 2 || resolvedCount >= 2
    }

    var persistedConfig: RandomModelConfig? {
        guard isArenaReady else { return nil }
        return RandomModelConfig(
            price_min: priceMin,
            price_max: priceMax,
            models: models.isEmpty ? nil : models,
            exclude: exclude.isEmpty ? nil : exclude)
    }

    var summary: String {
        if hasPriceRange || resolvedCount >= 2 {
            let lo = priceMin.map(Self.formatMultiplier) ?? "最小"
            let hi = priceMax.map(Self.formatMultiplier) ?? "最大"
            let count = resolvedCount > 0 ? " · \(resolvedCount) 个" : ""
            return "价格 \(lo) - \(hi)\(count)"
        }
        if models.count >= 2 { return "竞技场 · \(models.count) 个模型" }
        return fallbackModel ?? models.first ?? ""
    }

    private static func formatMultiplier(_ value: Double) -> String {
        if value >= 10 { return "\(Int(value.rounded()))x" }
        let s = String(format: "%.1f", value)
        let trimmed = s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        return "\(trimmed)x"
    }
}

private enum ModelCatalogFilters {
    private static let nativeBackedOpenRouterVendors: Set<String> = ["openai", "anthropic", "google"]

    static func isNativeBackedOpenRouterRow(_ model: OpenRouterModel) -> Bool {
        guard (model.source ?? "openrouter") == "openrouter" else { return false }
        let slug = model.slug.hasPrefix("~") ? String(model.slug.dropFirst()) : model.slug
        guard let vendor = slug.split(separator: "/", maxSplits: 1).first else { return false }
        return nativeBackedOpenRouterVendors.contains(String(vendor))
    }
}

private enum ArenaPriceRangeScale {
    static let numericMin: Double = 0
    static let numericMax: Double = 5
    private static let lowerSentinel: Double = -0.5
    private static let upperSentinel: Double = 5.5
    static let sliderBounds: ClosedRange<Double> = lowerSentinel...upperSentinel

    static func sliderLower(fromPriceMin priceMin: Double?) -> Double {
        guard let priceMin else { return lowerSentinel }
        return min(max(priceMin, numericMin), numericMax)
    }

    static func sliderUpper(fromPriceMax priceMax: Double?) -> Double {
        guard let priceMax else { return upperSentinel }
        return min(max(priceMax, numericMin), numericMax)
    }

    static func priceMin(fromSliderLower value: Double) -> Double? {
        guard value >= numericMin else { return nil }
        return rounded(min(max(value, numericMin), numericMax))
    }

    static func priceMax(fromSliderUpper value: Double) -> Double? {
        guard value <= numericMax else { return nil }
        return rounded(min(max(value, numericMin), numericMax))
    }

    static func lowerLabel(_ value: Double) -> String {
        guard value >= numericMin else { return "最小" }
        return formatMultiplier(value)
    }

    static func upperLabel(_ value: Double) -> String {
        guard value <= numericMax else { return "最大" }
        return formatMultiplier(value)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func formatMultiplier(_ value: Double) -> String {
        let rounded = rounded(value)
        let s = String(format: "%.1f", rounded)
        return "\(s.hasSuffix(".0") ? String(s.dropLast(2)) : s)x"
    }
}

private enum ArtificialAnalysisIntelligenceIndex {
    private static let scoresByName: [String: Double] = [
        "gpt55xhigh": 60,
        "gpt55high": 59,
        "claudeopus47adaptivereasoningmaxeffort": 57,
        "claudeopus47max": 57,
        "gemini31propreview": 57,
        "gpt54xhigh": 57,
        "gpt55medium": 57,
        "qwen37max": 57,
        "gemini35flash": 56,
        "kimik26": 54,
        "mimov25pro": 54,
        "gpt53codexxhigh": 54,
        "grok43high": 53,
        "musespark": 52,
        "claudeopus47nonreasoninghigh": 52,
        "claudesonnet46max": 52,
        "deepseekv4promax": 52,
        "glm51": 51,
        "gpt55low": 51,
        "qwen36plus": 50,
        "deepseekv4prohigh": 50,
        "glm5": 50,
        "minimaxm27": 50,
        "mimov25": 49,
        "gpt54minixhigh": 49,
        "grok43medium": 49,
        "gpt54low": 48,
        "glm5turbo": 47,
        "deepseekv4flashmax": 47,
        "deepseekv4flashhigh": 46,
        "qwen3627b": 46,
        "qwen35397ba17b": 45,
        "mimov2omni0327": 45,
        "claudesonnet46nonreasoning": 44,
        "gpt54nanoxhigh": 44,
        "grok43low": 44,
        "qwen3635ba3b": 43,
        "gpt55nonreasoning": 41,
        "deepseekv4pro": 39,
        "o3": 38,
        "gpt54nano": 38,
        "gpt54minimedium": 38,
    ]

    static func score(for model: OpenRouterModel) -> Double? {
        let key = normalized(model.display_name)
        if let exact = scoresByName[key] { return exact }
        return scoresByName
            .filter { key.contains($0.key) || $0.key.contains(key) }
            .map(\.value)
            .max()
    }

    static func sorted(_ models: [OpenRouterModel]) -> [OpenRouterModel] {
        models.sorted { lhs, rhs in
            let leftScore = score(for: lhs)
            let rightScore = score(for: rhs)
            switch (leftScore, rightScore) {
            case let (l?, r?) where l != r:
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftPrice = lhs.blended_usd_per_million ?? .infinity
                let rightPrice = rhs.blended_usd_per_million ?? .infinity
                if leftPrice != rightPrice { return leftPrice < rightPrice }
                return lhs.display_name.localizedCaseInsensitiveCompare(rhs.display_name) == .orderedAscending
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Multi-select model pool editor for the arena. A two-handle price range
/// defines the base pool; row checkboxes then add or remove individual models.
/// The persisted shape is `(price_min...price_max) union models minus exclude`.
struct ArenaModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initial: ArenaModelSelection
    var onDone: (ArenaModelSelection) -> Void

    @State private var selection: ArenaModelSelection

    init(initial: ArenaModelSelection, onDone: @escaping (ArenaModelSelection) -> Void) {
        self.initial = initial
        self.onDone = onDone
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ArenaModelPoolEditor(selection: $selection)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(selection.resolvedCount >= 2 ? "价格模型池 · \(selection.resolvedCount) 个" : "选择模型池")
                            .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.foregroundStyle(Theme.Palette.inkMuted)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { onDone(selection); dismiss() }
                            .disabled(selection.fallbackModel == nil)
                            .foregroundStyle(selection.fallbackModel == nil ? Theme.Palette.inkMuted : Theme.Palette.accent)
                    }
                }
        }
        .tint(Theme.Palette.accent)
    }
}

struct ArenaModelPoolEditor: View {
    @Environment(\.api) private var api

    @Binding var selection: ArenaModelSelection

    @State private var allModels: [OpenRouterModel] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var include: Set<String> = []
    @State private var exclude: Set<String> = []
    @State private var priceMinValue: Double = ArenaPriceRangeScale.numericMin
    @State private var priceMaxValue: Double = ArenaPriceRangeScale.numericMax

    // Only OpenRouter chat models without native-backed duplicates are
    // arena-eligible, matching the edge pool.
    private var pool: [OpenRouterModel] {
        allModels.filter {
            ($0.source ?? "openrouter") == "openrouter"
            && !ModelCatalogFilters.isNativeBackedOpenRouterRow($0)
        }
    }

    private var rangeModels: [OpenRouterModel] {
        pool.filter { isInPriceRange($0) }
    }

    private var effectiveModels: [OpenRouterModel] {
        ArtificialAnalysisIntelligenceIndex.sorted(pool.filter { isEffective($0) })
    }

    private var filtered: [OpenRouterModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ArtificialAnalysisIntelligenceIndex.sorted(pool.filter { m in
            if !q.isEmpty {
                let hay = "\(m.slug) \(m.display_name) \(m.provider)".lowercased()
                if !hay.contains(q) { return false }
            } else if !isInPriceRange(m) && !include.contains(m.slug) && !exclude.contains(m.slug) {
                return false
            }
            return true
        })
    }

    private var priceMinBound: Double? {
        ArenaPriceRangeScale.priceMin(fromSliderLower: priceMinValue)
    }

    private var priceMaxBound: Double? {
        ArenaPriceRangeScale.priceMax(fromSliderUpper: priceMaxValue)
    }

    private var draft: ArenaModelSelection {
        let effective = effectiveModels
        return ArenaModelSelection(
            priceMin: priceMinBound,
            priceMax: priceMaxBound,
            models: Array(include).sorted(),
            exclude: Array(exclude).sorted(),
            fallbackModel: effective.first?.slug ?? include.sorted().first ?? selection.fallbackModel,
            resolvedCount: effective.count)
    }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            if loading && allModels.isEmpty {
                ProgressView().tint(Theme.Palette.accent)
            } else if let error, allModels.isEmpty {
                VStack(spacing: 8) {
                    Text("加载模型列表失败")
                        .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Button("重试") { Task { await load() } }
                        .foregroundStyle(Theme.Palette.accent)
                }
            } else {
                VStack(spacing: 0) {
                    filterBar
                    list
                }
            }
        }
        .task { await load() }
        .onChange(of: priceMinValue) { _, _ in syncSelection() }
        .onChange(of: priceMaxValue) { _, _ in syncSelection() }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.inkMuted)
                TextField("搜索模型 / 厂商", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Theme.Fonts.rounded(size: 14, weight: .regular))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            PriceRangeSlider(
                lower: $priceMinValue,
                upper: $priceMaxValue,
                bounds: ArenaPriceRangeScale.sliderBounds
            )
            .frame(height: 34)
            HStack(spacing: 8) {
                rangeEndpoint("下限", value: ArenaPriceRangeScale.lowerLabel(priceMinValue))
                rangeEndpoint("上限", value: ArenaPriceRangeScale.upperLabel(priceMaxValue))
                Spacer()
                Text("区间内 \(rangeModels.count), 实际 \(draft.resolvedCount)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            if filtered.isEmpty {
                Section {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "当前区间没有可选模型" : "没有匹配的模型")
                        .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                .listRowBackground(Theme.Palette.surface)
            }
            Section {
                ForEach(filtered) { m in
                    Button {
                        toggle(m)
                        Haptics.tap()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: rowIcon(for: m))
                                .font(Theme.Fonts.glyph(size: 17, weight: .semibold))
                                .foregroundStyle(rowTint(for: m))
                                .frame(width: 22)
                            Text(m.display_name)
                                .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            if let p = m.blended_usd_per_million {
                                Text(ModelCatalog.formatMultiplier(p))
                                    .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.inkMuted)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.Palette.surfaceMuted))
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
    }

    private func rangeEndpoint(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.Palette.inkMuted)
            Text(value)
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Palette.ink)
                .frame(minWidth: 42)
        }
        .font(Theme.Fonts.caption)
    }

    private func load() async {
        guard let api else { return }
        loading = true; defer { loading = false }
        do {
            allModels = try await api.get("v1/models")
            include = Set(selection.models)
            exclude = Set(selection.exclude)
            if selection.priceMin == nil,
               selection.priceMax == nil,
               selection.models.isEmpty,
               selection.exclude.isEmpty {
                priceMinValue = ArenaPriceRangeScale.numericMin
                priceMaxValue = ArenaPriceRangeScale.numericMax
            } else {
                priceMinValue = ArenaPriceRangeScale.sliderLower(fromPriceMin: selection.priceMin)
                priceMaxValue = max(
                    priceMinValue,
                    ArenaPriceRangeScale.sliderUpper(fromPriceMax: selection.priceMax))
            }
            error = nil
            syncSelection()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func isInPriceRange(_ model: OpenRouterModel) -> Bool {
        guard let price = model.blended_usd_per_million else { return false }
        if let priceMinBound, price < priceMinBound { return false }
        if let priceMaxBound, price > priceMaxBound { return false }
        return true
    }

    private func isEffective(_ model: OpenRouterModel) -> Bool {
        if exclude.contains(model.slug) { return false }
        return include.contains(model.slug) || isInPriceRange(model)
    }

    private func toggle(_ model: OpenRouterModel) {
        if isEffective(model) {
            include.remove(model.slug)
            exclude.insert(model.slug)
        } else {
            exclude.remove(model.slug)
            include.insert(model.slug)
        }
        syncSelection()
    }

    private func syncSelection() {
        selection = draft
    }

    private func rowIcon(for model: OpenRouterModel) -> String {
        isEffective(model) ? "checkmark.square.fill" : "square"
    }

    private func rowTint(for model: OpenRouterModel) -> Color {
        if isEffective(model) { return Theme.Palette.accent }
        return Theme.Palette.inkMuted.opacity(0.5)
    }
}

private struct PriceRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - 28)
            let lowX = x(for: lower, width: width)
            let highX = x(for: upper, width: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Palette.surfaceMuted)
                    .frame(height: 6)
                    .offset(x: 14)
                Capsule()
                    .fill(Theme.Palette.accent.opacity(0.75))
                    .frame(width: max(0, highX - lowX), height: 6)
                    .offset(x: 14 + lowX)
                handle(label: "左")
                    .offset(x: lowX)
                    .gesture(drag(width: width, isLower: true))
                handle(label: "右")
                    .offset(x: highX)
                    .gesture(drag(width: width, isLower: false))
            }
            .frame(height: geo.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("价格区间")
        .accessibilityValue("\(ArenaPriceRangeScale.lowerLabel(lower)) 到 \(ArenaPriceRangeScale.upperLabel(upper))")
    }

    private func handle(label: String) -> some View {
        ZStack {
            Circle()
                .fill(Theme.Palette.surface)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Circle()
                .strokeBorder(Theme.Palette.accent, lineWidth: 2)
                .frame(width: 28, height: 28)
            Text(label)
                .font(Theme.Fonts.glyph(size: 9, weight: .bold))
                .foregroundStyle(Theme.Palette.accent)
        }
    }

    private func drag(width: CGFloat, isLower: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { dragValue in
                let next = value(for: dragValue.location.x - 14, width: width)
                if isLower {
                    lower = min(max(bounds.lowerBound, next), min(upper, ArenaPriceRangeScale.numericMax))
                } else {
                    upper = max(min(bounds.upperBound, next), max(lower, ArenaPriceRangeScale.numericMin))
                }
            }
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        let pct = (value - bounds.lowerBound) / span
        return CGFloat(min(max(0, pct), 1)) * width
    }

    private func value(for x: CGFloat, width: CGFloat) -> Double {
        let pct = min(max(0, x / width), 1)
        let span = bounds.upperBound - bounds.lowerBound
        return bounds.lowerBound + Double(pct) * span
    }
}
