import CallScribeCapture
import CallScribeCore
import Foundation

@main
struct CallScribeCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data(("Ошибка: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(0)
        }
        arguments.removeFirst()

        switch command {
        case "models":
            for variant in WhisperModels.all {
                let available = TranscriptionService.shared.isModelAvailable(variant.id)
                print("\(variant.id)\t\(variant.title)\t\(variant.approximateSize)\t\(available ? "загружена" : "нет")")
            }
        case "transcribe":
            try await transcribe(arguments: arguments)
        case "record":
            try await record(arguments: arguments)
        case "-h", "--help", "help":
            printUsage()
        default:
            printUsage()
            exit(2)
        }
    }

    private static func transcribe(arguments: [String]) async throws {
        guard let input = arguments.first, !input.hasPrefix("--") else {
            printUsage()
            exit(2)
        }

        var modelID = WhisperModels.largeV3.id
        var language = "ru"
        var outputPath: String?
        var includeTimestamps = false
        var saveSRT = false
        var quiet = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--model":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--model") }
                modelID = arguments[index]
            case "--language":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--language") }
                language = arguments[index]
            case "--out":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--out") }
                outputPath = arguments[index]
            case "--timestamps":
                includeTimestamps = true
            case "--srt":
                saveSRT = true
            case "--quiet":
                quiet = true
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }

        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(input)
        }

        let variant = WhisperModels.variant(id: modelID)
        FileHandle.standardError.write(Data("Модель: \(variant.title) (\(variant.id))\n".utf8))
        FileHandle.standardError.write(Data("Файл: \(url.path)\n".utf8))

        let started = Date()
        let modelPrinter = StepPrinter(enabled: !quiet)
        let transcriptionPrinter = StepPrinter(enabled: !quiet)
        let data = try await TranscriptionService.shared.transcribe(
            audioURLs: [(url, 0)],
            language: language,
            variant: variant.id,
            stage: { stage in
                switch stage {
                case .downloadingModel:
                    FileHandle.standardError.write(Data("Скачиваю модель…\n".utf8))
                case .loadingModel:
                    FileHandle.standardError.write(Data("Загружаю модель…\n".utf8))
                case .transcribing:
                    FileHandle.standardError.write(Data("Расшифровываю…\n".utf8))
                }
            },
            modelProgress: { value in
                modelPrinter.report(value, label: "модель")
            },
            progress: { value in
                transcriptionPrinter.report(value, label: "расшифровка")
            }
        )

        let elapsed = Date().timeIntervalSince(started)
        let metadata = TranscriptMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            date: Date(),
            duration: data.duration,
            modelTitle: variant.title,
            language: language,
            recordingName: url.lastPathComponent
        )

        if let outputPath {
            let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            let folder = outputURL.deletingLastPathComponent()
            let baseName = outputURL.deletingPathExtension().lastPathComponent
            let files = try TranscriptWriter.write(
                data: data,
                metadata: metadata,
                transcriptFolder: folder,
                baseName: baseName,
                includeTimestamps: includeTimestamps,
                saveSRT: saveSRT
            )
            FileHandle.standardError.write(Data("Сохранено: \(files.map(\.path).joined(separator: ", "))\n".utf8))
        } else {
            print(TranscriptWriter.makeText(data, metadata: metadata, includeTimestamps: includeTimestamps))
        }

        FileHandle.standardError.write(
            Data("Готово за \(String(format: "%.1f", elapsed)) c, аудио \(Format.duration(data.duration)), язык \(data.language)\n".utf8)
        )
    }

    private static func record(arguments: [String]) async throws {
        var seconds: Double = 10
        var kind: RecordingKind = .call
        var includeMicrophone = false
        var library = AppPaths.defaultLibraryFolder

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]) else {
                    throw CLIError.missingValue("--seconds")
                }
                seconds = value
            case "--video":
                kind = .screen
            case "--mic":
                includeMicrophone = true
            case "--out":
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue("--out") }
                library = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }

        guard Permissions.screenGranted else {
            FileHandle.standardError.write(Data("Нет разрешения на запись экрана. Разрешите доступ в Системных настройках и перезапустите терминал.\n".utf8))
            exit(3)
        }

        let controller = RecordingController()
        let active = try await controller.start(
            kind: kind,
            includeMicrophone: includeMicrophone,
            library: library
        )
        FileHandle.standardError.write(Data("Запись \(Int(seconds)) c → \(active.primaryURL.path)\n".utf8))
        try await Task.sleep(nanoseconds: UInt64(max(0.2, seconds) * 1_000_000_000))
        let output = try await controller.stop()
        print(output.primaryURL.path)
        FileHandle.standardError.write(Data("Готово: \(Format.duration(output.duration)) аудио/видео\n".utf8))
    }

    private static func printUsage() {
        print("""
        CallScribe CLI — локальная расшифровка аудио и видео.

        Использование:
          callscribe-cli transcribe <файл> [опции]
          callscribe-cli record [опции]
          callscribe-cli models

        Опции transcribe:
          --model <id>        large-v3-v20240930_626MB (по умолчанию) или large-v3-v20240930_turbo_632MB
          --language <ru|auto>
          --out <файл.txt>    сохранить текст в файл (рядом появится .srt при --srt)
          --timestamps        добавить таймкоды в текст
          --srt               сохранить субтитры
          --quiet             меньше вывода

        Опции record:
          --seconds <n>       длительность записи (по умолчанию 10)
          --video             записать экран вместо аудио
          --mic               добавить микрофон
          --out <папка>       базовая папка (по умолчанию ~/Documents/CallScribe)
        """)
    }

    final class StepPrinter: @unchecked Sendable {
        private let enabled: Bool
        private let lock = NSLock()
        private var lastStep = -1

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func report(_ value: Double, label: String) {
            guard enabled else { return }
            let percent = Int(max(0, min(1, value)) * 100)
            let step = percent / 10
            lock.lock()
            defer { lock.unlock() }
            guard step != lastStep else { return }
            lastStep = step
            FileHandle.standardError.write(Data("  \(label): \(percent)%\n".utf8))
        }
    }

    enum CLIError: LocalizedError {
        case missingValue(String)
        case unknownArgument(String)
        case fileNotFound(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let option):
                return "Для \(option) нужно значение"
            case .unknownArgument(let argument):
                return "Неизвестный аргумент: \(argument)"
            case .fileNotFound(let path):
                return "Файл не найден: \(path)"
            }
        }
    }
}
