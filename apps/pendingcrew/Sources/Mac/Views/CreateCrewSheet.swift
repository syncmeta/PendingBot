#if os(macOS)
import SwiftUI

/// 新建 crew 的 sheet。**P2 stub** —— 真表单 P3 实装。
struct CreateCrewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("新建 crew")
                .font(.title3.weight(.semibold))
            Text("(P3 待实装 — Form / NSOpenPanel / subject picker)")
                .foregroundStyle(.secondary)
            Button("关闭") { dismiss() }
        }
        .padding(40)
        .frame(width: 480, height: 240)
    }
}
#endif
