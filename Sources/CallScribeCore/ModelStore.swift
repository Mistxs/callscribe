import Foundation

public enum ModelStoreError: LocalizedError {
    case badResponse(Int)
    case invalidTree
    case downloadFailed(String, Error?)
    case missingFiles

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "Сервер моделей ответил кодом \(code)."
        case .invalidTree:
            return "Не удалось прочитать список файлов модели."
        case .downloadFailed(let name, let error):
            return "Не удалось скачать \(name): \(error?.localizedDescription ?? "неизвестная ошибка")"
        case .missingFiles:
            return "Модель скачалась не полностью."
        }
    }
}

public enum ModelStore {
    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let tokenizerRepo = "openai/whisper-large-v3"
    private static let tokenizerFiles = [
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "normalizer.json",
        "vocab.json",
        "merges.txt",
    ]

    public static func modelFolder(for variant: String, in modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(variant, isDirectory: true)
    }

    public static func isAvailable(_ variant: String, in modelsDirectory: URL) -> Bool {
        let folder = modelFolder(for: variant, in: modelsDirectory)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard fm.fileExists(atPath: folder.appendingPathComponent(".complete").path) else {
            return false
        }
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc").path
        let tokenizer = folder.appendingPathComponent("tokenizer.json").path
        return fm.fileExists(atPath: encoder) && fm.fileExists(atPath: tokenizer)
    }

    public static func download(
        variant: String,
        into modelsDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try AppPaths.ensureDirectory(modelsDirectory)
        let target = modelFolder(for: variant, in: modelsDirectory)
        try AppPaths.ensureDirectory(target)

        let remoteFolder = "openai_whisper-" + variant
        let modelEntries = try await fetchTree(repo: modelRepo, folder: remoteFolder)
        var files: [RemoteFile] = []
        for entry in modelEntries where entry.type == "file" {
            guard entry.path.hasPrefix(remoteFolder + "/") else { continue }
            let relative = String(entry.path.dropFirst(remoteFolder.count + 1))
            files.append(
                RemoteFile(
                    url: resolveURL(repo: modelRepo, path: entry.path),
                    destination: target.appendingPathComponent(relative),
                    size: entry.size ?? 0
                )
            )
        }
        guard !files.isEmpty else {
            throw ModelStoreError.invalidTree
        }

        let tokenizerEntries = (try? await fetchTree(repo: tokenizerRepo, folder: nil)) ?? []
        let tokenizerSizes = Dictionary(uniqueKeysWithValues: tokenizerEntries.compactMap { entry -> (String, Int)? in
            guard entry.type == "file", tokenizerFiles.contains(entry.path) else { return nil }
            return (entry.path, entry.size ?? 0)
        })
        for name in tokenizerFiles {
            files.append(
                RemoteFile(
                    url: resolveURL(repo: tokenizerRepo, path: name),
                    destination: target.appendingPathComponent(name),
                    size: tokenizerSizes[name] ?? 0
                )
            )
        }

        let totalBytes = files.reduce(Int64(0)) { $0 + Int64(max(0, $1.size)) }
        var completedBytes: Int64 = 0
        progress(0)

        for file in files {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.destination.path),
               let size = attributes[.size] as? NSNumber,
               file.size == 0 || size.intValue == file.size {
                completedBytes += Int64(max(0, file.size))
                if totalBytes > 0 {
                    progress(min(0.99, Double(completedBytes) / Double(totalBytes)))
                }
                continue
            }

            Log.info("Скачивание \(file.destination.lastPathComponent) (\(file.size) байт)")
            let base = completedBytes
            try await downloadFile(
                from: file.url,
                to: file.destination,
                onProgress: { written, expected in
                    guard totalBytes > 0 else { return }
                    let expectedForProgress = file.size > 0 ? Int64(file.size) : expected
                    let current = min(written, max(0, expectedForProgress))
                    let value = Double(base + current) / Double(totalBytes)
                    progress(min(0.99, max(0, value)))
                }
            )
            completedBytes += Int64(max(0, file.size))
            if totalBytes > 0 {
                progress(min(0.99, Double(completedBytes) / Double(totalBytes)))
            }
        }

        guard isComplete(folder: target) else {
            throw ModelStoreError.missingFiles
        }

        let marker = "\(variant)\n\(Date().ISO8601Format())\n"
        try marker.write(to: target.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        progress(1)
        Log.info("Модель скачана целиком: \(target.path)")
        return target
    }

    private static func isComplete(folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("MelSpectrogram.mlmodelc").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path)
    }

    private static func fetchTree(repo: String, folder: String?) async throws -> [RemoteEntry] {
        let suffix = folder.map { "/\($0)" } ?? ""
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main\(suffix)?recursive=true") else {
            throw ModelStoreError.invalidTree
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.badResponse(http.statusCode)
        }
        do {
            return try JSONDecoder().decode([RemoteEntry].self, from: data)
        } catch {
            throw ModelStoreError.invalidTree
        }
    }

    private static func resolveURL(repo: String, path: String) -> URL {
        let encoded = path.split(separator: "/").map { component in
            String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!
    }

    static func downloadFile(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Int64, Int64) -> Void
    ) async throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let downloader = FileDownloader(destination: destination, onProgress: onProgress)
                try await downloader.download(from: url)
                return
            } catch {
                lastError = error
                Log.error("Ошибка скачивания (попытка \(attempt)): \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
        throw ModelStoreError.downloadFailed(destination.lastPathComponent, lastError)
    }

    private struct RemoteEntry: Decodable {
        let type: String
        let path: String
        let size: Int?
    }

    private struct RemoteFile {
        let url: URL
        let destination: URL
        let size: Int
    }
}

private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var moveError: Error?

    private var resumeFile: URL {
        URL(fileURLWithPath: destination.path + ".resume")
    }

    init(destination: URL, onProgress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws {
        if let resumeData = try? Data(contentsOf: resumeFile), !resumeData.isEmpty {
            do {
                Log.info("Продолжаю скачивание \(destination.lastPathComponent) с сохранённого места")
                try await perform(url: url, resumeData: resumeData)
                return
            } catch {
                Log.error("Не удалось продолжить скачивание: \(error.localizedDescription). Начинаю заново.")
                try? FileManager.default.removeItem(at: resumeFile)
            }
        }
        try await perform(url: url, resumeData: nil)
    }

    private func perform(url: URL, resumeData: Data?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            moveError = nil
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 7_200
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: url)
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let folder = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeFile)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let result: Result<Void, Error>
        if let error {
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resumeData.write(to: resumeFile)
                Log.info("Сохранено место для продолжения скачивания \(destination.lastPathComponent)")
            }
            result = .failure(error)
        } else if let moveError {
            result = .failure(moveError)
        } else if (task.response as? HTTPURLResponse).map({ !(200..<300).contains($0.statusCode) }) == true {
            result = .failure(ModelStoreError.badResponse((task.response as! HTTPURLResponse).statusCode))
        } else {
            result = .success(())
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
