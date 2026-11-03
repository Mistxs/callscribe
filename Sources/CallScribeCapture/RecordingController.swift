import CallScribeCore
import CoreMedia
import Foundation

public final class RecordingController {
    private var systemRecorder: SystemRecorder?
    private var microphoneRecorder: MicrophoneRecorder?
    private var active: ActiveRecording?

    public var onFailure: ((Error) -> Void)?

    public init() {}

    public var isActive: Bool {
        active != nil
    }

    public func start(kind: RecordingKind, includeMicrophone: Bool, library: URL) async throws -> ActiveRecording {
        guard active == nil else {
            throw RecordingError.captureFailed(
                NSError(domain: "CallScribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Запись уже идёт"])
            )
        }

        let recordings = try AppPaths.ensureDirectory(AppPaths.recordingsFolder(in: library))
        let startedAt = Date()
        let baseName = Format.fileNameDate(startedAt) + "_" + kind.fileSuffix
        let primaryURL = recordings.appendingPathComponent(baseName + (kind == .call ? ".m4a" : ".mov"))
        let microphoneURL = recordings.appendingPathComponent(baseName + ".mic.m4a")

        let system = SystemRecorder(url: primaryURL, kind: kind)
        system.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }

        do {
            try await system.start()
        } catch {
            systemRecorder = nil
            throw error
        }
        systemRecorder = system

        var mic: MicrophoneRecorder?
        var warning: String?

        if includeMicrophone {
            let recorder = MicrophoneRecorder(url: microphoneURL)
            recorder.onFailure = { [weak self] error in
                self?.onFailure?(error)
            }
            do {
                try await recorder.start()
                mic = recorder
            } catch {
                Log.error("Микрофон не запустился: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: microphoneURL)
                warning = "Микрофон не записывается: \(error.localizedDescription)"
            }
        }
        microphoneRecorder = mic

        let recording = ActiveRecording(
            kind: kind,
            primaryURL: primaryURL,
            microphoneURL: mic == nil ? nil : microphoneURL,
            startedAt: startedAt,
            warning: warning
        )
        active = recording
        return recording
    }

    public func stop() async throws -> RecordingOutput {
        guard let active else {
            throw RecordingError.emptyFile
        }
        let endedAt = Date()
        var warnings: [String] = []
        if let warning = active.warning {
            warnings.append(warning)
        }

        let system = systemRecorder
        var systemError: Error?
        if let system {
            do {
                try await system.stop()
            } catch {
                systemError = error
                Log.error("Ошибка остановки системной записи: \(error.localizedDescription)")
            }
        }
        self.systemRecorder = nil

        var micOffset: TimeInterval = 0
        var micURL: URL?
        if let microphoneRecorder {
            let micFirst = microphoneRecorder.firstPresentationTime
            let systemFirst = system?.firstPresentationTime ?? .invalid
            if systemFirst.isValid, micFirst.isValid {
                let offset = CMTimeGetSeconds(CMTimeSubtract(micFirst, systemFirst))
                if offset.isFinite, abs(offset) < 30 {
                    micOffset = offset
                }
            }

            do {
                try await microphoneRecorder.stop()
                micURL = active.microphoneURL
            } catch {
                Log.error("Ошибка остановки микрофона: \(error.localizedDescription)")
                if let url = active.microphoneURL {
                    try? FileManager.default.removeItem(at: url)
                }
                warnings.append("Дорожка микрофона не сохранилась")
            }
        }
        self.microphoneRecorder = nil
        self.active = nil

        if let systemError {
            throw systemError
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: active.primaryURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw RecordingError.emptyFile
        }

        return RecordingOutput(
            kind: active.kind,
            primaryURL: active.primaryURL,
            microphoneURL: micURL,
            microphoneOffset: micOffset,
            startedAt: active.startedAt,
            endedAt: endedAt,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " · ")
        )
    }

    public func abort() async {
        if let microphoneRecorder {
            try? await microphoneRecorder.stop()
        }
        if let systemRecorder {
            try? await systemRecorder.stop()
        }
        microphoneRecorder = nil
        systemRecorder = nil
        if let active {
            try? FileManager.default.removeItem(at: active.primaryURL)
            if let url = active.microphoneURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        active = nil
    }
}
