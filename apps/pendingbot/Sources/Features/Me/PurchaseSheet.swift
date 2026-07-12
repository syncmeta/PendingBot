import SwiftUI
import RevenueCat

/// PNC 充值 sheet。RevenueCat offerings → 套餐卡片 → `Purchases.shared.purchase(package:)`。
///
/// 入账不在这里发生:购买成功后 App Store → RevenueCat → 我们的 webhook
/// (`/v1/billing/revenuecat/webhook`) → recordCreditIn → WalletDO。所以购买成功
/// 后本 sheet 只轮询刷新 `/v1/me/wallet/v2`,等 webhook 到账后余额自然更新。
///
/// appUserID 由 Telemetry.identify(Account.id) 绑成 **auth.users.id**（不是
/// subject id）；webhook 侧把 ev.app_user_id 经 subjects.user_id 查表映射回
/// user_account 的 subject id 再入账 —— 本 sheet 不再重复设置。
///
/// key 空(RevenueCat 未配置)时 `Purchases.isConfigured == false`:入口显示禁用
/// "内购未配置",不静默隐藏也不崩。
@MainActor
final class PurchaseModel: ObservableObject {
    enum Phase: Equatable {
        case notConfigured          // RevenueCat key 未填 → Purchases 未 configure
        case loading
        case ready
        case purchasing(String)     // productIdentifier
        case failed(String)
        case succeeded
    }

    @Published var phase: Phase = .loading
    @Published var packages: [Package] = []

    func load() async {
        guard Purchases.isConfigured else { phase = .notConfigured; return }
        phase = .loading
        do {
            let offerings = try await Purchases.shared.offerings()
            // 当前套餐:优先 current offering,回退第一个可用 offering。
            let offering = offerings.current ?? offerings.all.values.first
            packages = offering?.availablePackages ?? []
            phase = .ready
        } catch {
            phase = .failed("加载套餐失败：\(error.localizedDescription)")
        }
    }

    /// 购买一个套餐。成功(且非用户取消)→ .succeeded;调用方据此刷新钱包。
    func purchase(_ package: Package) async {
        guard Purchases.isConfigured else { phase = .notConfigured; return }
        phase = .purchasing(package.storeProduct.productIdentifier)
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                phase = .ready
                return
            }
            phase = .succeeded
        } catch {
            phase = .failed("购买失败：\(error.localizedDescription)")
        }
    }

    /// 恢复购买(换机/重装)。恢复本身不发额度(额度是消耗型充值,靠 webhook 入账),
    /// 但可重新对齐 RevenueCat customer,并让用户确认账号已连上。
    func restore() async {
        guard Purchases.isConfigured else { phase = .notConfigured; return }
        phase = .loading
        do {
            _ = try await Purchases.shared.restorePurchases()
            phase = .ready
        } catch {
            phase = .failed("恢复购买失败：\(error.localizedDescription)")
        }
    }
}

struct PurchaseSheet: View {
    /// 购买成功回调 —— 调用方(WalletV2View)据此刷新余额。
    var onPurchased: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PurchaseModel()

    var body: some View {
        NavigationStack {
            content
                .background(Theme.Palette.canvas.ignoresSafeArea())
                .navigationTitle("充值 PNC")
                .inlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .notConfigured:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Text("内购未配置")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.ink)
                    Text("充值功能尚未开通，稍后再来。")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }

        case .loading:
            centered { ProgressView() }

        case .succeeded:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Palette.success)
                    Text("购买成功")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.ink)
                    Text("额度到账可能有几秒延迟，钱包会自动刷新。")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .multilineTextAlignment(.center)
                    Button("完成") {
                        onPurchased()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 32)
            }

        case .ready, .purchasing, .failed:
            packageList
        }
    }

    private var packageList: some View {
        List {
            if case let .failed(msg) = model.phase {
                Section {
                    Text(msg)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.danger)
                        .listRowBackground(Theme.Palette.dangerBg)
                }
            }

            Section {
                if model.packages.isEmpty {
                    Text("暂无可购买的套餐。")
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .listRowBackground(Theme.Palette.surface)
                }
                ForEach(model.packages, id: \.identifier) { pkg in
                    packageRow(pkg)
                        .listRowBackground(Theme.Palette.surface)
                }
            } footer: {
                Text("购买后额度将充入你的 PNC 钱包，由 App Store 结算。")
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            Section {
                Button("恢复购买") {
                    Task { await model.restore() }
                }
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.accent)
                .listRowBackground(Theme.Palette.surface)
            }
        }
        .platformListStyle()
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func packageRow(_ pkg: Package) -> some View {
        let product = pkg.storeProduct
        let purchasing: Bool = {
            if case let .purchasing(id) = model.phase { return id == product.productIdentifier }
            return false
        }()
        Button {
            Task {
                await model.purchase(pkg)
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.localizedTitle.isEmpty ? "充值包" : product.localizedTitle)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.ink)
                    if !product.localizedDescription.isEmpty {
                        Text(product.localizedDescription)
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer()
                if purchasing {
                    ProgressView()
                } else {
                    Text(product.localizedPriceString)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.accent)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(purchasing)
    }

    @ViewBuilder
    private func centered<C: View>(@ViewBuilder _ inner: () -> C) -> some View {
        VStack {
            Spacer()
            inner()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
