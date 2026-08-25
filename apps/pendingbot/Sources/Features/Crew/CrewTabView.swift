import SwiftUI

/// The 机组 tab — **暂时只显示「待建设」**(作者 Todo #18)。
///
/// 原来的实现(session 卡片流 → 详情遥控台 → 新建任务 sheet)**没有删,原样
/// 留在这个目录里**:`CrewListView` / `CrewSessionDetailView` /
/// `CrewListStore` / `CrewSessionDetailStore` / `NewCrewTaskSheet`。它们此刻
/// 没有任何调用方,只是没人再从这里进去而已 —— 要恢复,把下面三个入口指回
/// `CrewListView(...)` 就行(git 历史里就是原样)。
///
/// 之所以只摘入口而不删代码:这一整套是照 spec 写过的真东西,只是后端那一半
/// 还没到位,现在摆出来是半成品。删了将来要重写,留着零成本。
///
/// 三个入口对应三种壳:
///   * compact(iPhone):自带 NavigationStack + 标题,
///   * wide(iPad/Mac):`WideRootView` 三栏壳驱动 `listColumn` + `detailColumn`,
///     壳自己管导航,所以中列不再套 NavigationStack。
struct CrewTabView: View {
    /// Wide-shell injection: 保留字段是为了让 `listColumn(selection:)` 的签名
    /// 不变(`FeatureSurface` 要求),待建设期间没人读它。
    var externalSelection: Binding<String?>? = nil
    /// Render only the bare list body (no chrome / NavigationStack) — set by
    /// `listColumn(...)` so it slots into the shell's middle column.
    var renderAsMacListColumn = false

    var body: some View {
        compactRoot()
    }

    /// 「待建设」本体。三个入口共用一份,免得哪天改文案漏掉一处。
    private var placeholder: some View {
        EmptyHint(text: "待建设")
            .background(Theme.Palette.canvas)
    }
}

// MARK: - FeatureSurface (wide shell)

extension CrewTabView: FeatureSurface {
    typealias Selection = String

    func listColumn(selection: Binding<String?>) -> some View {
        // 壳自己有导航,中列直接铺占位;selection 待建设期间不写。
        placeholder
    }

    func detailColumn(selection: Binding<String?>) -> some View {
        // 中列已经写着「待建设」了,右栏再说一遍是重复。留一片空画布。
        Theme.Palette.canvas.ignoresSafeArea()
    }

    func compactRoot() -> some View {
        Group {
            if renderAsMacListColumn {
                placeholder
            } else {
                NavigationStack {
                    placeholder
                        .navigationTitle("机组")
                }
            }
        }
    }
}
