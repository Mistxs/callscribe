import Foundation

public struct TranscriptSegment: Sendable, Equatable {
    public let start: Float
    public let end: Float
    public let text: String

    public init(start: Float, end: Float, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptionData: Sendable {
    public let text: String
    public let segments: [TranscriptSegment]
    public let language: String
    public let duration: TimeInterval
    public let modelVariant: String

    public init(text: String, segments: [TranscriptSegment], language: String, duration: TimeInterval, modelVariant: String) {
        self.text = text
        self.segments = segments
        self.language = language
        self.duration = duration
        self.modelVariant = modelVariant
    }
}

public struct TranscriptMetadata: Sendable {
    public let title: String
    public let date: Date
    public let duration: TimeInterval
    public let modelTitle: String
    public let language: String
    public let recordingName: String

    public init(title: String, date: Date, duration: TimeInterval, modelTitle: String, language: String, recordingName: String) {
        self.title = title
        self.date = date
        self.duration = duration
        self.modelTitle = modelTitle
        self.language = language
        self.recordingName = recordingName
    }
}

public enum TranscriptWriter {
    public static func makeText(_ data: TranscriptionData, metadata: TranscriptMetadata, includeTimestamps: Bool) -> String {
        var lines: [String] = []
        lines.append("Расшифровка: \(metadata.title)")
        lines.append("Дата: \(Format.humanDate(metadata.date))")
        lines.append("Длительность: \(Format.duration(metadata.duration))")
        lines.append("Модель: \(metadata.modelTitle)")
        if metadata.language == "auto" {
            lines.append("Язык: определён автоматически (\(data.language))")
        } else {
            lines.append("Язык: \(metadata.language)")
        }
        lines.append("Файл записи: \(metadata.recordingName)")
        lines.append("")
        lines.append(String(repeating: "─", count: 48))
        lines.append("")

        if includeTimestamps {
            for segment in data.segments {
                let text = normalise(segment.text)
                guard !text.isEmpty else { continue }
                lines.append("[\(Format.timestamp(segment.start))] \(text)")
            }
        } else {
            lines.append(contentsOf: paragraphs(from: data.segments))
        }

        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result + "\n"
    }

    public static func makeSRT(_ segments: [TranscriptSegment]) -> String {
        var blocks: [String] = []
        var index = 1
        for segment in segments {
            let text = normalise(segment.text)
            guard !text.isEmpty else { continue }
            blocks.append("\(index)")
            blocks.append("\(Format.srtTime(segment.start)) --> \(Format.srtTime(max(segment.end, segment.start + 0.2)))")
            blocks.append(text)
            blocks.append("")
            index += 1
        }
        return blocks.joined(separator: "\n")
    }

    @discardableResult
    public static func write(
        data: TranscriptionData,
        metadata: TranscriptMetadata,
        transcriptFolder: URL,
        baseName: String,
        includeTimestamps: Bool,
        saveSRT: Bool
    ) throws -> [URL] {
        try AppPaths.ensureDirectory(transcriptFolder)
        var written: [URL] = []

        let textURL = transcriptFolder.appendingPathComponent(baseName + ".txt")
        let text = makeText(data, metadata: metadata, includeTimestamps: includeTimestamps)
        try text.write(to: textURL, atomically: true, encoding: .utf8)
        written.append(textURL)

        if saveSRT {
            let srtURL = transcriptFolder.appendingPathComponent(baseName + ".srt")
            try makeSRT(data.segments).write(to: srtURL, atomically: true, encoding: .utf8)
            written.append(srtURL)
        }

        return written
    }

    private static func paragraphs(from segments: [TranscriptSegment]) -> [String] {
        var result: [String] = []
        var current = ""
        var lastEnd: Float = 0
        var segmentCount = 0

        for segment in segments {
            let text = normalise(segment.text)
            guard !text.isEmpty else { continue }
            let gap = segment.start - lastEnd
            if !current.isEmpty && (gap > 1.5 || segmentCount >= 7) {
                result.append(current)
                current = ""
                segmentCount = 0
            }
            if current.isEmpty {
                current = text
            } else {
                current += " " + text
            }
            lastEnd = segment.end
            segmentCount += 1
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
