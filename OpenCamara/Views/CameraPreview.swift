import AVFoundation
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(session: session)
        view.setMirrored(isMirrored)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.session = session
        nsView.setMirrored(isMirrored)
    }
}

final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setMirrored(_ mirrored: Bool) {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
