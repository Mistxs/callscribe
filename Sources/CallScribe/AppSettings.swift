import Combine
import Foundation
import CallScribeCore

final class AppSettings: ObservableObject {
    static let languageRussian = "ru"
    static let languageAuto = "auto"

    private let defaults: UserDefaults

    @Published var libraryFolder: String {
        didSet { defaults.set(libraryFolder, forKey: Keys.libraryFolder) }
    }

    @Published var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }

    @Published var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    @Published var includeMicrophone: Bool {
        didSet { defaults.set(includeMicrophone, forKey: Keys.includeMicrophone) }
    }

    @Published var autoTranscribe: Bool {
        didSet { defaults.set(autoTranscribe, forKey: Keys.autoTranscribe) }
    }

    @Published var includeTimestamps: Bool {
        didSet { defaults.set(includeTimestamps, forKey: Keys.includeTimestamps) }
    }

    @Published var saveSRT: Bool {
        didSet { defaults.set(saveSRT, forKey: Keys.saveSRT) }
    }

    @Published var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }

    @Published var engine: String {
        didSet { defaults.set(engine, forKey: Keys.engine) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultLibrary = AppPaths.defaultLibraryFolder.path
        libraryFolder = defaults.string(forKey: Keys.libraryFolder) ?? defaultLibrary
        modelID = defaults.string(forKey: Keys.modelID) ?? WhisperModels.largeV3.id
        language = defaults.string(forKey: Keys.language) ?? Self.languageRussian
        includeMicrophone = defaults.object(forKey: Keys.includeMicrophone) as? Bool ?? true
        autoTranscribe = defaults.object(forKey: Keys.autoTranscribe) as? Bool ?? true
        includeTimestamps = defaults.object(forKey: Keys.includeTimestamps) as? Bool ?? false
        saveSRT = defaults.object(forKey: Keys.saveSRT) as? Bool ?? false
        userName = defaults.string(forKey: Keys.userName) ?? "Вы"
        engine = defaults.string(forKey: Keys.engine) ?? RecognitionEngine.gigaam.rawValue
    }

    var libraryURL: URL {
        URL(fileURLWithPath: (libraryFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    var recordingsURL: URL {
        AppPaths.recordingsFolder(in: libraryURL)
    }

    var transcriptsURL: URL {
        AppPaths.transcriptsFolder(in: libraryURL)
    }

    var model: WhisperModelVariant {
        WhisperModels.variant(id: modelID)
    }

    var languageTitle: String {
        language == Self.languageAuto ? "авто" : "ru"
    }

    var speakerName: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Вы" : trimmed
    }

    var recognitionEngine: RecognitionEngine {
        RecognitionEngine(rawValue: engine) ?? .gigaam
    }

    private enum Keys {
        static let libraryFolder = "libraryFolder"
        static let modelID = "modelID"
        static let language = "language"
        static let includeMicrophone = "includeMicrophone"
        static let autoTranscribe = "autoTranscribe"
        static let includeTimestamps = "includeTimestamps"
        static let saveSRT = "saveSRT"
        static let userName = "userName"
        static let engine = "recognitionEngine"
    }
}
