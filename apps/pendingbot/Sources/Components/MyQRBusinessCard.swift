import SwiftUI
import CoreImage.CIFilterBuiltins
import Photos
import Supabase
import UIKit

/// "我的名片" — shared QR business-card view used by both the
/// Friends-tab `MyQRSheet` and the QR section in `AddMeMethodsView`,
/// so the two surfaces stay visually identical.
///
/// Renders the user's currently-active QR-kind handle as a deep-green
/// QR (Liquid Glass card on iOS 26+, plain rounded surface as
/// fallback) with the brand mark in the centre, then avatar + name
/// directly below, then a circular "refresh" button and the user's
/// preset ID row. Long-press the QR to save the card as an image.
///
/// Owns its own load / mint / refresh lifecycle — drop it in and it
/// will fetch (or mint) the active handle on first appear. The active
/// QR token is mirrored to UserDefaults so the card renders instantly
/// on the next open while the network fetch confirms it.
struct MyQRBusinessCard: View {
    @State private var currentValue: String?
    @State private var presetId: String?
    @State private var loading = false
    @State private var error: String?
    @State private var saveStatus: String?
    @State private var qrUIImage: UIImage?
    @State private var idCopied = false
    @State private var confirmRefresh = false

    private let context = CIContext()

    var body: some View {
        VStack(spacing: 22) {
            qrPanel(forSnapshot: false)
                .contextMenu {
                    Button {
                        saveCardImage()
                    } label: {
                        Label("保存图片", systemImage: "square.and.arrow.down")
                    }
                    .disabled(currentValue == nil)
                }
            identityBlock
            VStack(spacing: 14) {
                refreshButton
                idRow
            }
            if let saveStatus {
                Text(saveStatus)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let error {
                Text(error)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .task { await ensureActive() }
    }

    // MARK: - QR panel

    @ViewBuilder
    private func qrPanel(forSnapshot: Bool) -> some View {
        let size: CGFloat = 240
        ZStack {
            qrBackground(size: size, forSnapshot: forSnapshot)

            if loading && qrUIImage == nil {
                ProgressView().controlSize(.large)
            } else if let qr = qrUIImage {
                // Solid white card behind the QR provides the quiet zone
                // scanners need — the surrounding glass background is
                // translucent and unreliable as a "white" baseline.
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

                // Brand mark in the centre — sits inside a soft cream
                // halo so it reads cleanly against the dense pattern.
                // QR uses correctionLevel "H" so up to ~25% of the
                // area can be occluded without breaking scans.
                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
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
    private func qrBackground(size: CGFloat, forSnapshot: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(iOS 26.0, *), !forSnapshot {
            // ImageRenderer can't capture the live blur of Liquid
            // Glass, so the snapshot path uses the plain fallback.
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

    // MARK: - Identity

    @ViewBuilder
    private var identityBlock: some View {
        let store = AccountStore.shared
        let avatarSeed = store.avatarSeed ?? store.current?.id ?? "?"
        let displayName = store.profileDisplayName
            ?? store.current?.displayName ?? "你"
        VStack(spacing: 10) {
            UserAvatar(seed: avatarSeed,
                       attachmentId: store.avatarAttachmentId,
                       size: 56)
            Text(displayName)
                .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
        }
    }

    // MARK: - Refresh

    private var refreshButton: some View {
        Button {
            confirmRefresh = true
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(Theme.Fonts.glyph(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.Palette.accentBg))
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "刷新二维码后，旧码作废",
            isPresented: $confirmRefresh,
            titleVisibility: .visible
        ) {
            Button("刷新", role: .destructive) {
                Task { await refresh() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Preset ID

    @ViewBuilder
    private var idRow: some View {
        if let presetId {
            HStack(spacing: 6) {
                Text(presetId)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                    .onLongPressGesture { copyId(presetId) }
                Button {
                    copyId(presetId)
                } label: {
                    Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(idCopied ? Theme.Palette.accent : Theme.Palette.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyId(_ value: String) {
        UIPasteboard.general.string = value
        Haptics.tap()
        idCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { idCopied = false }
        }
    }

    // MARK: - Data

    private var tokenCacheKey: String? {
        guard let uid = AccountStore.shared.current?.id else { return nil }
        return "MyQRToken.\(uid)"
    }

    /// Applies a QR token: regenerates the rendered image only when the
    /// token actually changed, and mirrors it to UserDefaults so the
    /// next open can paint instantly before the network confirms.
    private func setToken(_ token: String) {
        if currentValue != token {
            qrUIImage = qrImage(for: PendingBotQR.url(forToken: token))
        }
        currentValue = token
        if let key = tokenCacheKey {
            UserDefaults.standard.set(token, forKey: key)
        }
    }

    private func ensureActive() async {
        struct Row: Decodable { let id: String; let value: String }
        if currentValue == nil, let key = tokenCacheKey,
           let cached = UserDefaults.standard.string(forKey: key) {
            setToken(cached)
        }
        if currentValue == nil { loading = true }
        defer { loading = false }
        do {
            let rows: [Row] = try await SupabaseStack.shared
                .from("user_handles")
                .select("id, value")
                .eq("kind", value: "qr")
                .eq("is_active", value: true)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                setToken(row.value)
            } else {
                try await mintNew()
            }
            let idRows: [Row] = try await SupabaseStack.shared
                .from("user_handles")
                .select("id, value")
                .eq("kind", value: "id")
                .limit(1)
                .execute()
                .value
            self.presetId = idRows.first?.value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        loading = true; defer { loading = false }
        do {
            // Revoke ALL active QR-kind handles so only the freshly
            // minted one stays valid afterwards.
            try await SupabaseStack.shared
                .from("user_handles")
                .update(["is_active": false])
                .eq("kind", value: "qr")
                .eq("is_active", value: true)
                .execute()
            try await mintNew()
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mintNew() async throws {
        guard let userId = AccountStore.shared.current?.id else { return }
        let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        let token = String((0..<10).compactMap { _ in alphabet.randomElement() })
        struct Insert: Encodable {
            let user_id: String
            let value: String
            let kind: String
            let label: String?
        }
        try await SupabaseStack.shared
            .from("user_handles")
            .insert(Insert(user_id: userId, value: token, kind: "qr", label: "QR"))
            .execute()
        setToken(token)
    }

    // MARK: - QR image
    //
    // Produces an opaque deep-green-on-cream QR with a 4-module quiet
    // zone baked in. A scannable QR needs (a) ≥4 modules of solid
    // background around the data and (b) a high-contrast colour pair
    // — `CIQRCodeGenerator` provides neither on its own, so we add the
    // border in CGContext and recolour with `CIFalseColor`.
    private func qrImage(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let raw = filter.outputImage else { return nil }

        // Recolour: 0 → deep green (data), 1 → cream (background).
        let recolour = CIFilter.falseColor()
        recolour.inputImage = raw
        recolour.color0 = CIColor(red: 4 / 255.0, green: 71 / 255.0, blue: 53 / 255.0)   // accent
        recolour.color1 = CIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0) // canvas
        guard let coloured = recolour.outputImage else { return nil }

        // Render at 10× without interpolation. CIQRCodeGenerator does NOT
        // emit a quiet zone, so we blit into a slightly larger canvas
        // pre-filled with the same cream colour to give scanners the
        // 4-module margin they need.
        let scale: CGFloat = 10
        let scaled = coloured.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let inner = CGFloat(cg.width)
        let quiet = scale * 4   // 4 modules per QR spec
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
        // Draw via UIImage rather than ctx.cgContext.draw — the CGContext
        // form would flip the result vertically (mirrored QRs don't scan).
        let qrUIImage = UIImage(cgImage: cg)
        return renderer.image { ctx in
            UIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: total, height: total))
            ctx.cgContext.interpolationQuality = .none
            qrUIImage.draw(in: CGRect(x: quiet, y: quiet, width: inner, height: inner))
        }
    }

    // MARK: - Save card image

    private func saveCardImage() {
        let renderer = ImageRenderer(content: snapshotContent)
        renderer.scale = UIScreen.main.scale
        guard let img = renderer.uiImage else {
            updateSaveStatus("保存失败")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    updateSaveStatus("未授权访问相册")
                    return
                }
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                Haptics.success()
                updateSaveStatus("已保存到相册")
            }
        }
    }

    private func updateSaveStatus(_ message: String) {
        saveStatus = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { saveStatus = nil }
        }
    }

    /// View used as the photo-album snapshot. Same QR + identity, on
    /// a plain canvas-tinted backdrop so the saved image looks like a
    /// finished card rather than a window grab.
    @ViewBuilder
    private var snapshotContent: some View {
        VStack(spacing: 22) {
            qrPanel(forSnapshot: true)
            identityBlock
        }
        .padding(28)
        .background(Theme.Palette.canvas)
    }
}
