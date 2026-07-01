#if os(iOS) && canImport(AVFoundation) && canImport(UIKit) && canImport(SwiftUI)
import AVFoundation
import SwiftUI
import UIKit

public struct CatapocketQRScannerView: UIViewControllerRepresentable {
    public let onCode: (String) -> Void

    public init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    public func updateUIViewController(_ uiViewController: ScannerViewController,
                                       context: Context) {}

    public final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var didScan = false

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            didScan = false
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.startRunning()
                }
            }
        }

        public override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.stopRunning()
                }
            }
        }

        private func configure() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                    guard allowed else { return }
                    DispatchQueue.main.async {
                        self?.configureSession()
                    }
                }
            case .denied, .restricted:
                showCameraDenied()
            @unknown default:
                showCameraDenied()
            }
        }

        private func configureSession() {
            guard previewLayer == nil,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                showCameraDenied()
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                showCameraDenied()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
        }

        public func metadataOutput(_ output: AVCaptureMetadataOutput,
                                   didOutput metadataObjects: [AVMetadataObject],
                                   from connection: AVCaptureConnection) {
            guard !didScan,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            didScan = true
            onCode?(value)
        }

        private func showCameraDenied() {
            let label = UILabel()
            label.text = "Camera access is needed to scan Catapult's Catapocket QR code."
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
    }
}
#endif
