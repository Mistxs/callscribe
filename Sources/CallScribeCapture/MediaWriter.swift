import AVFoundation
import CallScribeCore
import Foundation

enum MediaWriterError: LocalizedError {
    case cannotCreateWriter(Error?)
    case cannotAddInput
    case cannotStart(Error?)
    case noSamples
    case writeFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let error):
            return "Не удалось создать файл записи: \(error?.localizedDescription ?? "неизвестная ошибка")"
        case .cannotAddInput:
            return "Не удалось подготовить аудио/видео дорожку."
        case .cannotStart(let error):
            return "Не удалось начать запись: \(error?.localizedDescription ?? "неизвестная ошибка")"
        case .noSamples:
            return "Запись не содержит данных."
        case .writeFailed(let error):
            return "Не удалось сохранить запись: \(error?.localizedDescription ?? "неизвестная ошибка")"
        }
    }
}

/// Serialises all AVAssetWriter work on its own queue.
final class MediaWriter: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.mistxs.callscribe.media-writer")
    private var sessionStarted = false

    init(url: URL, videoSize: CGSize?, audioChannels: Int = 2) throws {
        self.url = url
        let fileType: AVFileType = videoSize == nil ? .m4a : .mov
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw MediaWriterError.cannotCreateWriter(error)
        }

        if let videoSize {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw MediaWriterError.cannotAddInput
            }
            writer.add(input)
            videoInput = input
        } else {
            videoInput = nil
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: audioChannels,
            AVEncoderBitRateKey: audioChannels == 1 ? 96_000 : 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MediaWriterError.cannotAddInput
        }
        writer.add(input)
        audioInput = input

        guard writer.startWriting() else {
            throw MediaWriterError.cannotStart(writer.error)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { self.append(sampleBuffer, to: self.audioInput) }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let videoInput else { return }
        queue.async { self.append(sampleBuffer, to: videoInput) }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard writer.status == .writing else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            Log.error("Не удалось записать семпл: \(self.writer.error?.localizedDescription ?? "неизвестная ошибка")")
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.sessionStarted else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    continuation.resume(throwing: MediaWriterError.noSamples)
                    return
                }

                self.videoInput?.markAsFinished()
                self.audioInput.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .failed {
                        continuation.resume(throwing: MediaWriterError.writeFailed(self.writer.error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.url)
        }
    }
}
