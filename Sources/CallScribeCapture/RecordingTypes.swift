import Foundation

public enum RecordingKind: String, Sendable {
    case call
    case screen

    public var title: String {
        switch self {
        case .call: return "Звонок"
        case .screen: return "Видео экрана"
        }
    }

    public var fileSuffix: String {
        switch self {
        case .call: return "call"
        case .screen: return "screen"
        }
    }

    public var menuStartTitle: String {
        switch self {
        case .call: return "Записать звонок (аудио)"
        case .screen: return "Записать экран (видео)"
        }
    }
}

public struct RecordingOutput: Sendable {
    public let kind: RecordingKind
    public let primaryURL: URL
    public let microphoneURL: URL?
    public let microphoneOffset: TimeInterval
    public let startedAt: Date
    public let endedAt: Date
    public let warning: String?

    public init(
        kind: RecordingKind,
        primaryURL: URL,
        microphoneURL: URL?,
        microphoneOffset: TimeInterval,
        startedAt: Date,
        endedAt: Date,
        warning: String?
    ) {
        self.kind = kind
        self.primaryURL = primaryURL
        self.microphoneURL = microphoneURL
        self.microphoneOffset = microphoneOffset
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.warning = warning
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    public var baseName: String {
        primaryURL.deletingPathExtension().lastPathComponent
    }

    public var title: String {
        kind.title
    }
}

public struct ActiveRecording {
    public let kind: RecordingKind
    public let primaryURL: URL
    public let microphoneURL: URL?
    public let startedAt: Date
    public let warning: String?

    public init(kind: RecordingKind, primaryURL: URL, microphoneURL: URL?, startedAt: Date, warning: String?) {
        self.kind = kind
        self.primaryURL = primaryURL
        self.microphoneURL = microphoneURL
        self.startedAt = startedAt
        self.warning = warning
    }
}
