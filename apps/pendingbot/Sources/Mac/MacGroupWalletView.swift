#if os(macOS)
import SwiftUI

/// macOS 群钱包 — 原生重画对齐 iOS `GroupWalletView`(实缴池 + 认缴)。展示群池
/// 余额、我的份额/占比/认缴、成员明细;操作:充值(实缴)、设/改/清认缴、部分取出、
/// 退群、解散(owner)。
///
/// 入口只有 crewId(Mac crew 右栏),先经 `CrewAPI.getCrewV2` 解析群的
/// `responsibleSubjectId`,其余读写全走跨平台 `GroupWalletService`/`GroupWalletFormat`/
/// 共享 `AmountForm`,与 iOS 同源。作为 sheet 弹出。
struct MacGroupWalletView: View {
    let crewId: String

    @Environment(\.dismiss) private var dismiss

    @State private var subjectId: String?
    @State private var wallet: GroupWalletService.Wallet?
    @State private var loading = false
    @State private var loadError: String?
    @State private var myUserId: String = ""

    // 操作态
    @State private var activeForm: AmountForm?
    @State private var working = false
    @State private var actionError: String?
    @State private var actionNotice: String?
    @State private var confirmingLeave = false
    @State private var confirmingDissolve = false

    private var isOwner: Bool { wallet?.role == "owner" }

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                membersSection
                actionsSection
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("群钱包")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading || subjectId == nil)
                        .help("刷新")
                }
            }
            .task {
                myUserId = (try? await SupabaseStack.shared.auth.session.user.id.uuidString.lowercased()) ?? ""
                await resolveAndLoad()
            }
            .sheet(item: $activeForm) { form in
                MacAmountFormSheet(form: form, working: working) { credits in
                    Task { await submit(form: form, credits: credits) }
                }
            }
            .confirmationDialog("退群会把你在群里的全部份额退回个人钱包,确定吗?",
                                isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("退群并退款", role: .destructive) { Task { await doLeave() } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("解散群会把群池按比例退给所有出资人,不可撤销,确定吗?",
                                isPresented: $confirmingDissolve, titleVisibility: .visible) {
                Button("解散群", role: .destructive) { Task { await doDissolve() } }
                Button("取消", role: .cancel) {}
            }
            .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("好", role: .cancel) { actionError = nil }
            } message: { Text(actionError ?? "") }
        }
        .frame(minWidth: 480, minHeight: 600)
    }

    // MARK: - 概览

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(GroupWalletFormat.fmt(wallet?.poolPnc ?? 0))
                        .font(Theme.Fonts.serif(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .monospacedDigit()
                    Text("PNC 群池")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                Divider().overlay(Theme.Palette.inkMuted.opacity(0.2))
                statRow("我的份额", value: "\(GroupWalletFormat.fmt(wallet?.me.stakePnc ?? 0)) PNC",
                        sub: "占比 \(GroupWalletFormat.pct(wallet?.me.shareRatio ?? 0)) · 实缴 \(GroupWalletFormat.fmt(wallet?.me.contributionShareNowPnc ?? 0)) PNC")
                statRow("我的认缴", value: "\(GroupWalletFormat.fmt(wallet?.me.pledgePnc ?? 0)) PNC",
                        sub: "当前生效 \(GroupWalletFormat.fmt(wallet?.me.pledgeEffectivePnc ?? 0)) PNC(= min(认缴, 个人余额))")
                statRow("分摊基数 S", value: "\(GroupWalletFormat.fmt(wallet?.totalStakePnc ?? 0)) PNC",
                        sub: "= 群池 + 全员生效认缴")
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.Palette.surface)
        } header: {
            Text("群池与我的份额")
        } footer: {
            if let loadError {
                Text(loadError).font(Theme.Fonts.monoSmall).foregroundStyle(Color(hex: 0xB14B3C))
            } else {
                Text("占比 = 你的份额 / S,同时是分摊比例与实缴可取出比例。")
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func statRow(_ title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.ink)
                Spacer()
                Text(value).font(Theme.Fonts.body).foregroundStyle(Theme.Palette.ink).monospacedDigit()
            }
            Text(sub).font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
        }
    }

    // MARK: - 成员明细

    @ViewBuilder
    private var membersSection: some View {
        if let w = wallet {
            Section {
                ForEach(w.members) { m in
                    memberRow(m)
                        .listRowBackground(Theme.Palette.surface)
                }
            } header: {
                Text("成员份额")
            } footer: {
                Text(w.membersComplete
                     ? "实缴 = 当前可取出份额;认缴 = min(额度, 个人余额)。"
                     : "仅群主 / 管理员可看全员明细,这里只显示你自己。")
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ m: GroupWalletService.Wallet.Member) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.userId == myUserId ? "我" : String(m.userId.prefix(8)))
                    .font(Theme.Fonts.body).foregroundStyle(Theme.Palette.ink)
                Text("实缴 \(GroupWalletFormat.fmt(m.contributionShareNowPnc)) · 认缴 \(GroupWalletFormat.fmt(m.pledgePnc))")
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(GroupWalletFormat.fmt(m.stakePnc)) PNC")
                    .font(Theme.Fonts.body).foregroundStyle(Theme.Palette.ink).monospacedDigit()
                Text(GroupWalletFormat.pct(m.shareRatio))
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 操作

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            actionButton("充值(注资进群)", icon: "plus.circle") { activeForm = .topup }
            actionButton("设 / 改认缴额度", icon: "hand.raised") { activeForm = .pledge(current: wallet?.me.pledgePnc ?? 0) }
            actionButton("部分取出", icon: "arrow.down.circle") { activeForm = .withdraw(max: wallet?.me.contributionShareNowPnc ?? 0) }
            actionButton("退群(全额退款)", icon: "rectangle.portrait.and.arrow.right", tint: Color(hex: 0xB14B3C)) {
                confirmingLeave = true
            }
            if isOwner {
                actionButton("解散群(全员退款)", icon: "trash", tint: Color(hex: 0xB14B3C)) {
                    confirmingDissolve = true
                }
            }
        } header: {
            Text("操作")
        } footer: {
            if let actionNotice {
                Text(actionNotice).font(Theme.Fonts.monoSmall).foregroundStyle(Color(hex: 0x2E7D5B))
            } else {
                Text("金额按整数 PNC。认缴填 0 = 撤销认缴。")
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .disabled(working || subjectId == nil)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, tint: Color = Theme.Palette.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Theme.Fonts.body)
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.Palette.surface)
    }

    // MARK: - 网络

    private func resolveAndLoad() async {
        if subjectId == nil {
            do {
                // CrewAPI(getCrewV2) 是 iOS-only;Mac 走跨平台 listCrewsV2,
                // 其 CrewSummaryV2 已带 responsibleSubjectId。
                let crews = try await APIClient().listCrewsV2()
                guard let sid = crews.first(where: { $0.id == crewId })?.responsibleSubjectId else {
                    loadError = "找不到这个机组的责任主体。"
                    return
                }
                subjectId = sid
            } catch {
                loadError = "无法解析群的责任主体,关掉重开试试。"
                return
            }
        }
        await reload()
    }

    private func reload() async {
        guard let sid = subjectId else { return }
        loading = true
        defer { loading = false }
        do {
            wallet = try await GroupWalletService.fetch(subjectId: sid)
            loadError = nil
        } catch {
            loadError = "加载群钱包失败,点刷新重试。"
        }
    }

    private func submit(form: AmountForm, credits: Int) async {
        guard let sid = subjectId else { return }
        working = true
        actionError = nil; actionNotice = nil
        defer { working = false }
        do {
            switch form {
            case .topup:
                let r = try await GroupWalletService.topup(subjectId: sid, credits: credits)
                actionNotice = "已注资 \(GroupWalletFormat.fmt(r.contributedPnc)) PNC。"
            case .pledge:
                let r = try await GroupWalletService.pledge(subjectId: sid, credits: credits)
                actionNotice = credits == 0 ? "已撤销认缴。" : "认缴已设为 \(r.pledgePnc) PNC。"
            case .withdraw:
                let r = try await GroupWalletService.withdraw(subjectId: sid, credits: credits)
                actionNotice = "已取出 \(GroupWalletFormat.fmt(r.withdrawnPnc)) PNC。"
            }
            activeForm = nil
            await reload()
        } catch {
            actionError = GroupWalletService.friendlyMessage(error)
        }
    }

    private func doLeave() async {
        guard let sid = subjectId else { return }
        working = true; actionError = nil; actionNotice = nil
        defer { working = false }
        do {
            let r = try await GroupWalletService.leave(subjectId: sid)
            actionNotice = "已退群,退回 \(GroupWalletFormat.fmt(r.refundedPnc)) PNC。"
            await reload()
        } catch {
            actionError = GroupWalletService.friendlyMessage(error)
        }
    }

    private func doDissolve() async {
        guard let sid = subjectId else { return }
        working = true; actionError = nil; actionNotice = nil
        defer { working = false }
        do {
            let r = try await GroupWalletService.dissolve(subjectId: sid)
            actionNotice = "已解散,退回 \(r.refundedContributors) 人共 \(GroupWalletFormat.fmt(r.totalRefundedPnc)) PNC。"
            await reload()
        } catch {
            actionError = GroupWalletService.friendlyMessage(error)
        }
    }
}

// MARK: - 金额输入 sheet(充值 / 认缴 / 取出共用,macOS 原生)

private struct MacAmountFormSheet: View {
    let form: AmountForm
    let working: Bool
    let onSubmit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    private var parsed: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool {
        guard let v = parsed else { return false }
        return form.allowsZero ? v >= 0 : v > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("PNC 整数", text: $text)
                } footer: {
                    Text(form.footer)
                }
                Section {
                    Button {
                        if let v = parsed { onSubmit(v) }
                    } label: {
                        if working {
                            HStack { ProgressView().controlSize(.small); Text("提交中…") }
                        } else {
                            Text("确定").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!valid || working)
                    .buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(form.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}
#endif
