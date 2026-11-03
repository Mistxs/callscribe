import AppKit
import CallScribeCapture
import CallScribeCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var permissionRefresh = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section("Куда сохранять") {
                    HStack(spacing: 10) {
                        Text(AppPaths.displayPath(settings.libraryURL))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Выбрать…") {
                            chooseFolder()
                        }
                        Button("Открыть") {
                            model.openLibraryFolder()
                        }
                    }

                    Text("Внутри будут папки Recordings (записи) и Transcripts (расшифровки).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("Движок распознавания") {
                    Picker("", selection: $settings.engine) {
                        ForEach(RecognitionEngine.allCases, id: \.rawValue) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if settings.recognitionEngine == .gigaam {
                        Text("Русская модель GigaAM v3: лучше держит имена, термины, окончания и пунктуацию. Работает только с русским.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        modelStatusRow(
                            available: model.gigaAMModelAvailable,
                            loadedText: "Модель GigaAM загружена",
                            sizeText: "~221 МБ"
                        )

                        Text("Первое использование: скачивание ~221 МБ. Дальше всё офлайн.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Picker("", selection: $settings.modelID) {
                            ForEach(WhisperModels.all) { variant in
                                Text("\(variant.title) — \(variant.approximateSize)").tag(variant.id)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Text(settings.model.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        modelStatusRow(
                            available: model.modelAvailability[settings.modelID] == true,
                            loadedText: "Модель загружена",
                            sizeText: ""
                        )
                    }
                }

                section("Расшифровка") {
                    HStack {
                        Text("Ваше имя в тексте")
                        Spacer()
                        TextField("Вы", text: $settings.userName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    if settings.recognitionEngine == .whisper {
                        Picker("Язык", selection: $settings.language) {
                            Text("Русский").tag(AppSettings.languageRussian)
                            Text("Определять автоматически").tag(AppSettings.languageAuto)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Text("GigaAM распознаёт только русский. Для других языков выберите Whisper.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Записывать микрофон (ваш голос)", isOn: $settings.includeMicrophone)
                    Toggle("Автоматически расшифровывать после остановки", isOn: $settings.autoTranscribe)
                    Toggle("Добавлять таймкоды в текст", isOn: $settings.includeTimestamps)
                    Toggle("Сохранять субтитры .srt", isOn: $settings.saveSRT)
                }

                section("Разрешения") {
                    permissionRow(
                        title: "Запись экрана и системного звука",
                        granted: Permissions.screenGranted,
                        note: Permissions.screenGranted
                            ? "Разрешено"
                            : "Нажмите «Разрешить», затем включите CallScribe в списке. Если его там нет — нажмите «+» и выберите /Applications/CallScribe.app, после чего перезапустите приложение."
                    ) {
                        Task {
                            _ = Permissions.requestScreen()
                            permissionRefresh = UUID()
                            if !Permissions.screenGranted {
                                Permissions.openScreenSettings()
                            }
                        }
                    }

                    Divider()

                    permissionRow(
                        title: "Микрофон",
                        granted: Permissions.microphoneGranted,
                        note: microphoneNote
                    ) {
                        Task {
                            _ = await Permissions.requestMicrophone()
                            permissionRefresh = UUID()
                        }
                    }

                    HStack {
                        Button("Проверить разрешения") {
                            permissionRefresh = UUID()
                        }
                        Spacer()
                        Button("Перезапустить CallScribe") {
                            model.restartApp()
                        }
                    }
                    .font(.caption)
                }
                .id(permissionRefresh)

                Text("«Записать звонок» — системный звук и микрофон без видео. «Записать экран» — видео экрана плюс звук. Расшифровка идёт локально, текст сохраняется в Transcripts. Для звонков лучше использовать наушники, чтобы микрофон не записывал голос собеседника повторно.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("CallScribe 0.1.0")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Открыть журнал") {
                        model.openLog()
                    }
                    .font(.caption)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 840)
        .onAppear {
            permissionRefresh = UUID()
            model.refreshModelAvailability()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("CallScribe")
                    .font(.title2.weight(.semibold))
                Text("Запись звонков и экрана с локальной расшифровкой")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var microphoneNote: String {
        switch Permissions.microphoneStatus {
        case .authorized:
            return "Разрешено"
        case .denied:
            return "Доступ запрещён — включите в Системных настройках."
        case .restricted:
            return "Доступ ограничен системой."
        case .notDetermined:
            return "Разрешение будет запрошено при первой записи."
        @unknown default:
            return "Неизвестный статус."
        }
    }

    private func modelStatusRow(available: Bool, loadedText: String, sizeText: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(available ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(available ? loadedText : "Будет скачана при первом использовании")
                .font(.caption)

            if !sizeText.isEmpty {
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.activity == .downloading {
                ProgressView(value: model.progress ?? 0)
                    .frame(width: 110)
                Text("\(Int((model.progress ?? 0) * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            } else if available {
                Text("Готова к работе")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Скачать сейчас") {
                    model.downloadSelectedModel()
                }
                .disabled(!model.canStart)
            }
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        note: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(granted ? "Настройки" : "Разрешить", action: action)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.libraryURL
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранять записи и расшифровки"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryFolder = url.path
        }
    }
}
