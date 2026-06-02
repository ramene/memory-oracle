// ScannerView.swift
//
// SwiftUI wrapper around AVCaptureSession for QR scanning. Used by the
// clinician to scan the patient's QR (which encodes patient recipient +
// relay URL). Single-shot: fires onCodeScanned exactly once and stops.

import SwiftUI
import AVFoundation
import UIKit

struct ScannerView: UIViewControllerRepresentable {
    var onCodeScanned: (String) -> Void
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCodeScanned = onCodeScanned
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false   // dedupe — fire callback only once

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("No camera available on this device.")
            return
        }

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                onError?("Cannot add camera input to session.")
                return
            }
            session.addInput(input)
        } catch {
            onError?("Camera setup failed: \(error.localizedDescription)")
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("Cannot add metadata output to session.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.previewLayer = preview
        self.captureSession = session

        // Reticle overlay so the operator knows where to aim
        let reticle = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 240))
        reticle.center = view.center
        reticle.backgroundColor = .clear
        reticle.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        reticle.layer.borderWidth = 2
        reticle.layer.cornerRadius = 10
        view.addSubview(reticle)

        let hint = UILabel(frame: CGRect(x: 0, y: view.bounds.height - 100, width: view.bounds.width, height: 30))
        hint.textAlignment = .center
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 14)
        hint.text = "Point at the patient's QR"
        view.addSubview(hint)

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let s = captureSession, s.isRunning {
            s.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didScan,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else { return }
        didScan = true
        captureSession?.stopRunning()

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        onCodeScanned?(value)
    }
}
