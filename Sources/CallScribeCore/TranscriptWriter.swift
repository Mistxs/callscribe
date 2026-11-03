import Foundation

public struct TranscriptSegment: Sendable, Equatable {
    public let start: Float
    public let end: Float
    public let text: String
    public let speaker: String?

    public init(start: Float, end: Float, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
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

        let speakers = uniqueSpeakers(in: data.segments)
        if !speakers.isEmpty {
            lines.append("Спикеры: \(speakers.joined(separator: ", "))")
        }
        lines.append("Файл записи: \(metadata.recordingName)")
        lines.append("")
        lines.append(String(repeating: "─", count: 48))
        lines.append("")

        let turns = makeTurns(from: data.segments)
        for turn in turns {
            let paragraphs = splitLongText(turn.text, limit: 1_400)
            let prefix = speakerPrefix(turn.speaker)
            for (index, paragraph) in paragraphs.enumerated() {
                if includeTimestamps && index == 0 {
                    lines.append("[\(Format.timestamp(turn.start))] \(prefix)\(paragraph)")
                } else {
                    lines.append(prefix + paragraph)
                }
            }
        }

        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result + "\n"
    }

    public static func makeSRT(_ segments: [TranscriptSegment]) -> String {
        var blocks: [String] = []
        var index = 1
        for segment in segments {
            let text = cleanSentence(segment.text)
            guard !text.isEmpty else { continue }
            let prefix = speakerPrefix(segment.speaker)
            blocks.append("\(index)")
            blocks.append("\(Format.srtTime(segment.start)) --> \(Format.srtTime(max(segment.end, segment.start + 0.2)))")
            blocks.append(prefix + text)
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

    // MARK: - Turns

    private struct Turn {
        let speaker: String?
        let start: Float
        let text: String
    }

    private static func makeTurns(from segments: [TranscriptSegment]) -> [Turn] {
        var groups: [(speaker: String?, start: Float, texts: [String])] = []

        for segment in segments {
            let text = segment.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isBackchannel(text) else { continue }

            if var last = groups.last, sameSpeaker(last.speaker, segment.speaker) {
                last.texts.append(text)
                groups[groups.count - 1] = last
            } else {
                groups.append((segment.speaker, segment.start, [text]))
            }
        }

        return groups.map { group in
            let joined = finalizeTurn(group.texts.joined(separator: " "))
            return Turn(speaker: group.speaker, start: group.start, text: joined)
        }
    }

    private static func finalizeTurn(_ text: String) -> String {
        var result = removeSpokenArtifacts(text)
        result = lowercaseCommonMidSentence(result)
        result = result
            .replacingOccurrences(of: #"([,.;:!?])\1+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = capitalizeSentences(result)
        return dedupeRepeatedSentences(result)
    }

    private static let backchannels: Set<String> = [
        "угу", "ага", "мм", "м", "хм", "э", "а", "и", "раз-раз",
    ]

    private static func isBackchannel(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return backchannels.contains(normalized)
    }

    private static func sameSpeaker(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return left == right
    }

    private static func speakerPrefix(_ speaker: String?) -> String {
        guard let speaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty else {
            return ""
        }
        return "\(speaker): "
    }

    private static func uniqueSpeakers(in segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for segment in segments {
            guard let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty else {
                continue
            }
            if seen.insert(speaker).inserted {
                result.append(speaker)
            }
        }
        return result
    }

    // MARK: - Text cleanup

    private static func cleanSentence(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        result = removeSpokenArtifacts(result)
        result = lowercaseCommonMidSentence(result)

        result = result
            .replacingOccurrences(of: #"([,.;:!?])\1+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isEmpty { return result }
        result = capitalizeSentences(result)
        return result
    }

    private static func removeSpokenArtifacts(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)(?:,\s*)?\b(?:э|а|и|хм|мм)(?:-(?:э|а|и|хм|мм))+\b\s*,?"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:хмм|мм|ээ|аа)\b"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b([А-ЯЁа-яё]+)-\1\b"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s*\.\.\.\s*"#,
            with: ". ",
            options: .regularExpression
        )
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static let commonMidSentenceWords: Set<String> = Set(
        """
        на без в во и а но что это так вот потом сейчас сегодня завтра очень просто можно нужно будет есть был была были
        встречу ассистент статусы разработки скраме ревью устроить знают сформировались хватит вести работу пригласил
        загружаю хожу делики деликах спринт спринты спринтов команде команда команды продуктовой продуктовую процесс
        процессы файлик папку очередь очереди задач задачи таски тасками пользователь пользовательский слой страница
        статья запросов материалы сайт сайта проект проекта направление человек компании компанию год года месяц месяца
        недели неделю день дня время работа работы работу работе делать сделать сделали делали говорить говорю сказал
        сказать понимаю понимаешь знаю знаешь думаю думаешь кажется как бы ли же уже ещё еще только тоже также здесь там
        туда оттуда где когда почему зачем потому поэтому если чтобы или либо при для из от до по с со к ко о об обо у
        за над под через между перед после около вокруг вместо кроме согласно благодаря несмотря всё все всех всем всего
        вся весь этот эта эти этого этой этих этим этими который которая которые которого которой которых которым которыми
        свой своя свои своего своей своих своим своими наш наша наши нашего нашей наших нашим нашими ваш ваша ваши
        вашего вашей ваших вашим вашими их его её ее мой моя мои моего моей моих моим моими твой твоя твои твоего твоей
        твоих твоим твоими один одна одно одни два две три четыре пять шесть семь восемь девять десять двадцать тридцать
        сорок пятьдесят сто тысяча тысячи миллион миллиона первый второй третий четвертый пятый шестой седьмой восьмой
        девятый десятый двадцатый тридцатый новый новая новые нового новой новых новым новыми старый старая старые
        старого старой старых старым старыми большой большая большие большого больших большим большими маленький
        маленькая маленькие маленького маленькой маленьких маленьким маленькими хороший хорошая хорошие хорошего
        хорошей хороших хорошим хорошими плохой плохая плохие плохого плохих плохим плохими главный главная главные
        главного главной главных главным главными важный важная важные важного важной важных важным важными нужный
        нужная нужные нужного нужной нужных нужным нужными конечно наверное например кстати вообще короче значит итак
        соответственно во-первых во-вторых в-третьих ладно хорошо понятно понял да нет ага угу спасибо пожалуйста
        извини извините привет здравствуйте пока давай давайте может быть надо нужно нельзя стоит
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    )

    private static func lowercaseCommonMidSentence(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var atSentenceStart = true

        for var token in tokens {
            if let firstLetter = token.firstIndex(where: { $0.isLetter }) {
                let rest = token[firstLetter...]
                let word = rest.prefix(while: { $0.isLetter || $0 == "-" })
                if !word.isEmpty,
                   !atSentenceStart,
                   word.first?.isUppercase == true,
                   word.allSatisfy({ $0.isLetter || $0 == "-" }),
                   commonMidSentenceWords.contains(word.lowercased()) {
                    let lower = String(word.first!).lowercased()
                    token.replaceSubrange(firstLetter...firstLetter, with: lower)
                }
            }

            result.append(token)
            let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "»\"')"))
            atSentenceStart = stripped.last.map { ".!?…".contains($0) } ?? false
        }

        return result.joined(separator: " ")
    }

    private static func capitalizeSentences(_ text: String) -> String {
        let pattern = #"(^|[.!?…]\s+)([а-яёa-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let range = match.range(at: 2)
            guard let swiftRange = Range(range, in: result) else { continue }
            let letter = String(result[swiftRange]).uppercased()
            result.replaceSubrange(swiftRange, with: letter)
        }
        return result
    }

    private static func dedupeRepeatedSentences(_ text: String) -> String {
        let pattern = #"[^.!?…]+[.!?…]+|[^.!?…]+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result: [String] = []
        var previous = ""

        for match in matches {
            let sentence = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = sentence
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !normalized.isEmpty else { continue }
            if normalized == previous { continue }
            result.append(sentence)
            previous = normalized
        }

        return capitalizeSentences(result.joined(separator: " "))
    }

    private static func splitLongText(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }

        let pattern = #"[^.!?…]+[.!?…]+|[^.!?…]+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        let sentences = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var paragraphs: [String] = []
        var current = ""
        for sentence in sentences where !sentence.isEmpty {
            if !current.isEmpty && current.count + sentence.count + 1 > limit {
                paragraphs.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + " " + sentence
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs.isEmpty ? [text] : paragraphs
    }
}
