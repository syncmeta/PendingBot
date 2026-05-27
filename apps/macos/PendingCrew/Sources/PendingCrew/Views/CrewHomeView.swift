import SwiftUI

struct CrewHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = "新的机组"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SubjectSummaryView()

                GroupBox("创建机组") {
                    HStack {
                        TextField("机组名称", text: $title)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await model.createCrew(title: title) }
                        } label: {
                            Label("创建", systemImage: "plus")
                        }
                        .disabled(model.personalSubjectId == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                GroupBox("最近机组") {
                    if model.crews.isEmpty {
                        ContentUnavailableView("还没有机组", systemImage: "person.3.sequence")
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("名称").foregroundStyle(.secondary)
                                Text("状态").foregroundStyle(.secondary)
                                Text("创建时间").foregroundStyle(.secondary)
                            }
                            ForEach(model.crews) { crew in
                                GridRow {
                                    Button(crew.title) {
                                        model.selection = .crew(crew.id)
                                        Task { await model.refreshCrew(crew.id) }
                                    }
                                    .buttonStyle(.plain)
                                    Text(crew.status)
                                    Text(crew.createdAt)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("机组")
    }
}

private struct SubjectSummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox("当前责任主体") {
            if let response = model.subjectResponse {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("名称").foregroundStyle(.secondary)
                        Text(response.subject.displayName)
                    }
                    GridRow {
                        Text("Subject").foregroundStyle(.secondary)
                        Text(response.subject.id)
                            .font(.system(.caption, design: .monospaced))
                    }
                    GridRow {
                        Text("余额").foregroundStyle(.secondary)
                        Text("\(response.wallet.balanceCredits)")
                    }
                }
            } else {
                ContentUnavailableView("未连接账号", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        }
    }
}
