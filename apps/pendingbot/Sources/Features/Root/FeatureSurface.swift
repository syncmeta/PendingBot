import SwiftUI

/// 一个 feature 向壳暴露的三种装配。宽屏壳取 list/detail 拼三列;
/// compact 取 compactRoot 自包含 push。Selection 由壳持有并下传。
///
/// 三类形态约定:
/// - 列表+详情型(好友/消息):list 选中驱动 detail。
/// - feed+正文型(来信):同构(list=feed,detail=正文)。
/// - 无列表型(我):list 给空态或入口,detail 给主内容。
protocol FeatureSurface {
    associatedtype Selection: Hashable
    associatedtype ListColumn: View
    associatedtype DetailColumn: View
    associatedtype CompactRoot: View

    @ViewBuilder func listColumn(selection: Binding<Selection?>) -> ListColumn
    @ViewBuilder func detailColumn(selection: Selection?) -> DetailColumn
    @ViewBuilder func compactRoot() -> CompactRoot
}
