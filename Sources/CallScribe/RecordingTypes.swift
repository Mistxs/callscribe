import Foundation

enum RecordingKind: String, Sendable {
    case call
    case screen

    var title: String {
        switch self {
        case .call: return "Звонок"
        case .screen: return "Видео экрана"
        }
    }

    var fileSuffix: String {
        switch self {
        case .call: return "call"
        case .screen: return "screen"
        }
    }

    var menuStartTitle: String {
        switch self {
        case .call: return "Записать звонок (аудио)"
        case .screen: return "Записать экран (видео)"
        }
    }
}

struct RecordingOutput: Sendable {
    let kind: RecordingKind
    let primaryURL: URL
    let microphoneURL: URL?
    let microphoneOffset: TimeInterval
    let startedAt: Date
    let endedAt: Date
    let warning: String?

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var baseName: String {
        primaryURL.deletingPathExtension().lastPathComponent
    }

    var title: String {
        kind.title
    }
}

struct ActiveRecording {
    let kind: RecordingKind
    let primaryURL: URL
    let microphoneURL: URL?
    let startedAt: Date
    let warning: String?
}
