import SwiftUI
import CoreImage.CIFilterBuiltins
import Photos
import Supabase

/// "我的名片" — shared QR business-card view used by both the
/// Friends-tab `MyQRSheet` and the QR section in `AddMeMethodsView`,
/// so the two surfaces stay visually identical.
///
/// Renders the user's currently-active QR-kind handle as a deep-green
/// QR (Liquid Glass card on iOS 26+, plain rounded surface as
/// fallback) with the brand mark in the centre, then avatar + name
/// directly below, then a light-green "refresh" pill. Long-press the
/// QR to save the card as an image.
///
/// Owns its own load / mint / refresh lifecycle — drop it in and it
/// will fetch (or mint) the active handle on first appear.
struct MyQRBusinessCard: View {
    @State private var currentValue: String?
    @State private var loading = false
    @State private var error: String?
    @State private var saveStatus: String?

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
            refreshButton
            if let saveStatus {
                Text(saveStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let error {
                Text(error)
                    .font(.footnote)
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

            if loading {
                ProgressView().controlSize(.large)
            } else if let value = currentValue, let mask = qrMaskImage(for: value) {
                // Tint: solid deep green, masked through the QR's
                // alpha pattern. Inverted+mask-to-alpha makes the data
                // pixels opaque and the white background drop out.
                Theme.Palette.accent
                    .frame(width: size - 32, height: size - 32)
                    .mask {
                        Image(uiImage: mask)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    }

                // Brand mark in the centre — sits inside a soft cream
                // halo so it reads cleanly against the dense pattern.
                // QR uses correctionLevel "H" so up to ~25% of the
                // area can be occluded without breaking scans.
                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            Task { await refresh() }
        } label: {
            Label("刷新（旧码作废）", systemImage: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.Palette.accentBg))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func ensureActive() async {
        loading = true; defer { loading = false }
        struct Row: Decodable { let id: String; let value: String }
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
                self.currentValue = row.value
            } else {
                try await mintNew()
            }
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
        self.currentValue = token
    }

    // MARK: - QR mask image
    //
    // Inverts the generator's black-on-white output and converts to
    // alpha mask so SwiftUI's `.mask()` can colour the data pixels in
    // deep green while letting the background drop out entirely.
    private func qrMaskImage(for s: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "H"
        guard let out = filter.outputImage else { return nil }

        let invert = CIFilter.colorInvert()
        invert.inputImage = out
        guard let inverted = invert.outputImage else { return nil }

        let mask = CIFilter.maskToAlpha()
        mask.inputImage = inverted
        guard let masked = mask.outputImage else { return nil }

        let scaled = masked.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
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
