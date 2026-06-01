#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import Observation

/// App-level inbox for incoming universal links (https deep links). The
/// app root pumps `onOpenURL` here; the tab that owns the matching
/// surface observes the relevant slot and consumes it.
///
/// Mirrors the IncomingCallStore.shared pattern (an @Observable singleton
/// read by the tab views) rather than threading a binding through the
/// whole hierarchy.
@MainActor
@Observable
final class DeepLinkStore {
    static let shared = DeepLinkStore()
    private init() {}

    /// Set when a `bot.pendingname.com/b/<token>` invite link is opened. The
    /// friends tab switches itself in and presents the add-bot preview,
    /// then clears this back to nil.
    var pendingAddBotToken: String?

    /// Parse an incoming URL into a pending action. Returns true when the
    /// link was recognised (so the caller can stop here).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        let raw = url.absoluteString
        if BotShareLink.isBotShareLink(raw) {
            pendingAddBotToken = BotShareLink.token(fromScanned: raw)
            return true
        }
        return false
    }
}

/// Codec for the contact-share QR.
///
/// Encoded form is a `https://bot.pendingname.com/c/<token>` URL — the
/// `bot.` subdomain is the one covered by the Universal Links
/// entitlement (`applinks:bot.pendingname.com`), so a tap on the link
/// opens the app directly when installed. The path prefix is `/c/`
/// ("contact"); the token is the raw value stored in
/// `user_handles.value` (kind=qr).
///
/// Backward compatibility: the parser still accepts the older
/// `pendingname.com/c/<token>` form (bare apex, pre-Universal-Links)
/// and bare-token QRs minted before either URL form existed.
enum PendingBotQR {
    static let host = "bot.pendingname.com"
    static let pathPrefix = "/c/"

    /// Suffix used when *recognising* a scanned URL — intentionally
    /// just `pendingname.com` so apex-host QRs printed before the
    /// `bot.` subdomain switch still parse.
    private static let urlHostSuffix = "pendingname.com"

    static func url(forToken token: String) -> String {
        "https://\(host)\(pathPrefix)\(token)"
    }

    /// Parse a scanner payload back into the bare token. Accepts:
    ///   - `https://bot.pendingname.com/c/<token>` (current form)
    ///   - `https://pendingname.com/c/<token>` (legacy apex QRs)
    ///   - bare `<token>` (oldest QRs)
    static func token(fromScanned raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
           url.path.hasPrefix(pathPrefix) {
            let token = String(url.path.dropFirst(pathPrefix.count))
            if !token.isEmpty { return token }
        }
        return trimmed
    }

    /// Strict check: only true when the scanned payload is unambiguously
    /// a PendingBot contact-share URL (`*pendingname.com/c/<token>`).
    /// Bare tokens are *not* recognised here because they're
    /// indistinguishable from arbitrary scanned text — callers that
    /// want the legacy bare-token behaviour should use
    /// `token(fromScanned:)` directly.
    static func isPendingBotQR(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
              url.path.hasPrefix(pathPrefix) else { return false }
        return !url.path.dropFirst(pathPrefix.count).isEmpty
    }
}

/// Codec for the bot-share deep link (decisions.md D1 — invite-only model).
///
/// Encoded form is `https://bot.pendingname.com/b/<token>` — same `bot.`
/// subdomain as the contact/group QRs (so the Universal Links entitlement
/// applies), AASA path `/b/` (see apps/edge/src/routes/well-known.ts). The
/// payload is an inviter-scoped, revocable invite *token* (minted by
/// POST /v1/bots/:id/invite-links), NOT the bot slug — bots are invite-only.
/// The token is opaque (64 hex); not normalised.
enum BotShareLink {
    static let host = "bot.pendingname.com"
    static let pathPrefix = "/b/"

    /// Matches *pendingname.com so apex-host links (pre-`bot.` subdomain)
    /// still parse, mirroring PendingBotQR.
    private static let urlHostSuffix = "pendingname.com"

    static func url(forToken token: String) -> String {
        "https://\(host)\(pathPrefix)\(token)"
    }

    /// Parse a payload back into the bare invite token. Accepts the current
    /// `bot.pendingname.com/b/<token>` form, the legacy apex form, and a
    /// bare token. Opaque — returned verbatim.
    static func token(fromScanned raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
           url.path.hasPrefix(pathPrefix) {
            let token = String(url.path.dropFirst(pathPrefix.count))
            if !token.isEmpty { return token }
        }
        return trimmed
    }

    /// Strict check: only true when the payload is unambiguously a
    /// bot-share URL (`*pendingname.com/b/<token>`). Bare tokens are not
    /// recognised here (indistinguishable from arbitrary text).
    static func isBotShareLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
              url.path.hasPrefix(pathPrefix) else { return false }
        return !url.path.dropFirst(pathPrefix.count).isEmpty
    }
}

enum DeviceLoginLink {
    static let host = "bot.pendingname.com"
    static let pathPrefix = "/d/"
    private static let urlHostSuffix = "pendingname.com"

    enum AppKind: String, Equatable {
        case pendingBotMacOS = "pendingbot_macos"
        case pendingCrewMacOS = "pendingcrew_macos"
    }

    struct Payload: Equatable, Identifiable {
        let challengeId: String
        let secret: String
        let appKind: AppKind?

        // Identifiable conformance is for SwiftUI .sheet(item:) presenters
        // that want to drive a modal off a scanned payload. challengeId
        // is unique per challenge so it doubles as the identity.
        var id: String { challengeId }
    }

    static func parse(_ raw: String) -> Payload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.host?.lowercased().hasSuffix(urlHostSuffix) == true,
              url.path.hasPrefix(pathPrefix) else { return nil }
        let challengeId = String(url.path.dropFirst(pathPrefix.count))
        guard !challengeId.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let secret = components.queryItems?.first(where: { $0.name == "s" || $0.name == "secret" })?.value,
              !secret.isEmpty else { return nil }
        let appKindValue = components.queryItems?.first(where: { $0.name == "k" || $0.name == "appKind" })?.value
        return Payload(
            challengeId: challengeId,
            secret: secret,
            appKind: appKindValue.flatMap(AppKind.init(rawValue:))
        )
    }
}

/// SwiftUI wrapper around AVCaptureSession for QR-code scanning. The
/// preview fills the parent; first valid QR detection fires `onScan`
/// with the decoded string and stops the session.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onError: (Error) -> Void = { _ in }

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onScan = onScan
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: (String) -> Void = { _ in }
        var onError: (Error) -> Void = { _ in }
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.session.startRunning()
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                session.stopRunning()
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video) else {
                onError(QRError.noCamera); return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) { session.addOutput(output) }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = view.bounds
                view.layer.addSublayer(preview)
                self.preview = preview
            } catch {
                onError(error)
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let str = obj.stringValue else { return }
            // First valid detection wins. Stop the session synchronously so
            // we don't get a flurry of duplicate events while UIKit dismisses
            // the sheet.
            session.stopRunning()
            onScan(str)
        }
    }

    enum QRError: LocalizedError {
        case noCamera
        var errorDescription: String? {
            switch self { case .noCamera: return "找不到相机" }
        }
    }
}
#endif
