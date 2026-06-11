#if os(macOS)
import SwiftUI
import AppKit

/// crew 详情 / 设置面板（spec §9 把它从中栏挪出来，中栏改放群聊）。
/// 显示 crew 元数据 + 机长 + 父/子 crew(DAG) + 责任比例 + 工作目录。
/// 以 inspector sheet 形式从 `CrewCenterView` 顶栏 ⓘ 打开。
struct CrewDetailInspector: View {
    let detail: CrewDetail
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel

    /// 已绑定的 edge relay conversation id（接合 v2 block 3）。onAppear 从
    /// LocalCrewStore 读，接入成功后就地更新。nil = 未接入。
    @State private var remoteConversationId: String?
    @State private var relayBusy = false
    @State private var relayError: String?
    /// 极简邀 bot 入口：手填 botId。TODO：等 `GET /v1/me/bots` 之类的"subject
    /// 可用 bot 列表"端点存在后换成 picker（现在没有现成端点，不为此造新端点）。
    @State private var inviteBotId = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    captainSection
                    if appModel.isAuthenticated {
                        relaySection
                    }
                    linkSection("父 crew", links: detail.parents)
                    linkSection("子 crew", links: detail.children)
                    sharesSection
                }
                .padding(20)
            }
        }
        .onAppear {
            remoteConversationId = LocalCrewStore.shared
                .relayBinding(for: detail.crew.id)?.remoteConversationId
        }
        .frame(minWidth: 420, minHeight: 440)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("crew 详情").font(.headline) }
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.crew.title).font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Label(detail.crew.runtimeLocationKind?.shortLabel ?? detail.crew.runtimeLocation,
                      systemImage: detail.crew.runtimeLocationKind?.displayIcon ?? "questionmark.circle")
                if let tag = detail.crew.tag, !tag.isEmpty {
                    Label(tag, systemImage: "tag")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let wd = detail.crew.workingDirectory, !wd.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(wd)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { revealInFinder(wd) } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中打开")
                }
            }
        }
    }

    @ViewBuilder
    private var captainSection: some View {
        sectionHeader("机长")
        if let captain = detail.captain {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.tint)
                Text(captain.displayName)
                Spacer()
                Text(captain.botId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        } else {
            Text("(无机长)").foregroundStyle(.secondary)
        }
    }

    // MARK: - PendingBot 接入（接合 v2 block 3 relay 信箱）

    /// 登录态下显示。未绑定 → 「接入 PendingBot」按钮（edge 建同名 relay crew
    /// conversation，remoteConversationId 存本地 crew JSON）；已绑定 → 状态 +
    /// 邀 bot 入口。同步搬运由 CrewRelayAgent 后台跑，这里只管绑定/邀请。
    @ViewBuilder
    private var relaySection: some View {
        sectionHeader("PendingBot 接入")
        if let remoteId = remoteConversationId {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.tint)
                    Text("已接入")
                    Spacer()
                    Text(remoteId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    TextField("bot id（邀请 PendingBot bot 进群）", text: $inviteBotId)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    Button("邀请 bot") { inviteBot(remoteId: remoteId) }
                        .disabled(relayBusy ||
                                  inviteBotId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    connectToPendingBot()
                } label: {
                    Label("接入 PendingBot", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(relayBusy)
                if relayBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("在 PendingBot 侧建一个同名 crew 群，手机端可看可聊；Mac 在线时自动双向同步白板。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let relayError {
            Text(relayError)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// 「接入 PendingBot」：edge `POST /v1/crews` 建 relay conversation（title
    /// 同本地 crew、runtime local_host、subject = grant subject、captain 系统
    /// 生成），成功后把 remoteConversationId 落进本地 crew JSON。
    private func connectToPendingBot() {
        relayBusy = true
        relayError = nil
        let crewId = detail.crew.id
        let title = detail.crew.title
        let tag = detail.crew.tag
        Task {
            defer { relayBusy = false }
            do {
                let api = try appModel.loggedAPIClient()
                guard let subject = try await api.listMySubjects().first else {
                    relayError = "没有可代表的 subject"
                    return
                }
                let resp = try await api.createCrew(.localHost(
                    responsibleSubjectId: subject.id,
                    title: title,
                    workingDirectory: nil,
                    tag: tag,
                    captain: .systemGenerated(templateName: nil)
                ))
                LocalCrewStore.shared.bindRemoteConversation(
                    crewId: crewId, remoteConversationId: resp.crewId)
                remoteConversationId = resp.crewId
            } catch {
                relayError = error.localizedDescription
            }
        }
    }

    /// 邀一个 PendingBot bot 进 relay crew（`POST /v1/crews/:id/members`）。
    private func inviteBot(remoteId: String) {
        let botId = inviteBotId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !botId.isEmpty else { return }
        relayBusy = true
        relayError = nil
        Task {
            defer { relayBusy = false }
            do {
                let api = try appModel.loggedAPIClient()
                try await api.addCrewMember(crewId: remoteId, kind: "bot", botId: botId)
                inviteBotId = ""
            } catch {
                relayError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func linkSection(_ title: String, links: [CrewDetail.CrewLink]) -> some View {
        sectionHeader(title)
        if links.isEmpty {
            Text("(无)").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(links, id: \.crewId) { link in
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        Text(link.title)
                        Spacer()
                        Text("\(sharePercent(link.childShareBps))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sharesSection: some View {
        sectionHeader("责任比例")
        if detail.shares.isEmpty {
            Text("(尚未结算)").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.shares, id: \.subjectId) { share in
                    HStack(spacing: 8) {
                        Image(systemName: share.kind == "group_account" ? "person.3" : "person.crop.circle")
                            .foregroundStyle(.secondary)
                        Text(share.displayName.isEmpty ? share.subjectId : share.displayName)
                            .lineLimit(1)
                        if share.isTiebreaker {
                            Text("决胜")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                        Spacer()
                        Text("\(sharePercent(share.shareBps))%")
                            .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func sharePercent(_ bps: Int) -> String {
        String(format: "%.2f", Double(bps) / 100.0)
    }

    private func revealInFinder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }
}
#endif
