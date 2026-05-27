import PendingBotShared
import SwiftUI

struct PendingBotMacRootView: View {
    @ObservedObject var store: PendingBotMacStore

    var body: some View {
        VStack(spacing: 0) {
            settingsBar
            Divider()

            if store.isLoggedIn {
                PendingBotBigScreenAppView(
                    crews: store.crews,
                    selectedCrewId: $store.selectedCrewId,
                    crewDetails: store.crewDetails,
                    crewListLoading: store.isLoadingCrews,
                    crewDetailLoadingIds: store.crewDetailLoadingIds,
                    crewDetailErrors: store.crewDetailErrors,
                    onRefresh: {
                        Task { await store.reloadAll() }
                    },
                    onSelectCrew: { crewId in
                        store.selectCrew(crewId)
                    },
                    onSendAnnouncement: { crewId, message in
                        store.sendAnnouncement(crewId: crewId, summary: message)
                    },
                    onCreateSession: { crewId, runnerKind, taskBrief in
                        store.createSession(crewId: crewId, runnerKind: runnerKind, taskBrief: taskBrief)
                    },
                    onCreateChildCrew: { crewId, title in
                        store.createChildCrew(parentCrewId: crewId, title: title)
                    }
                )
            } else {
                loginView
            }
        }
        .task {
            if store.isLoggedIn {
                await store.reloadAll()
            }
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 10) {
            Text("PendingBot")
                .font(.headline)

            TextField("API URL", text: $store.apiBaseURLString)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .onSubmit {
                    store.saveAPIBaseURL()
                }

            Button {
                store.saveAPIBaseURL()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("保存 API URL")

            if let subject = store.subject {
                Text(subject.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            if store.isLoggedIn {
                Button {
                    Task { await store.reloadAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")

                Button("退出登录") {
                    store.signOut()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var loginView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("登录 PendingBot Mac")
                    .font(.title2.weight(.semibold))
                Text("创建设备登录挑战后，用 PendingBot 扫码批准这个 Mac。批准后设备 grant token 会保存到系统钥匙串。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await store.startDeviceLogin() }
                } label: {
                    Label("创建设备登录", systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isPollingLogin)

                if store.loginChallenge != nil {
                    Button("取消") {
                        store.cancelLogin()
                    }
                }

                if store.isPollingLogin {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let challenge = store.loginChallenge {
                VStack(alignment: .leading, spacing: 10) {
                    Text("验证码")
                        .font(.headline)
                    Text(challenge.code)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    Text("过期时间: \(challenge.expiresAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("QR Payload")
                        .font(.headline)
                    Text(challenge.qrPayload)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if let loginStatus = store.loginStatus {
                Label(loginStatus, systemImage: "clock")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    }
}
