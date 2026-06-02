#if os(iOS)
import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// Group-side counterpart to `MyQRBusinessCard`. Renders the group's
/// active QR-handle as a deep-green QR with the brand mark in the
/// centre, plus the group title below.
///
/// Owns its own load + refresh lifecycle, mirroring the personal QR
/// card: on first appear it reads the active `qr` handle from
/// `group_join_handles` (auto-minted at group creation by migration
/// 0066, so non-admin members always have something to show); admin
/// gets a refresh pill that mints a new value via /v1/groups/:id/handle
/// (the previous QR stops scanning the moment the row is replaced).
///
/// Scanned payload format matches the user QRs:
///   https://bot.pendingname.com/c/<handle>
/// `PendingBotQR.token(fromScanned:)` strips the prefix; the in-app
/// scanner then tries /v1/groups/join first, falling back to
/// /v1/friend-requests — so both kinds of handles work through the
/// same scan path.
struct GroupQRCard: View {
    let conversationId: String
    let groupTitle: String
    /// Kept for call-site compatibility. In the per-inviter model (D2) ANY
    /// member can mint an invite link, so this no longer gates the UI.
    let isAdmin: Bool

    @State private var state: LinkState = .loading
    @State private var copied = false

    enum LinkState: Equatable {
        case loading
        case loaded(token: String)
        case failed(String)
    }

    private let api = APIClient()
    private let context = CIContext()

    private func shareURL(_ token: String) -> String { GroupShareLink.url(forToken: token) }

    var body: some View {
        VStack(spacing: 22) {
            qrPanel
            VStack(spacing: 6) {
                Text(groupTitle.isEmpty ? "未命名群聊" : groupTitle)
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("扫这个码加群 · 7 天有效")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.secondary)
            }
            if case .loaded(let token) = state {
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = shareURL(token)
                        copied = true
                        Haptics.tap()
                    } label: {
                        chipLabel(copied ? "已复制" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await load(forceNew: true) }
                    } label: {
                        chipLabel("重新生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            if case .failed(let msg) = state {
                Text(msg)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .task { if case .loading = state { await load(forceNew: false) } }
    }

    private func chipLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Fonts.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.Palette.accentBg))
    }

    // MARK: - QR panel

    @ViewBuilder
    private var qrPanel: some View {
        let size: CGFloat = 240
        ZStack {
            background(size: size)
            switch state {
            case .loading:
                ProgressView().controlSize(.large)
            case .loaded(let token):
                if let qr = qrImage(for: shareURL(token)) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size - 32, height: size - 32)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white)
                        )
                    Image("BrandMark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.Palette.canvas)
                        )
                } else {
                    Text("生成二维码失败").foregroundStyle(.secondary)
                }
            case .failed:
                Text("生成失败").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func background(size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear
                .frame(width: size, height: size)
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(Theme.Palette.surface)
                .frame(width: size, height: size)
                .overlay(
                    shape.strokeBorder(Theme.Palette.accent.opacity(0.08),
                                       lineWidth: 0.5)
                )
                .shadow(color: Theme.Palette.accent.opacity(0.12),
                        radius: 18, y: 8)
        }
    }

    // MARK: - Data

    /// Mint (or reuse the freshest active) per-inviter group invite link for
    /// this group via /v1/groups/:id/invite-links. Any member may mint.
    private func load(forceNew: Bool) async {
        state = .loading
        copied = false
        do {
            if !forceNew,
               let existing = try await api.listGroupInviteLinks(conversationId: conversationId).first(where: { $0.isActive }) {
                state = .loaded(token: existing.token)
                return
            }
            let link = try await api.createGroupInviteLink(conversationId: conversationId)
            state = .loaded(token: link.token)
        } catch {
            state = .failed((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // Mirrors MyQRBusinessCard.qrImage — kept in sync intentionally
    // (CIQRCodeGenerator + recolour + manual quiet-zone padding). The
    // alternative is extracting a shared helper, which would need
    // pbxproj juggling; this 25-line copy is cheaper for v1.
    private func qrImage(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let raw = filter.outputImage else { return nil }
        let recolour = CIFilter.falseColor()
        recolour.inputImage = raw
        recolour.color0 = CIColor(red: 4 / 255.0, green: 71 / 255.0, blue: 53 / 255.0)
        recolour.color1 = CIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0)
        guard let coloured = recolour.outputImage else { return nil }
        let scale: CGFloat = 10
        let scaled = coloured.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let inner = CGFloat(cg.width)
        let quiet = scale * 4
        let total = inner + quiet * 2
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: total, height: total),
            format: {
                let f = UIGraphicsImageRendererFormat.default()
                f.scale = 1
                f.opaque = true
                return f
            }(),
        )
        return renderer.image { ctx in
            UIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: total, height: total))
            ctx.cgContext.translateBy(x: 0, y: total)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.draw(cg, in: CGRect(x: quiet, y: quiet, width: inner, height: inner))
        }
    }
}
#endif
