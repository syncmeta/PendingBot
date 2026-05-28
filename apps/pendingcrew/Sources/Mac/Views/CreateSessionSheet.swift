#if os(macOS)
import SwiftUI

/// 新建 session sheet。**P2 stub** —— 真表单 + runner 接通在 P4。
struct CreateSessionSheet: View {
    let detail: CrewDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("新建 session — \(detail.crew.title)")
                .font(.title3.weight(.semibold))
            Text("(P4 待实装 — kind picker / brief / prompt / runner 接通)")
                .foregroundStyle(.secondary)
            Button("关闭") { dismiss() }
        }
        .padding(40)
        .frame(width: 480, height: 240)
    }
}
#endif
