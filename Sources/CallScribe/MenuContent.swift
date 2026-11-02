import AppKit
import CallScribeCore
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            Text(model.statusLine)
                .font(.headline)

            if let warning = model.warning, !warning.isEmpty {
                Text("⚠︎ \(warning)")
            }

            if model.activity == .failed {
                Button("Скопировать ошибку") {
                    model.copyLastError()
                }
                Button("Открыть журнал") {
                    model.openLog()
                }
            }

            Divider()

            if model.isRecording {
                Button("Остановить запись") {
                    model.stopRecording()
                }
            } else {
                Button(RecordingKind.call.menuStartTitle) {
                    model.startRecording(kind: .call)
                }
                .disabled(!model.canStart)

                Button(RecordingKind.screen.menuStartTitle) {
                    model.startRecording(kind: .screen)
                }
                .disabled(!model.canStart)
            }

            if model.isBusy && !model.isRecording {
                Text("Подождите, идёт обработка…")
            }

            Divider()

            if model.lastTranscriptURL != nil {
                Button("Открыть последнюю расшифровку") {
                    model.openLastTranscript()
                }
                Button("Скопировать последний текст") {
                    model.copyLastTranscript()
                }
            }

            if model.lastRecordingURL != nil {
                Button("Расшифровать последнюю запись") {
                    model.retryLastTranscription()
                }
                .disabled(!model.canStart)

                Button("Показать последнюю запись в Finder") {
                    model.revealLastRecording()
                }
            }

            Button("Открыть папку расшифровок") {
                model.openTranscriptsFolder()
            }

            Divider()

            Button("Настройки…") {
                model.openSettings()
            }

            Button("Выйти") {
                model.quit()
            }
        }
    }
}
