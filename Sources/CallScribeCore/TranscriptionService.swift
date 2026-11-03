import Foundation
import WhisperKit

public struct WhisperModelVariant: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let approximateSize: String

    public init(id: String, title: String, detail: String, approximateSize: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.approximateSize = approximateSize
    }
}

public enum WhisperModels {
    public static let largeV3 = WhisperModelVariant(
        id: "large-v3-v20240930_626MB",
        title: "Whisper large-v3",
        detail: "Максимальная точность, рекомендована для русского языка",
        approximateSize: "626 МБ"
    )

    public static let largeV3Turbo = WhisperModelVariant(
        id: "large-v3-v20240930_turbo_632MB",
        title: "Whisper large-v3 turbo",
        detail: "Почти как large-v3, но заметно быстрее",
        approximateSize: "632 МБ"
    )

    public static let all: [WhisperModelVariant] = [largeV3, largeV3Turbo]

    public static func variant(id: String) -> WhisperModelVariant {
        all.first(where: { $0.id == id }) ?? largeV3
    }
}

public enum TranscriptionStage: Sendable {
    case downloadingModel
    case loadingModel
    case transcribing
}

public enum TranscriptionError: LocalizedError {
    case emptyAudio
    case emptyResult
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Запись пустая: не удалось получить аудио."
        case .emptyResult:
            return "Whisper не нашёл речь в записи."
        case .modelNotLoaded:
            return "Модель Whisper не загружена."
        }
    }
}

public actor TranscriptionService {
    public static let shared = TranscriptionService()

    private let modelsDirectory: URL
    private var whisperKit: WhisperKit?
    private var loadedVariant: String?
    private var loadTask: Task<WhisperKit, Error>?
    private var loadTaskVariant: String?

    public init(modelsDirectory: URL = AppPaths.models) {
        self.modelsDirectory = modelsDirectory
    }

    public nonisolated var modelDirectory: URL {
        modelsDirectory
    }

    public nonisolated func isModelAvailable(_ variant: String) -> Bool {
        ModelStore.isAvailable(variant, in: modelsDirectory)
    }

    @discardableResult
    public func downloadModel(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try AppPaths.ensureDirectory(modelsDirectory)
        Log.info("Скачивание модели \(variant)")
        let folder = try await ModelStore.download(
            variant: variant,
            into: modelsDirectory,
            progress: progress
        )
        Log.info("Модель доступна: \(folder.path)")
        return folder
    }

    public func transcribe(
        audioURLs: [(url: URL, offset: TimeInterval)],
        language: String,
        variant: String,
        stage: @escaping @Sendable (TranscriptionStage) -> Void,
        modelProgress: @escaping @Sendable (Double) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionData {
        var decoded: [(samples: [Float], offset: TimeInterval)] = []
        for item in audioURLs {
            let samples = try await AudioDecoder.loadSamples16k(from: item.url)
            if !samples.isEmpty {
                decoded.append((samples, item.offset))
            }
        }

        let mixed = AudioDecoder.mix(decoded)
        guard !mixed.isEmpty else {
            throw TranscriptionError.emptyAudio
        }
        let originalDuration = AudioDecoder.duration(samples: mixed)
        let trimmed = AudioDecoder.trimSilence(mixed)
        let samples = trimmed.samples
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        let trimOffset = trimmed.offset
        let duration = AudioDecoder.duration(samples: samples)
        Log.info("Аудио для расшифровки: \(String(format: "%.1f", duration)) c, \(audioURLs.count) дорожек, обрезано \(String(format: "%.1f", trimOffset)) c")

        try await ensureLoaded(variant: variant, stage: stage, progress: modelProgress)

        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        stage(.transcribing)

        whisperKit.segmentDiscoveryCallback = { segments in
            guard duration > 0 else { return }
            let end = segments.map(\.end).max() ?? 0
            progress(min(0.99, Double(end) / duration))
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language == "auto" ? nil : language,
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            sampleLength: 448,
            topK: 5,
            usePrefillPrompt: true,
            detectLanguage: language == "auto",
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        Log.info("Старт расшифровки (язык: \(language), модель: \(variant))")
        let results = await whisperKit.transcribe(audioArrays: [samples], decodeOptions: options)
        guard let resultArray = results.first ?? nil else {
            throw TranscriptionError.emptyResult
        }

        var segments: [TranscriptSegment] = []
        for result in resultArray {
            for segment in result.segments {
                let cleaned = Self.removeKnownArtifacts(segment.text)
                guard !cleaned.isEmpty else { continue }
                if let last = segments.last, last.text == cleaned { continue }
                segments.append(
                    TranscriptSegment(
                        start: segment.start + Float(trimOffset),
                        end: segment.end + Float(trimOffset),
                        text: cleaned
                    )
                )
            }
        }
        segments.sort { $0.start < $1.start }

        let head = segments.map(\.text).joined(separator: " ")
        let fullText = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segments.isEmpty || !fullText.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        let detected = resultArray.first?.language ?? language
        Log.info("Расшифровка готова: \(segments.count) сегментов, язык \(detected)")
        progress(1.0)

        return TranscriptionData(
            text: fullText,
            segments: segments,
            language: detected,
            duration: originalDuration,
            modelVariant: WhisperModels.variant(id: variant).title
        )
    }

    public func preload(variant: String) async {
        guard ModelStore.isAvailable(variant, in: modelsDirectory) else { return }
        if loadedVariant == variant, whisperKit != nil { return }
        do {
            try await ensureLoaded(variant: variant, stage: { _ in }, progress: { _ in })
        } catch {
            Log.error("Не удалось заранее загрузить модель: \(error.localizedDescription)")
        }
    }

    public func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        loadedVariant = nil
    }

    private func ensureLoaded(
        variant: String,
        stage: @escaping @Sendable (TranscriptionStage) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if loadedVariant == variant, whisperKit != nil {
            return
        }

        // A recording can start loading the model in the background. Join that
        // load instead of compiling a second copy of the same model.
        if let loadTask, loadTaskVariant == variant {
            stage(.loadingModel)
            let loaded = try await loadTask.value
            if loadedVariant != variant {
                whisperKit = loaded
                loadedVariant = variant
            }
            self.loadTask = nil
            self.loadTaskVariant = nil
            return
        }

        // Wait for a different model to finish loading before replacing it.
        if let loadTask {
            _ = try? await loadTask.value
            self.loadTask = nil
            self.loadTaskVariant = nil
            if let old = whisperKit {
                await old.unloadModels()
            }
            whisperKit = nil
            loadedVariant = nil
        }

        if let old = whisperKit {
            await old.unloadModels()
        }
        whisperKit = nil
        loadedVariant = nil

        let folder: URL
        if ModelStore.isAvailable(variant, in: modelsDirectory) {
            folder = ModelStore.modelFolder(for: variant, in: modelsDirectory)
        } else {
            stage(.downloadingModel)
            progress(0)
            folder = try await downloadModel(variant: variant, progress: progress)
        }

        stage(.loadingModel)
        Log.info("Загрузка модели Whisper из \(folder.path)")
        let tokenizerFolder = modelsDirectory
        let task = Task {
            try await Self.loadWhisperKit(folder: folder, tokenizerFolder: tokenizerFolder)
        }
        loadTask = task
        loadTaskVariant = variant

        do {
            let loaded = try await task.value
            whisperKit = loaded
            loadedVariant = variant
            loadTask = nil
            loadTaskVariant = nil
            Log.info("Модель Whisper загружена")
        } catch {
            loadTask = nil
            loadTaskVariant = nil
            throw error
        }
    }

    /// Whisper occasionally hallucinates YouTube subtitle credits on noise.
    /// These phrases are never useful in a call transcript, so trim them.
    private static func removeKnownArtifacts(_ text: String) -> String {
        let markers = [
            "субтитры создавал",
            "субтитры создавала",
            "субтитры подготовил",
            "субтитры подготовила",
            "субтитры делал",
            "редактор субтитров",
            "dimatorzok",
            "amara.org",
        ]

        var result = text
        for marker in markers {
            if let range = result.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) {
                result = String(result[..<range.lowerBound])
            }
        }

        // Whisper marks non-speech sounds as *music*, [laughter], etc.
        result = result.replacingOccurrences(
            of: #"\*[^*]{1,40}\*"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[[^\]]{1,40}\]"#,
            with: " ",
            options: .regularExpression
        )

        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadWhisperKit(folder: URL, tokenizerFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }
}
