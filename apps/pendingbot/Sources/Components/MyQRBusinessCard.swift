import SwiftUI
import CoreImage
import Supabase
#if os(iOS)
import Photos
import UIKit
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// "我的名片" — shared QR business-card view used by both the
/// Friends-tab `MyQRSheet` and the QR section in `AddMeMethodsView`,
/// so the two surfaces stay visually identical. Cross-platform: QR
/// generation goes through the CoreImage `QRCode.image` shim and the
/// bitmap is held as `PlatformImage`, so the same view serves iOS and
/// macOS (scanning stays iOS-only — this card is the *generate* side).
///
/// Renders the user's currently-active QR-kind handle as a deep-green
/// QR (Liquid Glass card on iOS 26+ / macOS 26+, plain rounded surface
/// as fallback) with the brand mark in the centre, then avatar + name
/// directly below, then a circular "refresh" button and the user's
/// preset ID row. Long-press (right-click on Mac) the QR to save the
/// card as an image — Photos album on iOS, copy-to-clipboard / save
/// panel on macOS.
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
    @State private var qrBitmap: PlatformImage?
    @State private var idCopied = false
    @State private var confirmRefresh = false

    var body: some View {
        VStack(spacing: 22) {
            qrPanel(forSnapshot: false)
                .contextMenu {
                    #if os(iOS)
                    Button {
                        saveCardImage()
                    } label: {
                        Label("保存图片", systemImage: "square.and.arrow.down")
                    }
                    .disabled(currentValue == nil)
                    #else
                    Button {
                        copyCardImage()
                    } label: {
                        Label("拷贝图片", systemImage: "doc.on.doc")
                    }
                    .disabled(currentValue == nil)
                    Button {
                        saveCardImage()
                    } label: {
                        Label("保存图片…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(currentValue == nil)
                    #endif
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

            if loading && qrBitmap == nil {
                ProgressView().controlSize(.large)
            } else if let qr = qrBitmap {
                // Solid white card behind the QR provides the quiet zone
                // scanners need — the surrounding glass background is
                // translucent and unreliable as a "white" baseline.
                Image(platformImage: qr)
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
        if #available(iOS 26.0, macOS 26.0, *), !forSnapshot {
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
        Clipboard.copy(value)
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
            qrBitmap = qrImage(for: PendingBotQR.url(forToken: token))
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
            try await SupabaseStack.authedClient()
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
        try await SupabaseStack.authedClient()
            .from("user_handles")
            .insert(Insert(user_id: userId, value: token, kind: "qr", label: "QR"))
            .execute()
        setToken(token)
    }

    // MARK: - QR image
    //
    // Deep-green-on-cream QR with a baked-in 4-module quiet zone. Runs
    // through the cross-platform `QRCode.image` shim (CoreImage on both
    // iOS and macOS) — same colours + correction level "H" as before,
    // and the shim reproduces the old UIGraphicsImageRenderer quiet-zone
    // composite in CoreImage, so the iOS output is visually identical.
    private func qrImage(for payload: String) -> PlatformImage? {
        QRCode.image(
            payload,
            scale: 10,
            correctionLevel: "H",
            dark: CIColor(red: 4 / 255.0, green: 71 / 255.0, blue: 53 / 255.0),    // accent
            light: CIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0), // canvas
            quietModules: 4,
        )
    }

    // MARK: - Save / copy card image

    /// Renders `snapshotContent` into a platform bitmap at the screen's
    /// backing scale. Shared by the iOS Photos save and the macOS
    /// copy / save-panel paths.
    @MainActor
    private func renderCardImage() -> PlatformImage? {
        let renderer = ImageRenderer(content: snapshotContent)
        #if os(iOS)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
        #elseif os(macOS)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
        #endif
    }

    #if os(iOS)
    private func saveCardImage() {
        guard let img = renderCardImage() else {
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
    #elseif os(macOS)
    private func copyCardImage() {
        guard let img = renderCardImage() else {
            updateSaveStatus("拷贝失败")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        updateSaveStatus("已拷贝到剪贴板")
    }

    private func saveCardImage() {
        guard let img = renderCardImage(),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg)
                  .representation(using: .png, properties: [:]) else {
            updateSaveStatus("保存失败")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "我的名片.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                updateSaveStatus("已保存")
            } catch {
                updateSaveStatus("保存失败")
            }
        }
    }
    #endif

    private func updateSaveStatus(_ message: String) {
        saveStatus = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { saveStatus = nil }
        }
    }

    /// View used as the export snapshot. Same QR + identity, on a plain
    /// canvas-tinted backdrop so the saved image looks like a finished
    /// card rather than a window grab.
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
