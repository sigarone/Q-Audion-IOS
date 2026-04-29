import SwiftUI
import AVFoundation
import QAudionEngine

/// Camera-backed QR scanner.
///
/// Wraps `AVCaptureSession` + `AVCaptureMetadataOutput(.qr)` in a SwiftUI
/// surface. The session auto-stops on the first detected symbol; `onScanned`
/// is invoked exactly once per `QrScannerView` lifetime. To scan another
/// code, dismiss + re-present the view (this is what the `QrScannerSheet`
/// retry path does).
///
/// Permission flow:
/// - `.authorized` / `.notDetermined` → start session immediately (the system
///   shows the prompt on `AVCaptureDevice.requestAccess` if needed).
/// - `.denied` / `.restricted` → render the deny-state with a Settings deep
///   link instead of a black preview.
///
/// The scanner is gated to iOS only — `#if os(iOS)` — so SwiftUI previews on
/// macOS don't break the build.
struct QrScannerView: View {
    /// Invoked exactly once with the raw scanned string. Caller is responsible
    /// for routing through `QrPayloadRouter`.
    let onScanned: (String) -> Void
    /// Invoked when the user taps the Cancel button.
    let onCancel: () -> Void

    @State private var permissionState: PermissionState = .checking
    @State private var hasScanned: Bool = false

    enum PermissionState: Equatable {
        case checking
        case granted
        case denied
        case restricted
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch permissionState {
            case .checking:
                ProgressView()
                    .tint(.white)
            case .granted:
                #if os(iOS)
                ScannerPreview { raw in
                    guard !hasScanned else { return }
                    hasScanned = true
                    onScanned(raw)
                }
                .ignoresSafeArea()
                .overlay { reticleOverlay }
                #else
                Text("La scansione fotocamera è disponibile solo su iOS.")
                    .foregroundStyle(.white)
                #endif
            case .denied:
                deniedView
            case .restricted:
                restrictedView
            }

            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                }
                .padding()
                Spacer()
                if permissionState == .granted {
                    Text("Punta la fotocamera su un QR Q-Audion")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 32)
                }
            }
        }
        .task { await checkPermission() }
    }

    @ViewBuilder
    private var reticleOverlay: some View {
        // Translucent reticle to guide framing — the actual detection happens
        // anywhere in the camera frame; this is purely UX hint.
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.7), lineWidth: 2)
                .frame(width: 260, height: 260)
            ForEach(0..<4) { idx in
                cornerMark(at: idx)
            }
        }
    }

    private func cornerMark(at idx: Int) -> some View {
        let size: CGFloat = 28
        let offset: CGFloat = 130
        // 0=TL, 1=TR, 2=BR, 3=BL
        let xs: [CGFloat] = [-offset, offset, offset, -offset]
        let ys: [CGFloat] = [-offset, -offset, offset, offset]
        let rotations: [Double] = [0, 90, 180, 270]
        return Path { path in
            path.move(to: CGPoint(x: 0, y: size / 2))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size / 2, y: 0))
        }
        .stroke(.cyan, lineWidth: 4)
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotations[idx]))
        .offset(x: xs[idx], y: ys[idx])
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Accesso fotocamera negato")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Q-Audion ha bisogno della fotocamera per scansionare i QR per accoppiare contatti e collegare dispositivi.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            #if os(iOS)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Apri Impostazioni")
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
    }

    private var restrictedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Fotocamera non disponibile")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("L'accesso alla fotocamera è limitato su questo dispositivo (parental control o MDM).")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func checkPermission() async {
        #if os(iOS)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permissionState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
        case .denied:
            permissionState = .denied
        case .restricted:
            permissionState = .restricted
        @unknown default:
            permissionState = .denied
        }
        #else
        permissionState = .restricted
        #endif
    }
}

// MARK: - AVCaptureSession-backed UIViewController wrapper

#if os(iOS)
private struct ScannerPreview: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// `AVCaptureSession`-backed view controller. Owns the session +
/// preview-layer lifetime; suspends in `viewWillDisappear` so a second
/// scanner present cycle gets a fresh, working session.
private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "qaudion.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            return
        }

        let metaOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metaOutput) {
            session.addOutput(metaOutput)
            metaOutput.setMetadataObjectsDelegate(self, queue: .main)
            metaOutput.metadataObjectTypes = [.qr]
        } else {
            session.commitConfiguration()
            return
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let raw = object.stringValue,
              !raw.isEmpty else { return }

        // Stop the session immediately so we don't fire onScanned again
        // for the same symbol on subsequent frames.
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        onScanned?(raw)
    }
}
#endif
