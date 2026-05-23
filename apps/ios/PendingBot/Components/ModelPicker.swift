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
