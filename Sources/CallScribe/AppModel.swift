import AppKit
import CallScribeCapture
import CallScribeCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case downloading
        case loadingModel
        case transcribing
        case exporting
        case done
        case failed
    }

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var progress: Double?
    @Published private(set) var recordingKind: RecordingKind?
    @Published private(set) var warning: String?
    @Published private(set) var lastTranscriptURL: URL?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastMixedURL: URL?
    @Published private(set) var modelAvailability: [String: Bool] = [:]
    @Published private(set) var detail = "Готово"
    @Published private(set) var lastError: String?

    let settings: AppSettings

    private let recorder = RecordingController()
    private var timer: Timer?
    private var startedAt: Date?
    private var settingsWindow: NSWindow?
    private var lastRecordingOutput: RecordingOutput?

    init(settings: AppSettings) {
        self.settings = settings
        recorder.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.handleRecorderFailure(error)
            }
        }
        refreshModelAvailability()
        restoreLastSession()
        Log.info("Разрешения: экран=\(Permissions.screenGranted), микрофон=\(Permissions.microphoneStatus.rawValue)")

        if CommandLine.arguments.contains("--no-mic") {
            settings.includeMicrophone = false
        }

        if let index = CommandLine.arguments.firstIndex(of: "--record-test"),
           index + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.startRecording(kind: .call)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(2, seconds)) { [weak self] in
                    self?.stopRecording()
                }
            }
        }

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }

        if CommandLine.arguments.contains("--request-screen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.activate(ignoringOtherApps: true)
                _ = Permissions.requestScreen()
                if !Permissions.screenGranted {
                    Permissions.openScreenSettings()
                }
            }
        }
    }

    var isRecording: Bool {
        activity == .recording
    }

    var isBusy: Bool {
        switch activity {
        case .preparing, .recording, .stopping, .downloading, .loadingModel, .transcribing, .exporting:
            return true
        case .idle, .done, .failed:
            return false
        }
    }

    var canStart: Bool {
        switch activity {
        case .idle, .done, .failed:
            return true
        default:
            return false
        }
    }

    var statusLine: String {
        switch activity {
        case .idle:
            return detail
        case .preparing:
            return "Подготовка…"
        case .recording:
            return "● Запись \(Format.duration(elapsed))"
        case .stopping:
            return "Сохраняю запись…"
        case .downloading:
            if let progress {
                return "Скачиваю модель \(Int(progress * 100))%"
            }
            return "Скачиваю модель…"
        case .loadingModel:
            return "Загружаю модель Whisper…"
        case .transcribing:
            if let progress, progress > 0.001 {
                return "Расшифровываю \(Int(progress * 100))%"
            }
            return "Расшифровываю…"
        case .exporting:
            return "Объединяю дорожки в один файл…"
        case .done:
            return detail
        case .failed:
            return "Ошибка: \(lastError ?? "неизвестная ошибка")"
        }
    }

    var menuBarIcon: String {
        switch activity {
        case .recording:
            return "record.circle.fill"
        case .stopping, .downloading, .loadingModel, .transcribing, .exporting, .preparing:
            return "waveform"
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "waveform"
        }
    }

    // MARK: - Recording

    func startRecording(kind: RecordingKind) {
        guard canStart else { return }
        activity = .preparing
        detail = "Подготовка…"
        lastError = nil
        warning = nil
        NSSound(named: "Tink")?.play()

        Task {
            await startRecordingTask(kind: kind)
        }
    }

    private func startRecordingTask(kind: RecordingKind) async {
        if !Permissions.screenGranted {
            let granted = Permissions.requestScreen()
            if !granted {
                activity = .failed
                detail = "Нет разрешения на запись экрана"
                lastError = "Нужно разрешение на запись экрана"
                showScreenPermissionAlert()
                return
            }
        }

        do {
            let active = try await recorder.start(
                kind: kind,
                includeMicrophone: settings.includeMicrophone,
                library: settings.libraryURL
            )
            recordingKind = kind
            startedAt = active.startedAt
            elapsed = 0
            warning = active.warning
            activity = .recording
            detail = ""
            startTimer()
            prepareModelInBackground()
            NSSound(named: "Glass")?.play()
        } catch {
            fail(error)
        }
    }

    func stopRecording() {
        guard activity == .recording else { return }
        activity = .stopping
        timer?.invalidate()
        timer = nil
        Task {
            await finishRecording(transcribe: settings.autoTranscribe)
        }
    }

    private func finishRecording(transcribe: Bool) async {
        do {
            let output = try await recorder.stop()
            startedAt = nil
            elapsed = 0
            lastRecordingOutput = output
            lastRecordingURL = output.primaryURL
            lastMixedURL = nil
            recordingKind = output.kind
            rememberPaths()
            if let outputWarning = output.warning {
                warning = outputWarning
            }
            if transcribe {
                await transcribeRecording(output)
            } else {
                activity = .done
                detail = "Запись сохранена: \(output.primaryURL.lastPathComponent)"
            }
        } catch {
            fail(error)
        }
    }

    private func handleRecorderFailure(_ error: Error) {
        guard activity == .recording else { return }
        Log.error("Захват прерван: \(error.localizedDescription)")
        warning = "Захват прерван: \(error.localizedDescription)"
        activity = .stopping
        timer?.invalidate()
        timer = nil
        Task {
            await finishRecording(transcribe: false)
        }
    }

    // MARK: - Transcription

    private func transcribeRecording(_ output: RecordingOutput) async {
        activity = .transcribing
        progress = 0
        detail = ""
        let variant = settings.modelID

        var audioURLs: [(url: URL, offset: TimeInterval)] = [(output.primaryURL, 0)]
        if let microphoneURL = output.microphoneURL {
            audioURLs.append((microphoneURL, output.microphoneOffset))
        }

        do {
            let data = try await TranscriptionService.shared.transcribe(
                audioURLs: audioURLs,
                language: settings.language,
                variant: variant,
                stage: { [weak self] stage in
                    Task { @MainActor in
                        guard let self else { return }
                        switch stage {
                        case .downloadingModel:
                            self.activity = .downloading
                            self.progress = 0
                        case .loadingModel:
                            self.activity = .loadingModel
                            self.progress = nil
                        case .transcribing:
                            self.activity = .transcribing
                            self.progress = 0
                        }
                    }
                },
                modelProgress: { [weak self] value in
                    Task { @MainActor in
                        guard let self else { return }
                        self.activity = .downloading
                        self.progress = value
                    }
                },
                progress: { [weak self] value in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.activity == .downloading || self.activity == .loadingModel {
                            self.activity = .transcribing
                        }
                        self.progress = value
                    }
                }
            )

            let metadata = TranscriptMetadata(
                title: output.title,
                date: output.startedAt,
                duration: data.duration,
                modelTitle: settings.model.title,
                language: settings.language,
                recordingName: output.primaryURL.lastPathComponent
            )
            let files = try TranscriptWriter.write(
                data: data,
                metadata: metadata,
                transcriptFolder: settings.transcriptsURL,
                baseName: output.baseName,
                includeTimestamps: settings.includeTimestamps,
                saveSRT: settings.saveSRT
            )

            lastTranscriptURL = files.first
            rememberPaths()
            modelAvailability[variant] = true
            progress = nil
            activity = .done
            detail = "Готово: \(files.first?.lastPathComponent ?? "расшифровка")"
            NSSound(named: "Hero")?.play()
            Log.info("Расшифровка сохранена: \(files.map(\.path).joined(separator: ", "))")
        } catch {
            fail(error)
        }
    }

    func retryLastTranscription() {
        guard canStart, let output = lastRecordingOutput else { return }
        guard FileManager.default.fileExists(atPath: output.primaryURL.path) else {
            fail(RecordingError.emptyFile)
            return
        }
        Task {
            await transcribeRecording(output)
        }
    }

    // MARK: - Models

    func refreshModelAvailability() {
        let variants = WhisperModels.all
        Task.detached(priority: .utility) {
            var result: [String: Bool] = [:]
            for variant in variants {
                result[variant.id] = TranscriptionService.shared.isModelAvailable(variant.id)
            }
            let availability = result
            await MainActor.run {
                self.modelAvailability = availability
            }
        }
    }

    func downloadSelectedModel() {
        guard canStart else { return }
        let variant = settings.modelID
        activity = .downloading
        progress = 0
        lastError = nil

        Task {
            do {
                _ = try await TranscriptionService.shared.downloadModel(variant: variant) { [weak self] value in
                    Task { @MainActor in
                        self?.progress = value
                    }
                }
                modelAvailability[variant] = true
                activity = .idle
                progress = nil
                detail = "Модель загружена"
                NSSound(named: "Glass")?.play()
            } catch {
                fail(error)
            }
        }
    }

    // MARK: - Settings window

    func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView()
            .environmentObject(self)
            .environmentObject(settings)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Настройки CallScribe"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 660, height: 900))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Combined file for external services

    var canExportSingleFile: Bool {
        canStart && lastRecordingOutput?.microphoneURL != nil
    }

    func exportLastRecordingAsSingleFile() {
        guard canStart, let output = lastRecordingOutput else { return }
        guard let microphone = output.microphoneURL else {
            detail = "У этой записи нет отдельной дорожки микрофона"
            return
        }

        activity = .exporting
        progress = nil
        detail = "Объединяю дорожки в один файл…"

        Task {
            do {
                let outputURL = output.primaryURL
                    .deletingPathExtension()
                    .appendingPathExtension("mixed.wav")
                let exported = try await AudioExporter.exportMixedWAV(
                    primary: output.primaryURL,
                    microphone: microphone,
                    microphoneOffset: output.microphoneOffset,
                    to: outputURL
                )
                lastMixedURL = exported
                activity = .done
                detail = "Один файл готов: \(exported.lastPathComponent)"
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            } catch {
                fail(error)
            }
        }
    }

    func revealLastMixedFile() {
        guard let lastMixedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastMixedURL])
    }

    // MARK: - Menu actions

    func openTranscriptsFolder() {
        do {
            try AppPaths.ensureDirectory(settings.transcriptsURL)
            NSWorkspace.shared.open(settings.transcriptsURL)
        } catch {
            fail(error)
        }
    }

    func openLibraryFolder() {
        do {
            try AppPaths.ensureDirectory(settings.libraryURL)
            NSWorkspace.shared.open(settings.libraryURL)
        } catch {
            fail(error)
        }
    }

    func openLastTranscript() {
        guard let lastTranscriptURL else {
            openTranscriptsFolder()
            return
        }
        NSWorkspace.shared.open(lastTranscriptURL)
    }

    func revealLastRecording() {
        guard let lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }

    func copyLastTranscript() {
        guard let lastTranscriptURL,
              let text = try? String(contentsOf: lastTranscriptURL, encoding: .utf8) else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        detail = "Текст скопирован в буфер обмена"
    }

    func copyLastError() {
        guard let lastError else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastError, forType: .string)
    }

    func openLog() {
        _ = try? AppPaths.ensureDirectory(AppPaths.logs)
        if !FileManager.default.fileExists(atPath: AppPaths.logFile.path) {
            FileManager.default.createFile(atPath: AppPaths.logFile.path, contents: nil)
        }
        NSWorkspace.shared.open(AppPaths.logFile)
    }

    func restartApp() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    func quit() {
        if activity == .recording {
            activity = .stopping
            timer?.invalidate()
            timer = nil
            Task {
                _ = try? await recorder.stop()
                NSApp.terminate(nil)
            }
            return
        }
        if isBusy {
            let alert = NSAlert()
            alert.messageText = "Прервать текущую операцию?"
            alert.informativeText = "Расшифровка ещё не закончена. Если выйти сейчас, результат не сохранится."
            alert.addButton(withTitle: "Выйти")
            alert.addButton(withTitle: "Остаться")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Loads Whisper while the call is being recorded, so the first transcription
    /// does not have to wait for Core ML to specialise the model.
    private func prepareModelInBackground() {
        let variant = settings.modelID
        Task.detached(priority: .utility) {
            guard TranscriptionService.shared.isModelAvailable(variant) else { return }
            await TranscriptionService.shared.preload(variant: variant)
        }
    }

    private func rememberPaths() {
        let defaults = UserDefaults.standard
        defaults.set(lastRecordingURL?.path, forKey: "lastRecordingPath")
        defaults.set(lastTranscriptURL?.path, forKey: "lastTranscriptPath")
    }

    private func restoreLastSession() {
        let defaults = UserDefaults.standard
        let fm = FileManager.default

        if let path = defaults.string(forKey: "lastTranscriptPath") {
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: url.path) {
                lastTranscriptURL = url
            }
        }

        if let path = defaults.string(forKey: "lastRecordingPath") {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { return }
            lastRecordingURL = url
            let kind: RecordingKind = url.pathExtension.lowercased() == "mov" ? .screen : .call
            recordingKind = kind
            let micURL = url.deletingPathExtension().appendingPathExtension("mic.m4a")
            let mic = fm.fileExists(atPath: micURL.path) ? micURL : nil
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let date = attributes?[.creationDate] as? Date ?? Date()
            lastRecordingOutput = RecordingOutput(
                kind: kind,
                primaryURL: url,
                microphoneURL: mic,
                microphoneOffset: 0,
                startedAt: date,
                endedAt: date,
                warning: nil
            )
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fail(_ error: Error) {
        activity = .failed
        progress = nil
        lastError = error.localizedDescription
        Log.error("\(error.localizedDescription)")
        NSSound(named: "Basso")?.play()
    }

    private func showScreenPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Разрешите запись экрана"
        alert.informativeText = """
        Откройте «Системные настройки» → «Конфиденциальность и безопасность» → «Запись экрана и системного звука» и включите CallScribe.

        Если CallScribe нет в списке, нажмите «+» и выберите /Applications/CallScribe.app. После включения перезапустите приложение.

        Без этого разрешения macOS не отдаёт ни экран, ни системный звук.
        """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openScreenSettings()
        }
    }
}
