import SwiftUI
import AVFoundation
import UIKit

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
