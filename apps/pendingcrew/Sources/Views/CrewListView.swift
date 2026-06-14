import SwiftUI

/// 跨平台 crew 列表 —— iPad sidebar / macOS reuse 用。
///
/// 不含 macOS-only 的 session 列、toolbar、identity footer 等，那些逻辑
/// 留在 `CrewSidebarView`（`#if os(macOS)`）。这里只是纯列表。
///
/// 选中态通过 `$selection` 双向绑定传入，由外层 NavigationSplitView 或
/// macOS List(selection:) 统一持有。
struct CrewListView: View {
    @EnvironmentObject private var crewStore: CrewStore
    /// 当前选中的 crew id；nil = 无选中。
    @Binding var selection: String?

    var body: some View {
        List(crewStore.crews, selection: $selection) { crew in
            CrewListRow(crew: crew)
                .tag(crew.id)
        }
        .overlay {
            if crewStore.crews.isEmpty {
                emptyOverlay
            }
        }
        .task { await crewStore.refreshList() }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyOverlay: some View {
        if crewStore.loadingList {
            ProgressView()
        } else {
            VStack(spacing: 6) {
                Text("还没有 crew")
                    .font(Theme.Fonts.subheadline)
                    .foregroundStyle(Theme.Palette.ink)
                Text("新建一个来开始")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
    }
}

// MARK: - Row

private struct CrewListRow: View {
    let crew: CrewSummary

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(emojiSeed: crew.id, colorSeed: crew.id, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(crew.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                subtitleText
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var subtitleText: some View {
        let location = crew.runtimeLocationKind?.shortLabel ?? crew.runtimeLocation
        Text(location)
    }
}
