import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: "com.mistxs.callscribe", category: "app")
    private static let queue = DispatchQueue(label: "com.mistxs.callscribe.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        append("DEBUG", message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        print(line, terminator: "")
        queue.async {
            do {
                try AppPaths.ensureDirectory(AppPaths.logs)
                let url = AppPaths.logFile
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Logging must never take the app down.
            }
        }
    }
}
