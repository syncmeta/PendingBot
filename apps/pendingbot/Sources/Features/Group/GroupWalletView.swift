import SwiftUI

/// 群钱包页(实缴池 + 认缴)。读/写 `/v1/group-subjects/:id/*`,模型见
/// GroupWalletService。展示群池余额、我的份额/占比/认缴、成员明细;操作:
/// 充值(实缴)、设/改/清认缴、部分取出、退群、解散(owner)。
///
/// ⚠️ 视觉 / 交互 **待用户定稿** —— 当前按现有钱包页(WalletV2View)的设计语言
/// 搭骨架(Theme 调色板 + insetGrouped List + 金额输入 sheet),不自创风格。
/// 待定稿点见文件末尾注释 + 给用户的清单。
struct GroupWalletView: View {
    let subjectId: String

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
        List {
            overviewSection
            membersSection
            actionsSection
        }
        .platformListStyle()
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("群钱包")
        .inlineNavTitle()
        .refreshable { await reload() }
        .task {
            myUserId = (try? await SupabaseStack.shared.auth.session.user.id.uuidString.lowercased()) ?? ""
            await reload()
        }
        .sheet(item: $activeForm) { form in
            AmountFormSheet(
                form: form,
                working: working,
                onSubmit: { credits in Task { await submit(form: form, credits: credits) } },
            )
            .platformDetents([.medium])
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

    // MARK: - 概览

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // 群池余额
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(GroupWalletFormat.fmt(wallet?.poolPnc ?? 0))
                        .font(Theme.Fonts.serif(size: 24, weight: .semibold))
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
                Text(loadError).font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.danger)
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
                // TODO(待定稿): 成员只返回 user_id,无显示名 —— 暂显示"我"/短 id。
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
            // 权限矩阵(spec v2 §4.3):owner 不能直接退群 —— 先转让或解散。
            // 客户端预检只做 UX 禁用,服务端 /leave 对 owner 返回 409 是最终裁决。
            if isOwner {
                actionButton("解散群(全员退款)", icon: "trash", tint: Theme.Palette.danger) {
                    confirmingDissolve = true
                }
            } else {
                actionButton("退群(全额退款)", icon: "rectangle.portrait.and.arrow.right", tint: Theme.Palette.danger) {
                    confirmingLeave = true
                }
            }
        } header: {
            Text("操作")
        } footer: {
            if let actionNotice {
                Text(actionNotice).font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.success)
            } else if isOwner {
                Text("金额按整数 PNC。认缴填 0 = 撤销认缴。群主需先转让群主或解散群,不能直接退群。")
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
            } else {
                Text("金额按整数 PNC。认缴填 0 = 撤销认缴。")
                    .font(Theme.Fonts.monoSmall).foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .disabled(working)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, tint: Color = Theme.Palette.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Theme.Fonts.body)
                .foregroundStyle(tint)
        }
        .listRowBackground(Theme.Palette.surface)
    }

    // MARK: - 网络

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            wallet = try await GroupWalletService.fetch(subjectId: subjectId)
            loadError = nil
        } catch {
            loadError = "加载群钱包失败,下拉重试。"
        }
    }

    private func submit(form: AmountForm, credits: Int) async {
        working = true
        actionError = nil; actionNotice = nil
        defer { working = false }
        do {
            switch form {
            case .topup:
                let r = try await GroupWalletService.topup(subjectId: subjectId, credits: credits)
                actionNotice = "已注资 \(GroupWalletFormat.fmt(r.contributedPnc)) PNC。"
            case .pledge:
                let r = try await GroupWalletService.pledge(subjectId: subjectId, credits: credits)
                actionNotice = credits == 0 ? "已撤销认缴。" : "认缴已设为 \(r.pledgePnc) PNC。"
            case .withdraw:
                let r = try await GroupWalletService.withdraw(subjectId: subjectId, credits: credits)
                actionNotice = "已取出 \(GroupWalletFormat.fmt(r.withdrawnPnc)) PNC。"
            }
            activeForm = nil
            await reload()
        } catch {
            actionError = GroupWalletService.friendlyMessage(error)
        }
    }

    private func doLeave() async {
        working = true; actionError = nil; actionNotice = nil
        defer { working = false }
        do {
            let r = try await GroupWalletService.leave(subjectId: subjectId)
            actionNotice = "已退群,退回 \(GroupWalletFormat.fmt(r.refundedPnc)) PNC。"
            await reload()
        } catch {
            actionError = GroupWalletService.friendlyMessage(error)
        }
    }

    private func doDissolve() async {
        working = true; actionError = nil; actionNotice = nil
        defer { working = false }
        do {
            let r = try await GroupWalletService.dissolve(subjectId: subjectId)
            actionNotice = "已解散,退回 \(r.refundedContributors) 人共 \(GroupWalletFormat.fmt(r.totalRefundedPnc)) PNC。"
            await reload()
        } catch {
            actionError = GroupWalletService.friendlyMessage(error)
        }
    }

}

// MARK: - 金额输入 sheet(充值 / 认缴 / 取出共用)

private struct AmountFormSheet: View {
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
                        .platformKeyboard(.number)
                } footer: {
                    Text(form.footer)
                }
                Section {
                    Button {
                        if let v = parsed { onSubmit(v) }
                    } label: {
                        if working {
                            HStack { ProgressView(); Text("提交中…") }
                        } else {
                            Text("确定").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!valid || working)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle(form.title)
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
