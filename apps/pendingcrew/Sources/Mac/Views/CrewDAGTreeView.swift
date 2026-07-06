#if os(macOS)
import Combine
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
    /// 本组要渲染的 crew 子集（某台机器的 crew）。
    let crews: [CrewSummary]

    var body: some View {
        // childMap: parentId → 该父下直接子 crew。限定在子集内算。
        let childMap = Self.buildChildMap(crews)
        let ids = Set(crews.map(\.id))
        // 组内根 = 无父，或父不在本组（跨机器父边 → 在本组当根）。
        let roots = crews.filter { crew in
            crew.parentCrewIds.isEmpty || !crew.parentCrewIds.contains(where: ids.contains)
        }

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

/// 单个 crew 树节点 —— 竖色条 + 标题,有子时带 disclosure 三角。
private struct CrewDAGNode: View {
    let crew: CrewSummary
    let childMap: [String: [CrewSummary]]
    let crewsById: [String: CrewSummary]
    /// 当前渲染路径上的祖先 id(含到本节点为止的链)—— 防环下钻自保。
    let ancestors: Set<String>

    @EnvironmentObject private var crewStore: CrewStore
    /// session 状态源（isWorking/health/退出）—— 状态点聚合用。由 `MacRootView`
    /// 注入 sidebar（与中/右栏同一实例，才看得到同一批 run）。
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
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

    /// 会话行样式(对齐 PendingBot `ConversationListRow`):细竖色条(谱系
    /// 二分色,见 `CrewColorBar`) + 无衬线-14 标题 + 最近一条消息 + 相对时间。
    /// 三角槽**恒占位**(无子节点画透明占位)—— 同层级的色条/标题左缘必须
    /// 对齐,不能因为某行有子带三角就被推出去。
    ///
    /// **不再贴每行「本机/云端」location tag**(#369:侧栏已按 machine 分组,crew
    /// 视觉嵌在所属 machine Section 下,行内派生标签既冗余又把派生列当事实源)。
    private var row: some View {
        HStack(alignment: .top, spacing: 6) {
            if !expandableChildren.isEmpty {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .frame(width: 12)
                .padding(.top, 10)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            CrewColorBar(colors: CrewColorBar.chain(for: crew, crewsById: crewsById))
                // 状态点浮在色条右上角（spec §3）：红=异常、黄=机长 attention、
                // 绿=干活中、灰=全闲/退；无 session 且无 attention 不画。
                .overlay(alignment: .topTrailing) {
                    CrewStatusDotView(
                        attentionReason: crew.attentionReason,
                        runs: sessionRunner.runs.filter { $0.crewId == crew.id }
                    )
                    .offset(x: 6, y: -5)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(crew.title)
                        .font(Theme.Fonts.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let when = relativeUpdated {
                        Text(when)
                            .font(Theme.Fonts.caption2)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 传 whiteboardRevision 进 preview：本身不参与文案，但让本行订阅
                    // CrewStore 的白板变更计数 —— 白板一变（含 helper 子进程跨进程写）
                    // 行重渲染、预览重新求值。删掉它预览就退化成「点选才刷新」。
                    Text(lastMessagePreview(revision: crewStore.whiteboardRevision))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if crew.parentCrewIds.count > 1 {
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.triangle.branch")
                            .font(Theme.Fonts.caption2)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .help("此 crew 挂在多个父 crew 之下,在每个父下都会出现")
                    }
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
        // 每个 crew 之间留一道竖向呼吸间距 —— 加在高亮 pill 之外(背景/点击区已闭合),
        // 所以是 crew 之间的留白,不是把 pill 撑高;根 crew(独立 list row)与展开的
        // 子 crew(同 VStack 内堆叠)都吃这道下边距,间距统一。
        .padding(.bottom, 6)
    }

    /// 最近一条白板消息(本地 store);空则"还没有消息"。
    /// `revision` = `CrewStore.whiteboardRevision`,值本身不用 —— 只为把「白板变了」
    /// 变成本视图的依赖,变更时重新同步读 store(spec 2026-07-06 §2 方案 A)。
    private func lastMessagePreview(revision: Int) -> String {
        let text = LocalWhiteboardStore.shared.list(crewId: crew.id).last?.text ?? ""
        return text.isEmpty ? "还没有消息" : text
    }

    /// crew.updatedAt(ISO8601)→ 相对时间("3 分钟前"),解析失败留 nil。
    private var relativeUpdated: String? {
        guard let date = ISO8601DateFormatter().date(from: crew.updatedAt) else { return nil }
        return date.formatted(.relative(presentation: .numeric))
    }
}

/// 头像右上角的 crew 状态点。聚合逻辑在 `CrewStatusAggregation`（纯函数，单测
/// 覆盖优先级），这里只负责取信号 + 画点。
///
/// **嵌套 ObservableObject 观察**：`run.isWorking` / `run.health` / `run.status`
/// 是各 run 自己的 `@Published` —— 父视图观察 `CrewSessionRunner` 看不到 run 内
/// 部变更（同 `SessionBarItemView` 的问题）。这里 merge 所有 run 的
/// `objectWillChange` 撞一下本视图的 `@State revision`，任一 run 状态变化即重
/// 渲染重新聚合。runs 列表本身增删由父视图（观察 runner.runs）驱动重建。
private struct CrewStatusDotView: View {
    let attentionReason: String?
    let runs: [CrewSessionRun]

    @State private var revision = 0

    var body: some View {
        Group {
            if let color = dotColor {
                ZStack {
                    // 2pt 背景色描边 —— 让点从头像盘上浮出（点 10pt + 描边圈 14pt）。
                    Circle()
                        .fill(Theme.Palette.canvas)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(fill(color))
                        .frame(width: 10, height: 10)
                }
                .help(helpText(color) ?? "")
            }
        }
        .onReceive(Publishers.MergeMany(runs.map(\.objectWillChange))) { _ in
            revision &+= 1
        }
    }

    private var dotColor: CrewStatusDotColor? {
        _ = revision // 把 revision 变成 body 依赖：run 内部状态一变即重新聚合。
        return CrewStatusAggregation.dot(
            sessions: runs.map {
                CrewSessionStatusSignal(
                    isAlive: $0.status == .running,
                    isWorking: $0.isWorking,
                    hasHealthIssue: $0.health != nil)
            },
            attentionReason: attentionReason)
    }

    /// 配色对齐右栏切换条状态点（`SessionBarItemView`）：系统语义色。
    private func fill(_ color: CrewStatusDotColor) -> Color {
        switch color {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .gray: return .gray
        }
    }

    /// 悬浮提示：黄 = 机长的 attention reason；红 = 首个异常 session 的 health
    /// detail（实现顺手，spec 允许）。绿/灰不带。
    private func helpText(_ color: CrewStatusDotColor) -> String? {
        switch color {
        case .yellow: return attentionReason
        case .red: return runs.first(where: { $0.health != nil && $0.status == .running })?.health?.detail
        case .green, .gray: return nil
        }
    }
}
#endif
