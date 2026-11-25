import UIKit
import AVFoundation

/// Màn hình quét mã vạch bằng camera sau.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onResult: ((String?) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let frameView = UIView()
    private var finished = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            configureFocus(device)

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                let wanted: [AVMetadataObject.ObjectType] = [
                    .ean13, .ean8, .upce, .code128, .code39, .code93,
                    .itf14, .interleaved2of5, .qr, .dataMatrix, .pdf417
                ]
                output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
            }

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        frameView.layer.borderColor = UIColor.systemGreen.cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 14
        view.addSubview(frameView)

        let hint = UILabel()
        hint.text = "Đưa mã vạch vào trong khung"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 17, weight: .semibold)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Đóng", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 19, weight: .bold)
        cancel.setTitleColor(.white, for: .normal)
        cancel.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        cancel.layer.cornerRadius = 12
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 180),
            cancel.heightAnchor.constraint(equalToConstant: 52)
        ])

        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        let w = min(view.bounds.width - 48, 420)
        frameView.frame = CGRect(x: (view.bounds.width - w) / 2, y: view.bounds.midY - w * 0.35, width: w, height: w * 0.7)
        if let conn = preview?.connection, conn.isVideoOrientationSupported {
            switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
            case .landscapeLeft: conn.videoOrientation = .landscapeLeft
            case .landscapeRight: conn.videoOrientation = .landscapeRight
            case .portraitUpsideDown: conn.videoOrientation = .portraitUpsideDown
            default: conn.videoOrientation = .portrait
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if preview == nil { finish(nil) }
    }

    private func configureFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        // Máy có camera lấy nét xa (iPhone 13 Pro trở lên): phóng to nhẹ để quét mã nhỏ dễ hơn
        if #available(iOS 15.0, *), device.minimumFocusDistance > 120, device.activeFormat.videoMaxZoomFactor >= 2 {
            device.videoZoomFactor = 2
        }
        device.unlockForConfiguration()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !finished,
              let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue,
              !code.isEmpty else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish(code)
    }

    @objc private func cancelTapped() { finish(nil) }

    private func finish(_ code: String?) {
        guard !finished else { return }
        finished = true
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        let cb = onResult
        dismiss(animated: true) { cb?(code) }
    }
}
