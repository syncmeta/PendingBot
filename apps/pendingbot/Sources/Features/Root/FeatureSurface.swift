import SwiftUI

/// 一个 feature 向壳暴露的三种装配。宽屏壳取 list/detail 拼三列;
/// compact 取 compactRoot 自包含 push。Selection 由壳持有并下传。
///
/// 三类形态约定:
/// - 列表+详情型(好友/消息):list 选中驱动 detail。
/// - feed+正文型(来信):同构(list=feed,detail=正文)。
/// - 无列表型(我):list 给空态或入口,detail 给主内容。
///
/// **两列拿的都是 `Binding`,不是值。** detail 曾经只拿到 `Selection?` 的**值**,
/// 于是右栏里任何"做完一件事要换选中项"的回调都写了个没人观察的副本 —— 表现是
/// 点了完全没反应。2026-08-25 建群就栽在这:Mac 上按「创建」,群建出来了,右栏
/// 纹丝不动,用户只能理解成没建成、再按一次(线上因此多了两个同名空群)。
/// 右栏是壳的一等公民,不是只读投影;给它写入口,这一类 bug 就不存在。
protocol FeatureSurface {
    associatedtype Selection: Hashable
    associatedtype ListColumn: View
    associatedtype DetailColumn: View
    associatedtype CompactRoot: View

    @ViewBuilder func listColumn(selection: Binding<Selection?>) -> ListColumn
    @ViewBuilder func detailColumn(selection: Binding<Selection?>) -> DetailColumn
    @ViewBuilder func compactRoot() -> CompactRoot
}
