import Foundation
import GigaSTT
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

    public static let largeV3Full = WhisperModelVariant(
        id: "large-v3-v20240930",
        title: "Whisper large-v3 (полная)",
        detail: "Максимальное качество, но больше и медленнее сжатой версии",
        approximateSize: "1.6 ГБ"
    )

    public static let largeV3Turbo = WhisperModelVariant(
        id: "large-v3-v20240930_turbo_632MB",
        title: "Whisper large-v3 turbo",
        detail: "Почти как large-v3, но заметно быстрее",
        approximateSize: "632 МБ"
    )

    public static let all: [WhisperModelVariant] = [largeV3, largeV3Full, largeV3Turbo]

    public static func variant(id: String) -> WhisperModelVariant {
        all.first(where: { $0.id == id }) ?? largeV3
    }
}

public enum AudioTrackKind: Sendable {
    case system
    case microphone
    case other
}

public enum RecognitionEngine: String, Sendable, CaseIterable {
    case gigaam
    case whisper

    public var title: String {
        switch self {
        case .gigaam: return "GigaAM v3 (русский)"
        case .whisper: return "Whisper large-v3 (универсальный)"
        }
    }
}

public struct AudioTrackInput: Sendable {
    public let url: URL
    public let offset: TimeInterval
    public let speaker: String?
    public let kind: AudioTrackKind

    public init(url: URL, offset: TimeInterval = 0, speaker: String? = nil, kind: AudioTrackKind = .other) {
        self.url = url
        self.offset = offset
        self.speaker = speaker
        self.kind = kind
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
    case gigaAMFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Запись пустая: не удалось получить аудио."
        case .emptyResult:
            return "Не удалось найти речь в записи."
        case .modelNotLoaded:
            return "Модель распознавания не загружена."
        case .gigaAMFailed(let reason):
            return "Ошибка GigaAM: \(reason)"
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
    private var gigaAMEngine: Engine?
    private var gigaAMLoadTask: Task<Engine, Error>?

    public init(modelsDirectory: URL = AppPaths.models) {
        self.modelsDirectory = modelsDirectory
    }

    public nonisolated var modelDirectory: URL {
        modelsDirectory
    }

    public nonisolated func isModelAvailable(_ variant: String) -> Bool {
        ModelStore.isAvailable(variant, in: modelsDirectory)
    }

    public nonisolated func isGigaAMModelAvailable() -> Bool {
        GigaAMModelStore.isAvailable(in: modelsDirectory)
    }

    public func downloadGigaAMModel(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try AppPaths.ensureDirectory(modelsDirectory)
        Log.info("Скачивание модели GigaAM")
        return try await GigaAMModelStore.download(into: modelsDirectory, progress: progress)
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
        tracks: [AudioTrackInput],
        language: String,
        variant: String,
        engine: RecognitionEngine,
        stage: @escaping @Sendable (TranscriptionStage) -> Void,
        modelProgress: @escaping @Sendable (Double) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionData {
        struct DecodedTrack {
            let samples: [Float]
            let duration: TimeInterval
            let offset: TimeInterval
            let speaker: String?
            let kind: AudioTrackKind
        }

        struct TaggedSegment {
            let segment: TranscriptSegment
            let kind: AudioTrackKind
        }

        var decoded: [DecodedTrack] = []
        var originalDuration: TimeInterval = 0

        for input in tracks {
            let samples = try await AudioDecoder.loadSamples16k(from: input.url)
            guard !samples.isEmpty else { continue }

            let trackDuration = AudioDecoder.duration(samples: samples)
            originalDuration = max(originalDuration, input.offset + trackDuration)

            let trimmed = AudioDecoder.trimSilence(samples)
            guard !trimmed.samples.isEmpty else { continue }

            decoded.append(
                DecodedTrack(
                    samples: trimmed.samples,
                    duration: AudioDecoder.duration(samples: trimmed.samples),
                    offset: max(0, input.offset + trimmed.offset),
                    speaker: input.speaker,
                    kind: input.kind
                )
            )
        }

        guard !decoded.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        Log.info("Дорожек для расшифровки: \(decoded.count), длительность \(String(format: "%.1f", originalDuration)) c")

        switch engine {
        case .whisper:
            try await ensureLoaded(variant: variant, stage: stage, progress: modelProgress)
        case .gigaam:
            try await ensureGigaAMLoaded(stage: stage, progress: modelProgress)
        }
        stage(.transcribing)

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

        var allSegments: [TaggedSegment] = []
        var detectedLanguage = language

        for (index, track) in decoded.enumerated() {
            let base = Double(index) / Double(decoded.count)
            let span = 1.0 / Double(decoded.count)

            Log.info(
                "Расшифровка дорожки \(index + 1)/\(decoded.count) (\(track.speaker ?? "без спикера")), "
                + "\(String(format: "%.1f", track.duration)) c"
            )

            switch engine {
            case .whisper:
                guard let whisperKit else {
                    throw TranscriptionError.modelNotLoaded
                }
                whisperKit.segmentDiscoveryCallback = { segments in
                    guard track.duration > 0 else { return }
                    let end = segments.map(\.end).max() ?? 0
                    progress(min(0.99, base + span * Double(end) / track.duration))
                }

                let results = await whisperKit.transcribe(audioArrays: [track.samples], decodeOptions: options)
                guard let resultArray = results.first ?? nil else { continue }

                if detectedLanguage == "auto", let language = resultArray.first?.language, !language.isEmpty {
                    detectedLanguage = language
                }

                for result in resultArray {
                    for segment in result.segments {
                        let cleaned = Self.removeKnownArtifacts(segment.text)
                        guard !cleaned.isEmpty else { continue }

                        allSegments.append(
                            TaggedSegment(
                                segment: TranscriptSegment(
                                    start: segment.start + Float(track.offset),
                                    end: segment.end + Float(track.offset),
                                    text: cleaned,
                                    speaker: track.speaker
                                ),
                                kind: track.kind
                            )
                        )
                    }
                }

            case .gigaam:
                let gigaSegments = try await transcribeWithGigaAM(
                    samples: track.samples,
                    offset: track.offset,
                    speaker: track.speaker,
                    base: base,
                    span: span,
                    progress: progress
                )
                for segment in gigaSegments {
                    allSegments.append(TaggedSegment(segment: segment, kind: track.kind))
                }
                if detectedLanguage == "auto" {
                    detectedLanguage = "ru"
                }
            }

            progress(base + span * 0.99)
        }

        // Split long engine segments into sentences. This gives finer speaker
        // turns and lets us remove echo sentence-by-sentence instead of losing
        // a whole 20-second microphone block.
        let expanded = allSegments.flatMap { item in
            Self.splitSegment(item.segment).map { segment in
                TaggedSegment(segment: segment, kind: item.kind)
            }
        }

        let systemSegments = expanded.filter { $0.kind == .system }.map(\.segment)
        var droppedEchoes = 0
        var filteredSegments: [TaggedSegment] = []

        for item in expanded {
            guard item.kind == .microphone, !systemSegments.isEmpty else {
                filteredSegments.append(item)
                continue
            }

            let segment = item.segment
            let nearby = systemSegments.filter { system in
                abs(system.start - segment.start) < 25 || abs(system.end - segment.end) < 25
            }
            let bestSimilarity = nearby.map { Self.textSimilarity(segment.text, $0.text) }.max() ?? 0

            if bestSimilarity > 0.55 {
                droppedEchoes += 1
                continue
            }
            filteredSegments.append(item)
        }

        if droppedEchoes > 0 {
            Log.info("Отброшено эхо микрофона: \(droppedEchoes) предложений")
        }

        let sorted = filteredSegments.sorted {
            if $0.segment.start == $1.segment.start {
                return $0.segment.end < $1.segment.end
            }
            return $0.segment.start < $1.segment.start
        }

        var segments: [TranscriptSegment] = []
        for item in sorted {
            if let last = segments.last,
               last.speaker == item.segment.speaker,
               last.text == item.segment.text {
                continue
            }
            segments.append(item.segment)
        }

        guard !segments.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        let fullText = segments.map { segment -> String in
            if let speaker = segment.speaker, !speaker.isEmpty {
                return "\(speaker): \(segment.text)"
            }
            return segment.text
        }.joined(separator: " ")

        Log.info("Расшифровка готова: \(segments.count) сегментов, язык \(detectedLanguage)")
        progress(1.0)

        let modelTitle: String
        switch engine {
        case .gigaam:
            modelTitle = "GigaAM v3"
        case .whisper:
            modelTitle = WhisperModels.variant(id: variant).title
        }

        return TranscriptionData(
            text: fullText,
            segments: segments,
            language: detectedLanguage,
            duration: originalDuration,
            modelVariant: modelTitle
        )
    }

    public func preload(variant: String) async {
        guard ModelStore.isAvailable(variant, in: modelsDirectory) else { return }
        if loadedVariant == variant, whisperKit != nil { return }
        do {
            try await ensureLoaded(variant: variant, stage: { _ in }, progress: { _ in })
        } catch {
            Log.error("Не удалось заранее загрузить модель Whisper: \(error.localizedDescription)")
        }
    }

    public func preloadGigaAM() async {
        guard GigaAMModelStore.isAvailable(in: modelsDirectory) else { return }
        if gigaAMEngine != nil { return }
        do {
            try await ensureGigaAMLoaded(stage: { _ in }, progress: { _ in })
        } catch {
            Log.error("Не удалось заранее загрузить GigaAM: \(error.localizedDescription)")
        }
    }

    public func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        loadedVariant = nil
    }

    private func transcribeWithGigaAM(
        samples: [Float],
        offset: TimeInterval,
        speaker: String?,
        base: Double,
        span: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard let engine = gigaAMEngine else {
            throw TranscriptionError.modelNotLoaded
        }

        let stream: GigaSTT.Stream
        do {
            stream = try GigaSTT.Stream(engine: engine)
        } catch {
            throw TranscriptionError.gigaAMFailed(error.localizedDescription)
        }

        var result: [TranscriptSegment] = []
        let chunkSize = 16_000 * 20
        var index = 0

        func append(_ segments: [GigaSTT.TranscriptSegment], chunkStart: Double, chunkEnd: Double) {
            for segment in segments where segment.isFinal {
                let text = Self.removeKnownArtifacts(segment.text)
                guard !text.isEmpty else { continue }

                let localStart = segment.words.first.map { Double($0.start) } ?? chunkStart
                let localEnd = segment.words.last.map { Double($0.end) } ?? chunkEnd
                let start = offset + max(0, localStart)
                let end = offset + max(start, localEnd)

                result.append(
                    TranscriptSegment(
                        start: Float(start),
                        end: Float(end),
                        text: text,
                        speaker: speaker
                    )
                )
            }
        }

        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            let chunkStart = Double(index) / 16_000.0
            let chunkEnd = Double(end) / 16_000.0
            let data = Self.pcm16Data(samples[index..<end])

            do {
                let segments = try stream.processChunk(data, sampleRate: 16_000)
                append(segments, chunkStart: chunkStart, chunkEnd: chunkEnd)
            } catch {
                throw TranscriptionError.gigaAMFailed(error.localizedDescription)
            }

            index = end
            progress(base + span * Double(index) / Double(samples.count))
        }

        do {
            let tail = try stream.flush()
            append(tail, chunkStart: Double(samples.count) / 16_000.0, chunkEnd: Double(samples.count) / 16_000.0)
        } catch {
            throw TranscriptionError.gigaAMFailed(error.localizedDescription)
        }

        var deduped: [TranscriptSegment] = []
        for segment in result {
            if let last = deduped.last, last.text == segment.text, last.speaker == segment.speaker {
                continue
            }
            deduped.append(segment)
        }
        return deduped
    }

    private static func pcm16Data(_ samples: ArraySlice<Float>) -> Data {
        var pcm = [Int16](repeating: 0, count: samples.count)
        var index = 0
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            pcm[index] = Int16(clamped * 32767.0).littleEndian
            index += 1
        }
        return pcm.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private func ensureGigaAMLoaded(
        stage: @escaping @Sendable (TranscriptionStage) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if gigaAMEngine != nil {
            return
        }

        if let gigaAMLoadTask {
            stage(.loadingModel)
            let engine = try await gigaAMLoadTask.value
            gigaAMEngine = engine
            self.gigaAMLoadTask = nil
            return
        }

        let directory: URL
        if GigaAMModelStore.isAvailable(in: modelsDirectory) {
            directory = GigaAMModelStore.modelDirectory(in: modelsDirectory)
        } else {
            stage(.downloadingModel)
            progress(0)
            directory = try await downloadGigaAMModel(progress: progress)
        }

        stage(.loadingModel)
        Log.info("Загрузка GigaAM из \(directory.path)")
        let task = Task {
            try Engine(modelDir: directory.path, poolSize: 1)
        }
        gigaAMLoadTask = task

        do {
            let engine = try await task.value
            gigaAMEngine = engine
            gigaAMLoadTask = nil
            Log.info("GigaAM загружена")
        } catch {
            gigaAMLoadTask = nil
            throw TranscriptionError.gigaAMFailed(error.localizedDescription)
        }
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

    private static let latinToCyrillic: [Character: String] = [
        "a": "а", "b": "б", "c": "к", "d": "д", "e": "е", "f": "ф", "g": "г",
        "h": "х", "i": "и", "j": "дж", "k": "к", "l": "л", "m": "м", "n": "н",
        "o": "о", "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "у",
        "v": "в", "w": "в", "x": "кс", "y": "й", "z": "з",
    ]

    private static func normalizeForSimilarity(_ text: String) -> String {
        let mapped = text.lowercased().map { character -> String in
            latinToCyrillic[character] ?? String(character)
        }.joined()
        let cleaned = mapped.replacingOccurrences(of: "ё", with: "е")
        return cleaned
            .replacingOccurrences(of: #"[^а-яa-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitSentences(_ text: String) -> [String] {
        let pattern = #"[^.!?…]+[.!?…]+|[^.!?…]+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let sentence = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }

    private static func splitSegment(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        let sentences = splitSentences(segment.text)
        guard sentences.count > 1 else { return [segment] }

        let totalCharacters = max(1, sentences.reduce(0) { $0 + $1.count })
        let duration = max(0.1, segment.end - segment.start)
        var characterOffset = 0
        var result: [TranscriptSegment] = []

        for sentence in sentences {
            let startFraction = Double(characterOffset) / Double(totalCharacters)
            let endFraction = Double(characterOffset + sentence.count) / Double(totalCharacters)
            characterOffset += sentence.count
            result.append(
                TranscriptSegment(
                    start: segment.start + Float(startFraction) * duration,
                    end: segment.start + Float(endFraction) * duration,
                    text: sentence,
                    speaker: segment.speaker
                )
            )
        }
        return result
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(normalizeForSimilarity(lhs).split(separator: " ").map(String.init))
        let right = Set(normalizeForSimilarity(rhs).split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(min(left.count, right.count))
    }

    /// Whisper occasionally hallucinates YouTube subtitle credits on noise.
    /// These phrases are never useful in a call transcript, so trim them.
    private static func removeKnownArtifacts(_ text: String) -> String {
        // Subtitle credits are usually appended after the real text; cut them.
        let truncateMarkers = [
            "субтитры создавал",
            "субтитры создавала",
            "субтитры создал",
            "субтитры создала",
            "субтитры подготовил",
            "субтитры подготовила",
            "субтитры делал",
            "редактор субтитров",
            "dimatorzok",
            "amara.org",
        ]

        // These often appear at the start of a hallucinated segment; remove the
        // phrase itself and keep the actual speech that follows.
        let removeMarkers = [
            "продолжение следует",
            "спасибо за просмотр",
            "подписывайтесь на канал",
            "ставьте лайки",
        ]

        var result = text
        for marker in truncateMarkers {
            if let range = result.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) {
                result = String(result[..<range.lowerBound])
            }
        }
        for marker in removeMarkers {
            result = result.replacingOccurrences(
                of: marker,
                with: "",
                options: [.caseInsensitive, .diacriticInsensitive]
            )
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

        result = result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.replacingOccurrences(
            of: #"^[\s,.;:—–-]+"#,
            with: "",
            options: .regularExpression
        )
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
