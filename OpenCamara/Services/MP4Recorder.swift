@preconcurrency import AVFoundation
import Foundation

/// Writes camera samples directly into a fragmented MP4 file.
/// Media data is flushed in short fragments while recording; stopping only
/// finalizes the container and does not transcode the completed recording.
final class MP4Recorder {
    let outputURL: URL

    private let writer: AVAssetWriter
    private let includesAudio: Bool
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime?
    private var storedError: Error?

    init(outputURL: URL, includesAudio: Bool) throws {
        self.outputURL = outputURL
        self.includesAudio = includesAudio
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieTimeScale = 600
    }

    func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) -> Error? {
        guard storedError == nil, CMSampleBufferDataIsReady(sampleBuffer) else { return storedError }

        if sessionStartTime == nil {
            guard mediaType == .video else { return nil }
            do {
                try beginSession(using: sampleBuffer)
            } catch {
                storedError = error
                return error
            }
        }

        guard let sessionStartTime else { return nil }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime >= sessionStartTime else { return nil }

        let input = mediaType == .video ? videoInput : audioInput
        guard let input, input.isReadyForMoreMediaData else { return nil }

        if !input.append(sampleBuffer) {
            let error = writer.error ?? RecorderError.couldNotAppendSample
            storedError = error
            return error
        }
        return nil
    }

    func finish(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        if let storedError {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            completion(.failure(storedError))
            return
        }

        guard sessionStartTime != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            completion(.failure(RecorderError.noVideoFrames))
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let outputURL = outputURL
        let writerBox = AssetWriterBox(writer)
        writer.finishWriting { [writerBox] in
            if writerBox.writer.status == .completed {
                completion(.success(outputURL))
            } else {
                let error = writerBox.writer.error ?? RecorderError.couldNotFinishWriting
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(error))
            }
        }
    }

    func cancelAndDelete() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func beginSession(using videoSampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(videoSampleBuffer) else {
            throw RecorderError.missingVideoFormat
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let width = max(Int(dimensions.width), 1)
        let height = max(Int(dimensions.height), 1)
        let averageBitRate = min(max(width * height * 6, 4_000_000), 16_000_000)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings,
            sourceFormatHint: formatDescription
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.couldNotAddVideoInput }
        writer.add(videoInput)
        self.videoInput = videoInput

        if includesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.couldNotStartWriting
        }

        let startTime = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
        writer.startSession(atSourceTime: startTime)
        sessionStartTime = startTime
    }
}

private final class AssetWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private enum RecorderError: LocalizedError {
    case missingVideoFormat
    case couldNotAddVideoInput
    case couldNotStartWriting
    case couldNotAppendSample
    case couldNotFinishWriting
    case noVideoFrames

    var errorDescription: String? {
        switch self {
        case .missingVideoFormat,
             .couldNotAddVideoInput,
             .couldNotStartWriting,
             .couldNotAppendSample,
             .couldNotFinishWriting,
             .noVideoFrames:
            return L10n.string("无法创建 MP4 文件。")
        }
    }
}
