import SwiftUI
import UIKit

/// T4.6 — crew 详情页（P0 MVP）。
///
/// spec v2 §11.2 — 完整形态应当是群聊 UI：消息流 + composer + @人/@session/
/// @captain mention + session 状态卡 + 子 crew 摘要卡 + "在 PendingCrew 中
/// 打开"按钮。**P0 这版只接 metadata + relationships**:
///   - crew title / responsible subject / runtime / tag / 工作目录
///   - Captain bot 名字
///   - 父/子 crew 列表
///   - 责任比例
///   - "在 PendingCrew 中打开" 按钮 → 复制 / 分享 deep link
///   - 提示卡说明"消息流 / @session / session 状态卡 留 T4.1 接入后实装"
///
/// T4.1（通信规则）+ T4.3（permission 通道）+ T4.5（跨端遥控）ship 后，
/// 这个 view 会被改成 ConversationView-style 群聊页（白板 + composer），
/// metadata 部分挪到右上角 "..."→机组详情 sheet。
struct CrewDetailV2View: View {
    @Environment(\.api) private var api

    let crewId: String
    /// list row 已经知道 title，先用它做 placeholder，等 detail 拉回来再
    /// 用 detail.crew.title 覆盖，避免 nav title 一闪空白。
    let fallbackTitle: String

    @State private var detail: CrewDetailV2?
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showingShareSheet = false

    var body: some View {
        Group {
            if let detail {
                detailContent(detail)
            } else if loading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("无法加载机组", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(detail?.crew.title ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingShareSheet) {
            DeepLinkShareSheet(deepLinkURL: pendingCrewDeepLink)
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert("已复制", isPresented: .constant(notice != nil)) {
            Button("好") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Detail body

    @ViewBuilder
    private func detailContent(_ detail: CrewDetailV2) -> some View {
        List {
            Section {
                LabeledRow(label: "标题", value: detail.crew.title)
                LabeledRow(label: "状态", value: detail.crew.status ?? "—")
                LabeledRow(label: "运行位置", value: runtimeLabel(for: detail.crew))
                if let tag = detail.crew.tag, !tag.isEmpty {
                    LabeledRow(label: "标签", value: "#\(tag)")
                }
                if let cwd = detail.crew.workingDirectory, !cwd.isEmpty {
                    LabeledRow(label: "工作目录", value: cwd, monospaced: true)
                }
                LabeledRow(label: "责任主体 ID", value: detail.crew.responsibleSubjectId.prefix(8) + "…", monospaced: true)
            } header: {
                Text("基本信息")
            }

            Section {
                if let captain = detail.captain {
                    HStack {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.15))
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(captain.displayName)
                                .font(.body.weight(.medium))
                            Text("机长（captain）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("还没有指定机长").foregroundStyle(.secondary)
                }
            } header: {
                Text("机长")
            } footer: {
                Text("机长是 crew 的「代理人格」和「对父 crew 的代表」。spec v2 §6.3。")
            }

            Section {
                if detail.parents.isEmpty {
                    Text("没有父机组").foregroundStyle(.secondary)
                } else {
                    ForEach(detail.parents) { link in
                        crewLinkRow(link)
                    }
                }
            } header: {
                Text("父机组")
            }

            Section {
                if detail.children.isEmpty {
                    Text("没有子机组").foregroundStyle(.secondary)
                } else {
                    ForEach(detail.children) { link in
                        crewLinkRow(link)
                    }
                }
            } header: {
                Text("子机组")
            }

            Section {
                if detail.shares.isEmpty {
                    Text("没有责任分配").foregroundStyle(.secondary)
                } else {
                    ForEach(detail.shares) { share in
                        shareRow(share)
                    }
                }
            } header: {
                Text("责任比例")
            } footer: {
                Text("总和恒为 10000 bps（100%）。带星号 ★ 的是拍板方。spec v2 §7.3。")
            }

            Section {
                Button {
                    showingShareSheet = true
                } label: {
                    Label("在 PendingCrew 中打开", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = pendingCrewDeepLink.absoluteString
                    notice = "深链已复制到剪贴板"
                } label: {
                    Label("复制深链", systemImage: "doc.on.doc")
                }
            } header: {
                Text("操作")
            } footer: {
                Text("PendingCrew Mac / iPad 打开深链后会自动跳到这个机组。")
            }

            Section {
                Label {
                    Text("消息流 / @session / @captain / session 状态卡 留 T4.1 通信规则接入后实装。当前版本只展示元数据，方便你确认 crew 创建成功 + 父子关系 / 责任比例符合预期。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("尚未实装")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Subviews

    private func crewLinkRow(_ link: CrewLinkV2) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .font(.body)
                    .lineLimit(1)
                Text("子方保留 \(bpsAsPercent(link.childShareBps))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(link.crewId.prefix(8) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private func shareRow(_ share: CrewShareV2) -> some View {
        HStack(spacing: 10) {
            Image(systemName: share.kind == "group_account" ? "person.3.fill" : "person.crop.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(share.displayName.isEmpty ? share.subjectId.prefix(8) + "…" : share.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if share.isTiebreaker {
                        Text("★")
                            .foregroundStyle(.orange)
                            .font(.body.weight(.bold))
                    }
                }
                Text(share.kind == "group_account" ? "群账号" : "本人账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(bpsAsPercent(share.shareBps))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private var pendingCrewDeepLink: URL {
        // spec v2 §11.3 — `pendingcrew://crew/<crew-id>`
        URL(string: "pendingcrew://crew/\(crewId)")!
    }

    private func bpsAsPercent(_ bps: Int) -> String {
        // 4 位 bps → 整数 / 一位小数 % (e.g. 5500 → "55.0%", 5550 → "55.5%")
        let percent = Double(bps) / 100.0
        return String(format: "%.1f%%", percent)
    }

    private func runtimeLabel(for crew: CrewBodyV2) -> String {
        if let kind = crew.runtimeLocationKind {
            return kind.shortLabel
        }
        return crew.runtimeLocation
    }

    private func reload() async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            self.detail = try await api.getCrewV2(crewId)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Small reusable rows

private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    init(label: String, value: any StringProtocol, monospaced: Bool = false) {
        self.label = label
        self.value = String(value)
        self.monospaced = monospaced
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Share sheet wrapper

/// 包 UIActivityViewController 用 SwiftUI sheet 弹出，让用户复制 / 发到
/// Messages / 用 PendingCrew Mac 扫码定位 crew。
///
/// spec v2 §11.3 — iOS PendingBot 跳转 PendingCrew 主要做"复制 + 二维
/// 码"两件事；二维码留下次（需要本机渲染 QR），这次先用系统 share sheet
/// 把"复制 / AirDrop / 发消息"几个常用动作铺出来。
private struct DeepLinkShareSheet: UIViewControllerRepresentable {
    let deepLinkURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [deepLinkURL], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}
