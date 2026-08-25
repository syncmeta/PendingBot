import SwiftUI

/// The 机组 tab — **暂时只显示「待建设」**(作者 Todo #18)。
///
/// 原来的实现(session 卡片流 → 详情遥控台 → 新建任务 sheet)**没有删,原样
/// 留在这个目录里**:`CrewListView` / `CrewSessionDetailView` /
/// `CrewListStore` / `CrewSessionDetailStore` / `NewCrewTaskSheet`。它们此刻
/// 没有任何调用方,只是没人再从这里进去而已 —— 要恢复,把下面三个入口指回
/// `CrewListView(...)` 就行(git 历史里就是原样),顺带把 `externalSelection`
/// / `renderAsMacListColumn` 两个字段加回来(见下)。
///
/// 之所以只摘入口而不删代码:这一整套是照 spec 写过的真东西,只是后端那一半
/// 还没到位,现在摆出来是半成品。删了将来要重写,留着零成本。
///
/// **待建设期间这个类型没有任何存储属性** —— 原来那两个(`externalSelection`
/// 承接三栏壳的选中项、`renderAsMacListColumn` 标记"我是中列,别自带导航")
/// 都随入口一起摘掉了:三个入口现在各自返回固定内容,没人写也没人读它们。
/// `FeatureSurface` 只要求三个方法,不要求任何字段,所以留着纯属误导 ——
/// 下一个人会以为中列还走那条分支。
struct CrewTabView: View {
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
        // 壳自己有导航,中列直接铺占位;待建设期间不写 selection。
        placeholder
    }

    func detailColumn(selection: Binding<String?>) -> some View {
        // 中列已经写着「待建设」了,右栏再说一遍是重复。留一片空画布。
        Theme.Palette.canvas.ignoresSafeArea()
    }

    func compactRoot() -> some View {
        // compact(iPhone)才需要自带 NavigationStack + 标题;宽屏走的是上面
        // 那两个入口,壳自己管导航,不会进这里。
        NavigationStack {
            placeholder
                .navigationTitle("机组")
        }
    }
}
