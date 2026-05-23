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

    private var filtered: [OpenRouterModel] {
        let visionFiltered = visionOnly
            ? allModels.filter { $0.supports_vision == true }
            : allModels
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

    private static func isNativeKey(_ key: String) -> Bool {
        key == nativeAnthropicKey || key == nativeGeminiKey || key == nativeOpenAIKey
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
            // Index of the first OpenRouter (non-native) group, used to slot
            // the "native above / OpenRouter below" note right at the seam.
            // Only when there's at least one native group ahead of it.
            let orSeam: Int? = searching ? nil : groups.firstIndex { !Self.isNativeKey($0.provider) }.flatMap { $0 > 0 ? $0 : nil }
            ForEach(Array(groups.enumerated()), id: \.element.provider) { item in
                let group = item.element
                if item.offset == orSeam {
                    nativeVsOpenRouterNote
                }
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

    /// Sits at the seam between the native sections and the OpenRouter long
    /// tail, calling out that picking a native vendor's model from below
    /// (via OpenRouter) breaks prompt caching.
    private var nativeVsOpenRouterNote: some View {
        Section {
            Text("以上三家是原生调用，下面走 OpenRouter。如果在下面选以上三家的模型，账单会爆，因为提示词缓存没配置好。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.vertical, 2)
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
               let match = allModels.first(where: { $0.slug == initial }) {
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
        if hasPriceRange {
            let lo = priceMin.map(Self.formatMultiplier) ?? "不限"
            let hi = priceMax.map(Self.formatMultiplier) ?? "不限"
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

/// Multi-select model picker for the arena. A two-handle price range defines
/// the base pool; rows and vendor actions then add out-of-range models or
/// remove in-range models. The persisted shape is:
/// `(price_min...price_max) union models minus exclude`.
struct ArenaModelPickerSheet: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    let initial: ArenaModelSelection
    var onDone: (ArenaModelSelection) -> Void

    @State private var allModels: [OpenRouterModel] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var include: Set<String> = []
    @State private var exclude: Set<String> = []
    @State private var priceMinValue: Double = 0
    @State private var priceMaxValue: Double = 5
    @State private var priceCap: Double = 50

    // Only openrouter-source chat models are arena-eligible (matches the edge
    // pool — native twins are dropped to avoid double-weighting).
    private var pool: [OpenRouterModel] {
        allModels.filter { ($0.source ?? "openrouter") == "openrouter" }
    }

    private var rangeModels: [OpenRouterModel] {
        pool.filter { isInPriceRange($0) }
    }

    private var effectiveModels: [OpenRouterModel] {
        pool.filter { isEffective($0) }
            .sorted { ($0.blended_usd_per_million ?? .infinity) < ($1.blended_usd_per_million ?? .infinity) }
    }

    private var filtered: [OpenRouterModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return pool.filter { m in
            if !q.isEmpty {
                let hay = "\(m.slug) \(m.display_name) \(m.provider)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        .sorted { ($0.blended_usd_per_million ?? .infinity) < ($1.blended_usd_per_million ?? .infinity) }
    }

    private var groupedFiltered: [(provider: String, models: [OpenRouterModel])] {
        Dictionary(grouping: filtered, by: \.provider)
            .keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ($0, Dictionary(grouping: filtered, by: \.provider)[$0] ?? []) }
    }

    private var draft: ArenaModelSelection {
        let effective = effectiveModels
        return ArenaModelSelection(
            priceMin: priceMinValue,
            priceMax: priceMaxValue >= priceCap ? nil : priceMaxValue,
            models: Array(include).sorted(),
            exclude: Array(exclude).sorted(),
            fallbackModel: effective.first?.slug ?? include.sorted().first ?? initial.fallbackModel,
            resolvedCount: effective.count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                if loading && allModels.isEmpty {
                    ProgressView().tint(Theme.Palette.accent)
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        list
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(draft.resolvedCount >= 2 ? "价格模型池 · \(draft.resolvedCount) 个" : "选择模型池")
                        .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(Theme.Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(draft); dismiss() }
                        .disabled(draft.fallbackModel == nil)
                        .foregroundStyle(draft.fallbackModel == nil ? Theme.Palette.inkMuted : Theme.Palette.accent)
                }
            }
        }
        .task { await load() }
        .tint(Theme.Palette.accent)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.inkMuted)
                TextField("搜索 slug / 名字 / 厂商", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Theme.Fonts.rounded(size: 14, weight: .regular))
            }
            PriceRangeSlider(
                lower: $priceMinValue,
                upper: $priceMaxValue,
                bounds: 0...priceCap
            )
            .frame(height: 34)
            HStack(spacing: 8) {
                rangeEndpoint("左", value: $priceMinValue)
                rangeEndpoint("右", value: $priceMaxValue)
                Spacer()
                Text("区间内 \(rangeModels.count), 实际 \(draft.resolvedCount)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            HStack(spacing: 8) {
                Button {
                    for m in filtered { include.insert(m.slug); exclude.remove(m.slug) }
                    Haptics.tap()
                } label: {
                    Label("加入当前列表", systemImage: "plus.circle")
                }
                Spacer()
                Button(role: .destructive) {
                    for m in filtered { exclude.insert(m.slug); include.remove(m.slug) }
                    Haptics.tap()
                } label: {
                    Label("去除当前列表", systemImage: "minus.circle")
                }
            }
            .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 10)
    }

    private var list: some View {
        List {
            if draft.resolvedCount > 0 {
                Section {
                    Button("清空手动调整") {
                        include.removeAll()
                        exclude.removeAll()
                        Haptics.tap()
                    }
                        .font(Theme.Fonts.rounded(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                } footer: {
                    Text("价格区间是基础池；加号会把区间外模型加入池子，减号会把区间内模型排除。创建后机器人每轮从池子随机挑一个模型。")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.inkMuted)
                }
                .listRowBackground(Theme.Palette.surface)
            }
            ForEach(groupedFiltered, id: \.provider) { group in
                Section {
                    ForEach(group.models) { m in
                        Button {
                            toggle(m)
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: rowIcon(for: m))
                                    .foregroundStyle(rowTint(for: m))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.display_name).font(Theme.Fonts.rounded(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.Palette.ink).lineLimit(1)
                                    Text(m.slug).font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                if let p = m.blended_usd_per_million {
                                    Text(ModelCatalog.formatMultiplier(p))
                                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.inkMuted)
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(Capsule().fill(Theme.Palette.surfaceMuted))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(group.provider)
                            .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                        Text("\(group.models.count)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                        Spacer()
                        Button {
                            for m in group.models {
                                include.insert(m.slug)
                                exclude.remove(m.slug)
                            }
                            Haptics.tap()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        Button {
                            for m in group.models {
                                exclude.insert(m.slug)
                                include.remove(m.slug)
                            }
                            Haptics.tap()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .textCase(nil)
                }
                .listRowBackground(Theme.Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas)
    }

    private func rangeEndpoint(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.Palette.inkMuted)
            TextField(title, text: Binding(
                get: { String(format: "%.1f", value.wrappedValue) },
                set: { raw in
                    guard let n = Double(raw) else { return }
                    value.wrappedValue = min(max(0, n), priceCap)
                    if priceMinValue > priceMaxValue {
                        if title == "左" { priceMaxValue = priceMinValue }
                        else { priceMinValue = priceMaxValue }
                    }
                }
            ))
            .keyboardType(.decimalPad)
            .frame(width: 56)
            .multilineTextAlignment(.center)
            .font(Theme.Fonts.monoSmall)
        }
        .font(Theme.Fonts.caption)
    }

    private func load() async {
        guard let api else { return }
        loading = true; defer { loading = false }
        do {
            allModels = try await api.get("v1/models")
            include = Set(initial.models)
            exclude = Set(initial.exclude)
            let maxP = pool.compactMap { $0.blended_usd_per_million }.max() ?? 50
            priceCap = max(1, maxP)
            priceMinValue = min(max(0, initial.priceMin ?? 0), priceCap)
            priceMaxValue = min(max(priceMinValue, initial.priceMax ?? min(priceCap, 5)), priceCap)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func isInPriceRange(_ model: OpenRouterModel) -> Bool {
        guard let price = model.blended_usd_per_million else { return false }
        return price >= priceMinValue && price <= priceMaxValue
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
    }

    private func rowIcon(for model: OpenRouterModel) -> String {
        if exclude.contains(model.slug) { return "minus.circle.fill" }
        if include.contains(model.slug) { return "plus.circle.fill" }
        return isInPriceRange(model) ? "checkmark.circle.fill" : "circle"
    }

    private func rowTint(for model: OpenRouterModel) -> Color {
        if exclude.contains(model.slug) { return .red.opacity(0.75) }
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
        .accessibilityValue("\(ModelCatalog.formatMultiplier(lower)) 到 \(ModelCatalog.formatMultiplier(upper))")
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
                    lower = min(max(bounds.lowerBound, next), upper)
                } else {
                    upper = max(min(bounds.upperBound, next), lower)
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
