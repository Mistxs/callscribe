import AVFoundation
import CallScribeCore
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum RecordingError: LocalizedError {
    case noDisplay
    case screenPermission
    case microphonePermission
    case noMicrophone
    case captureFailed(Error)
    case emptyFile

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "Не найден экран для записи."
        case .screenPermission:
            return "Нет разрешения на запись экрана."
        case .microphonePermission:
            return "Нет разрешения на запись микрофона."
        case .noMicrophone:
            return "Микрофон не найден."
        case .captureFailed(let error):
            return "Ошибка захвата: \(error.localizedDescription)"
        case .emptyFile:
            return "Запись не создана или получилась пустой."
        }
    }
}

final class SystemRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let url: URL
    private let kind: RecordingKind
    private let queue = DispatchQueue(label: "com.mistxs.callscribe.system-capture")
    private var writer: MediaWriter?
    private var stream: SCStream?
    private var firstSampleTime: CMTime = .invalid
    private var firstAudioTime: CMTime = .invalid
    private var videoSize: CGSize?

    var onFailure: ((Error) -> Void)?

    init(url: URL, kind: RecordingKind) {
        self.url = url
        self.kind = kind
    }

    var firstPresentationTime: CMTime {
        queue.sync { firstAudioTime.isValid ? firstAudioTime : firstSampleTime }
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw RecordingError.captureFailed(error)
        }

        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw RecordingError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 6

        if kind == .screen {
            let size = Self.videoSize(for: display)
            videoSize = size
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.scalesToFit = true
            config.preservesAspectRatio = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            videoSize = nil
            // Video is not delivered because no .screen output is attached.
            config.width = 16
            config.height = 16
        }

        let writer = try MediaWriter(url: url, videoSize: videoSize)
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            if kind == .screen {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            }
            self.stream = stream
            try await stream.startCapture()
            Log.info("Запись запущена: \(self.kind.rawValue), файл \(self.url.lastPathComponent)")
        } catch {
            writer.cancel()
            self.writer = nil
            self.stream = nil
            throw RecordingError.captureFailed(error)
        }
    }

    func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        guard let writer else {
            throw RecordingError.emptyFile
        }
        try await writer.finish()
        self.writer = nil

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw RecordingError.emptyFile
        }
        Log.info("Системная запись сохранена: \(self.url.lastPathComponent), \(size) байт")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstSampleTime == .invalid {
            firstSampleTime = presentationTime
        }
        if type == .audio, firstAudioTime == .invalid {
            firstAudioTime = presentationTime
        }

        if type == .screen {
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            writer?.appendVideo(sampleBuffer)
        } else if type == .audio {
            writer?.appendAudio(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Поток ScreenCaptureKit остановился: \(error.localizedDescription)")
        onFailure?(RecordingError.captureFailed(error))
    }

    private static func videoSize(for display: SCDisplay) -> CGSize {
        let sourceWidth = CGFloat(display.width)
        let sourceHeight = CGFloat(display.height)
        let maxWidth: CGFloat = 1920
        let scale = min(1, maxWidth / max(sourceWidth, 1))
        var width = (sourceWidth * scale).rounded(.down)
        var height = (sourceHeight * scale).rounded(.down)
        width -= width.truncatingRemainder(dividingBy: 2)
        height -= height.truncatingRemainder(dividingBy: 2)
        return CGSize(width: max(2, width), height: max(2, height))
    }
}
