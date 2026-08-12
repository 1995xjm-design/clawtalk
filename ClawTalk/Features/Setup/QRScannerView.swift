import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import Vision

/// 全屏二维码扫码页：用于引导页扫描 `openclaw qr` 生成的配对码。
/// 扫到任意二维码后回调原始内容并自动停止相机会话。
struct QRScannerView: UIViewControllerRepresentable {
    /// 扫到二维码时回调原始字符串。
    var onScan: (String) -> Void
    /// 用户主动取消（点关闭按钮）。
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: QRScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

/// 相机扫码控制器（AVFoundation AVCaptureMetadataOutput）。
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, PHPickerViewControllerDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didRecognizeCode = false

    private let closeButton = UIButton(type: .system)
    private let torchButton = UIButton(type: .system)
    private let photoButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let errorLabel = UILabel()
    private let overlayView = ScannerOverlayView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreviewIfAuthorized()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    // MARK: - Camera Setup

    private func setupPreviewIfAuthorized() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                        self.startSession()
                    } else {
                        self.showCameraDenied()
                    }
                }
            }
        default:
            showCameraDenied()
        }
    }

    private func configureSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showCameraUnavailable()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showCameraUnavailable()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        captureSession = session
    }

    private func startSession() {
        guard let captureSession, !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    func stopSession() {
        guard let captureSession, captureSession.isRunning else { return }
        captureSession.stopRunning()
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didRecognizeCode else { return }
        guard let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadata.type == .qr,
              let value = metadata.stringValue,
              !value.isEmpty
        else { return }

        didRecognizeCode = true
        stopSession()
        onScan?(value)
    }

    // MARK: - UI

    private func setupUI() {
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 20
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        torchButton.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
        torchButton.tintColor = .white
        torchButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        torchButton.layer.cornerRadius = 20
        torchButton.translatesAutoresizingMaskIntoConstraints = false
        torchButton.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
        view.addSubview(torchButton)

        photoButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        photoButton.tintColor = .white
        photoButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        photoButton.layer.cornerRadius = 20
        photoButton.translatesAutoresizingMaskIntoConstraints = false
        photoButton.addTarget(self, action: #selector(photoTapped), for: .touchUpInside)
        view.addSubview(photoButton)

        hintLabel.text = "将二维码放入框内即可自动识别"
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 15)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            torchButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            torchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            torchButton.widthAnchor.constraint(equalToConstant: 40),
            torchButton.heightAnchor.constraint(equalToConstant: 40),

            photoButton.trailingAnchor.constraint(equalTo: torchButton.leadingAnchor, constant: -12),
            photoButton.centerYAnchor.constraint(equalTo: torchButton.centerYAnchor),
            photoButton.widthAnchor.constraint(equalToConstant: 40),
            photoButton.heightAnchor.constraint(equalToConstant: 40),

            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48),

            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        stopSession()
        onCancel?()
    }

    @objc private func photoTapped() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage else { return }
            self.recognizeQR(in: image)
        }
    }

    /// Vision 识别相册图片中的二维码（扫码页新增「相册」入口）。
    private func recognizeQR(in image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let request = VNDetectBarcodesRequest { [weak self] request, _ in
            guard let self else { return }
            if let payload = request.results?
                .compactMap({ ($0 as? VNBarcodeObservation)?.payloadStringValue })
                .first {
                DispatchQueue.main.async {
                    self.stopSession()
                    self.onScan?(payload)
                }
            } else {
                DispatchQueue.main.async {
                    self.showError("图片中未识别到二维码")
                }
            }
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }
    @objc private func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            let willEnable = device.torchMode != .on
            device.torchMode = willEnable ? .on : .off
            device.unlockForConfiguration()
            torchButton.setImage(UIImage(systemName: willEnable ? "flashlight.on.fill" : "flashlight.off.fill"), for: .normal)
        } catch {
            // 忽略闪光灯切换失败
        }
    }

    private func showCameraDenied() {
        showError("相机权限被拒绝。\n请在 设置 > ClawTalk > 相机 中开启后重试。")
    }

    private func showCameraUnavailable() {
        showError("无法启动相机，请检查设备是否支持扫码。")
    }

    private func showError(_ message: String) {
        hintLabel.isHidden = true
        errorLabel.text = message
        errorLabel.isHidden = false
    }
}

/// 扫码取景框遮罩：框外压暗 + 白色圆角边框。
final class ScannerOverlayView: UIView {
    private let scanRectLength: CGFloat = 240

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        // 纯装饰遮罩：不拦截触摸，否则会盖住关闭/手电筒/相册按钮（历史「扫码页无法退出」根因）
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let scanRect = CGRect(
            x: (bounds.width - scanRectLength) / 2,
            y: (bounds.height - scanRectLength) / 2,
            width: scanRectLength,
            height: scanRectLength
        )

        // 框外压暗
        let dimPath = UIBezierPath(rect: bounds)
        dimPath.append(UIBezierPath(roundedRect: scanRect, cornerRadius: 16).reversing())
        UIColor.black.withAlphaComponent(0.55).setFill()
        dimPath.fill()

        // 边框
        UIColor.white.withAlphaComponent(0.9).setStroke()
        let border = UIBezierPath(roundedRect: scanRect, cornerRadius: 16)
        border.lineWidth = 3
        border.stroke()
    }
}