@preconcurrency import AVFoundation
import AppKit
import Foundation

@MainActor
final class CameraManager: NSObject, ObservableObject {
    enum CameraState {
        case preparing
        case ready
        case permissionDenied
        case unavailable
    }

    nonisolated(unsafe) let session = AVCaptureSession()

    @Published private(set) var state: CameraState = .preparing
    @Published private(set) var isRecording = false
    @Published private(set) var isCapturingPhoto = false
    @Published private(set) var isMirroringEnabled = false
    @Published private(set) var isProcessingVideo = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var lastCapturedURL: URL?
    @Published private(set) var flashCount = 0
    @Published var errorMessage: String?

    private let sessionQueue = DispatchQueue(label: "com.opencamara.capture-session", qos: .userInitiated)
    private let recordingQueue = DispatchQueue(label: "com.opencamara.mp4-writer", qos: .userInitiated)
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioDataOutput = AVCaptureAudioDataOutput()
    nonisolated(unsafe) private var isConfigured = false
    nonisolated(unsafe) private var includesAudioOutput = false
    nonisolated(unsafe) private var recorder: MP4Recorder?
    private var pendingPhotoURL: URL?
    private var recordingTimer: Timer?

    func requestPermissionsAndStart() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch videoStatus {
        case .authorized:
            requestMicrophoneIfNeededAndConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.requestMicrophoneIfNeededAndConfigure()
                    } else {
                        self.state = .permissionDenied
                    }
                }
            }
        default:
            state = .permissionDenied
        }
    }

    func capturePhoto(to destinationURL: URL) {
        guard state == .ready, !isRecording, !isProcessingVideo, !isCapturingPhoto else { return }
        pendingPhotoURL = destinationURL
        isCapturingPhoto = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            // The request must never exceed the output's configured maximum.
            // Some Mac cameras default to `.balanced` or `.speed`; forcing
            // `.quality` in that case raises an AVFoundation exception.
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func toggleMirroring() {
        guard !isRecording, !isProcessingVideo, !isCapturingPhoto else { return }
        isMirroringEnabled.toggle()
        let shouldMirror = isMirroringEnabled

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setMirroring(shouldMirror, on: self.photoOutput.connection(with: .video))
            self.setMirroring(shouldMirror, on: self.videoDataOutput.connection(with: .video))
        }
    }

    func startRecording(to finalURL: URL) {
        guard state == .ready, !isRecording, !isProcessingVideo else { return }
        isRecording = true
        recordingDuration = 0
        startRecordingTimer()

        recordingQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.recorder = try MP4Recorder(
                    outputURL: finalURL,
                    includesAudio: self.includesAudioOutput
                )
            } catch {
                self.finishWithError(L10n.format("录像失败：%@", error.localizedDescription))
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isProcessingVideo = true
        stopRecordingTimer()
        recordingQueue.async { [weak self] in
            guard let self, let recorder = self.recorder else {
                self?.finishWithError(L10n.string("没有可用的录像保存位置。"))
                return
            }
            self.recorder = nil
            recorder.finish { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isProcessingVideo = false
                    switch result {
                    case .success(let outputURL):
                        self.lastCapturedURL = outputURL
                    case .failure(let error):
                        self.errorMessage = L10n.format("MP4 保存失败：%@", error.localizedDescription)
                    }
                }
            }
        }
    }

    func stopSession() {
        stopRecordingTimer()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func requestMicrophoneIfNeededAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.configureAndStart(includeAudio: granted)
                }
            }
        case .authorized:
            configureAndStart(includeAudio: true)
        default:
            configureAndStart(includeAudio: false)
        }
    }

    private func configureAndStart(includeAudio: Bool) {
        state = .preparing
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession(includeAudio: includeAudio)
                    self.isConfigured = true
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                Task { @MainActor in self.state = .ready }
            } catch {
                Task { @MainActor in
                    self.state = .unavailable
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private nonisolated func configureSession(includeAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            throw CameraError.cameraUnavailable
        }
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else { throw CameraError.cannotAddVideoInput }
        session.addInput(videoInput)

        var addedAudioInput = false
        if includeAudio,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            addedAudioInput = true
        }

        guard session.canAddOutput(photoOutput), session.canAddOutput(videoDataOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(photoOutput)
        session.addOutput(videoDataOutput)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: recordingQueue)

        if addedAudioInput, session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
            audioDataOutput.setSampleBufferDelegate(self, queue: recordingQueue)
            includesAudioOutput = true
        }
    }

    private nonisolated func setMirroring(_ enabled: Bool, on connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = enabled
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        let startDate = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration = Date().timeIntervalSince(startDate)
            }
        }
        recordingTimer?.tolerance = 0.03
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private nonisolated func finishWithError(_ message: String) {
        Task { @MainActor in
            self.isRecording = false
            self.isProcessingVideo = false
            self.stopRecordingTimer()
            self.errorMessage = message
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            Task { @MainActor in
                self.pendingPhotoURL = nil
                self.isCapturingPhoto = false
                self.errorMessage = L10n.format("拍照失败：%@", error.localizedDescription)
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            Task { @MainActor in
                self.pendingPhotoURL = nil
                self.isCapturingPhoto = false
                self.errorMessage = L10n.string("未能生成 JPG 照片。")
            }
            return
        }

        Task { @MainActor in
            guard let destinationURL = self.pendingPhotoURL else { return }
            self.pendingPhotoURL = nil
            self.isCapturingPhoto = false
            do {
                guard let jpegData = Self.jpegData(from: data) else {
                    self.errorMessage = L10n.string("未能将照片转换为 JPG 格式。")
                    return
                }
                try jpegData.write(to: destinationURL, options: .atomic)
                self.lastCapturedURL = destinationURL
                self.flashCount += 1
            } catch {
                self.errorMessage = L10n.format("照片保存失败：%@", error.localizedDescription)
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let recorder else { return }
        let mediaType: AVMediaType
        if output === videoDataOutput {
            mediaType = .video
        } else if output === audioDataOutput {
            mediaType = .audio
        } else {
            return
        }

        if let error = recorder.append(sampleBuffer, mediaType: mediaType) {
            self.recorder = nil
            recorder.cancelAndDelete()
            finishWithError(L10n.format("录像失败：%@", error.localizedDescription))
        }
    }
}

extension CameraManager {
    nonisolated private static func jpegData(from sourceData: Data) -> Data? {
        if sourceData.count >= 2,
           sourceData[sourceData.startIndex] == 0xFF,
           sourceData[sourceData.index(after: sourceData.startIndex)] == 0xD8 {
            return sourceData
        }

        guard let image = NSImage(data: sourceData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }
}

private enum CameraError: LocalizedError {
    case cameraUnavailable
    case cannotAddVideoInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return L10n.string("没有检测到可用的摄像头。")
        case .cannotAddVideoInput: return L10n.string("无法连接摄像头。")
        case .cannotAddOutput: return L10n.string("无法配置拍照或录像输出。")
        }
    }
}
