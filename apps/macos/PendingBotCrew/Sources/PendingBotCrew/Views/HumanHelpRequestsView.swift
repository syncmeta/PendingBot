import SwiftUI

struct HumanHelpRequestsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.helpRequests.isEmpty {
                    ContentUnavailableView("暂无请求", systemImage: "tray")
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(model.helpRequests) { request in
                        HelpRequestRow(request: request)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("有求于你")
    }
}

private struct HelpRequestRow: View {
    @EnvironmentObject private var model: AppModel
    let request: HumanHelpRequest

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.temporaryGroup.title)
                            .font(.headline)
                        if let requester = request.requester {
                            Text("\(requester.displayName) 请求你加入")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(request.createdAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let reason = request.reason, !reason.isEmpty {
                    Text(reason)
                }

                HStack {
                    Button {
                        Task { await model.decideHelpRequest(id: request.id, accepted: true) }
                    } label: {
                        Label("接受", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await model.decideHelpRequest(id: request.id, accepted: false) }
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                    }
                }
            }
        }
    }
}

