import Foundation

public enum AppPaths {
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallScribe", isDirectory: true)
    }

    public static var models: URL {
        applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    public static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }

    public static var logFile: URL {
        logs.appendingPathComponent("CallScribe.log")
    }

    public static var defaultLibraryFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallScribe", isDirectory: true)
    }

    public static func recordingsFolder(in library: URL) -> URL {
        library.appendingPathComponent("Recordings", isDirectory: true)
    }

    public static func transcriptsFolder(in library: URL) -> URL {
        library.appendingPathComponent("Transcripts", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A short, human friendly path for display in the UI.
    public static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
