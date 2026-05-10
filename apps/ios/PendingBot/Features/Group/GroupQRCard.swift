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
    let isAdmin: Bool

    @State private var currentValue: String?
    @State private var loading = false
    @State private var refreshing = false
    @State private var error: String?

    private let context = CIContext()

    var body: some View {
        VStack(spacing: 22) {
            qrPanel
            VStack(spacing: 6) {
                Text(groupTitle.isEmpty ? "未命名群聊" : groupTitle)
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("扫这个码加群")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isAdmin {
                refreshButton
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .task { await ensureActive() }
    }

    // MARK: - QR panel

    @ViewBuilder
    private var qrPanel: some View {
        let size: CGFloat = 240
        ZStack {
            background(size: size)
            if loading {
                ProgressView().controlSize(.large)
            } else if let value = currentValue, !value.isEmpty,
                      let qr = qrImage(for: PendingBotQR.url(forToken: value)) {
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
                Text("生成二维码失败")
                    .foregroundStyle(.secondary)
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

    // MARK: - Refresh

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            HStack(spacing: 6) {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("刷新（旧码作废）")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.Palette.accentBg))
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
    }

    // MARK: - Data

    private func ensureActive() async {
        loading = true; defer { loading = false }
        struct Row: Decodable {
            let handle_type: String
            let value: String
        }
        do {
            let rows: [Row] = try await SupabaseStack.shared
                .from("group_join_handles")
                .select("handle_type, value")
                .eq("conversation_id", value: conversationId)
                .eq("handle_type", value: "qr")
                .limit(1)
                .execute()
                .value
            self.currentValue = rows.first?.value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        refreshing = true; defer { refreshing = false }
        let fresh = randomHandleToken()
        do {
            try await postHandle(value: fresh)
            self.currentValue = fresh
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func postHandle(value: String) async throws {
        struct Body: Encodable {
            let handleType: String
            let value: String
        }
        let url = HostedConfig.environment.workerURL
            .appendingPathComponent("v1/groups/\(conversationId)/handle")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await SupabaseStack.shared.auth.session.accessToken
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(handleType: "qr", value: value))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw NSError(
                domain: "GroupQR",
                code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: msg],
            )
        }
    }

    /// 8 chars from the lowercase + digit alphabet (skip 0/o/1/l/i for
    /// readability) — matches the server's [A-Za-z0-9_-]{4,20} guard
    /// and the migration-0066 trigger that mints handles at creation.
    private func randomHandleToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
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
