#if os(macOS)
import SwiftUI

/// 左栏的本地 crew **DAG 折叠树**。
///
/// 「家」在本地 —— crew 的组织/DAG 模型是纯本地的(`LocalCrewStore.parentCrewIds`),
/// 不走 edge。这里把扁平 `[CrewSummary]` 渲染成折叠树:
/// - **根** = `parentCrewIds` 为空的 crew。
/// - 每个节点下嵌它的**子**(其它 crew 的 parentCrewIds 含本 crew)。
/// - **多父 crew 在每个父下各出现一次**(引用式,不是唯一归属)。
/// - **防无限递归**:渲染带一条「祖先路径」`Set<String>`,某节点已在路径上则
///   不再下钻(attachParent 已禁环,渲染仍自保,防脏数据)。
///
/// 点击节点设 `crewStore.selectedCrewId`(沿用现有选中逻辑)。展开态每个节点
/// 自持(`@State isExpanded`),互不影响。
struct CrewDAGTreeView: View {
    @EnvironmentObject private var crewStore: CrewStore

    var body: some View {
        let crews = crewStore.crews
        // childMap: parentId → 该父下直接子 crew(按 createdAt DESC,跟列表一致)。
        let childMap = Self.buildChildMap(crews)
        let roots = crews.filter { $0.parentCrewIds.isEmpty }

        ForEach(roots) { crew in
            CrewDAGNode(
                crew: crew,
                childMap: childMap,
                crewsById: Self.byId(crews),
                ancestors: []
            )
        }
    }

    // MARK: - 推导

    /// parentId → [子 crew]。child = 其 parentCrewIds 含某 crew 的那些 crew。
    static func buildChildMap(_ crews: [CrewSummary]) -> [String: [CrewSummary]] {
        var map: [String: [CrewSummary]] = [:]
        for crew in crews {
            for parentId in crew.parentCrewIds {
                map[parentId, default: []].append(crew)
            }
        }
        return map
    }

    static func byId(_ crews: [CrewSummary]) -> [String: CrewSummary] {
        Dictionary(crews.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// 单个 crew 树节点 —— 头像 + 标题,有子时带 disclosure 三角。
private struct CrewDAGNode: View {
    let crew: CrewSummary
    let childMap: [String: [CrewSummary]]
    let crewsById: [String: CrewSummary]
    /// 当前渲染路径上的祖先 id(含到本节点为止的链)—— 防环下钻自保。
    let ancestors: Set<String>

    @EnvironmentObject private var crewStore: CrewStore
    @State private var isExpanded = false

    private var children: [CrewSummary] { childMap[crew.id] ?? [] }
    /// 已在祖先路径上的子不再下钻(环自保);其余正常展开。
    private var expandableChildren: [CrewSummary] {
        children.filter { !ancestors.contains($0.id) }
    }
    private var isSelected: Bool { crewStore.selectedCrewId == crew.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded {
                ForEach(expandableChildren) { child in
                    CrewDAGNode(
                        crew: child,
                        childMap: childMap,
                        crewsById: crewsById,
                        ancestors: ancestors.union([crew.id])
                    )
                    .padding(.leading, 16) // 每层缩进
                }
            }
        }
    }

    /// 会话行样式(对齐 PendingBot `ConversationListRow`):36pt 头像 + serif-16
    /// 标题 + footnote 副行 + 相对时间。前面留一个三角槽承载 DAG 展开/收起。
    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            // disclosure 三角 —— 有可下钻子才显示,否则等宽占位对齐。顶部留白
            // 让它大致对到头像竖直中线。
            Group {
                if !expandableChildren.isEmpty {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            .padding(.top, 12)

            CrewGroupAvatar(seed: crew.id, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(crew.title)
                        .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let when = relativeUpdated {
                        Text(when)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(subtitleText)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if crew.parentCrewIds.count > 1 {
                        Image(systemName: "arrow.triangle.branch")
                            .font(Theme.Fonts.caption2)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .help("此 crew 挂在多个父 crew 之下,在每个父下都会出现")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(isSelected ? Theme.Palette.accentBg : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { crewStore.selectCrew(crew.id) }
    }

    /// 副行文案:位置 + 标签 + 机长名(有就接上),当"消息预览"位用。
    private var subtitleText: String {
        var parts: [String] = [crew.runtimeLocationKind?.shortLabel ?? crew.runtimeLocation]
        if let tag = crew.tag, !tag.isEmpty { parts.append(tag) }
        return parts.joined(separator: " · ")
    }

    /// crew.updatedAt(ISO8601)→ 相对时间("3 分钟前"),解析失败留 nil。
    private var relativeUpdated: String? {
        guard let date = ISO8601DateFormatter().date(from: crew.updatedAt) else { return nil }
        return date.formatted(.relative(presentation: .numeric))
    }
}
#endif
