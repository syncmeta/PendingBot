import SwiftUI
import AVFoundation
import UIKit

/// Codec for the contact-share QR.
///
/// Encoded form is a `https://pendingname.com/c/<token>` URL so the
/// QR is "a link" rather than an opaque string — pasting the URL in
/// Safari, scanning with the iOS Camera app, etc. all surface the
/// link cleanly. The path prefix is `/c/` ("contact"); the token is
/// the raw value stored in `user_handles.value` (kind=qr).
///
/// Old QRs minted before this change encoded the bare token. Both
/// the in-app scanner and the worker route accept either form so
/// already-printed QRs keep working.
enum PendingBotQR {
    static let host = "pendingname.com"
    static let pathPrefix = "/c/"

    static func url(forToken token: String) -> String {
        "https://\(host)\(pathPrefix)\(token)"
    }

    /// Parse a scanner payload back into the bare token. Accepts:
    ///   - `https://pendingname.com/c/<token>` (and `http://` / no scheme)
    ///   - bare `<token>` (legacy QRs)
    static func token(fromScanned raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           url.host?.lowercased().hasSuffix(host) == true,
           url.path.hasPrefix(pathPrefix) {
            let token = String(url.path.dropFirst(pathPrefix.count))
            if !token.isEmpty { return token }
        }
        return trimmed
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
