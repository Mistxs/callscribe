import Foundation

public enum GigaAMModelStore {
    public static let variant = "v3_e2e_rnnt"
    private static let repo = "istupakov/gigaam-v3-onnx"

    private struct RemoteFile {
        let remoteName: String
        let localName: String
        let size: Int
    }

    private static let files: [RemoteFile] = [
        RemoteFile(remoteName: "v3_e2e_rnnt_encoder.int8.onnx", localName: "v3_e2e_rnnt_encoder_int8.onnx", size: 224_570_477),
        RemoteFile(remoteName: "v3_e2e_rnnt_decoder.onnx", localName: "v3_e2e_rnnt_decoder.onnx", size: 4_599_910),
        RemoteFile(remoteName: "v3_e2e_rnnt_joint.onnx", localName: "v3_e2e_rnnt_joint.onnx", size: 2_712_896),
        RemoteFile(remoteName: "v3_e2e_rnnt_vocab.txt", localName: "v3_e2e_rnnt_vocab.txt", size: 13_354),
    ]

    public static func modelDirectory(in modelsRoot: URL) -> URL {
        modelsRoot
            .appendingPathComponent("GigaAM", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    public static func isAvailable(in modelsRoot: URL) -> Bool {
        let directory = modelDirectory(in: modelsRoot)
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(".complete").path) else {
            return false
        }
        return files.allSatisfy { file in
            let path = directory.appendingPathComponent(file.localName).path
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.intValue == file.size
        }
    }

    public static func download(
        into modelsRoot: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let directory = modelDirectory(in: modelsRoot)
        try AppPaths.ensureDirectory(directory)

        let total = files.reduce(0) { $0 + $1.size }
        var completed = 0
        progress(0)

        for file in files {
            let destination = directory.appendingPathComponent(file.localName)

            if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue == file.size {
                completed += file.size
                progress(min(0.99, Double(completed) / Double(total)))
                continue
            }

            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.remoteName)") else {
                throw ModelStoreError.downloadFailed(file.remoteName, nil)
            }

            Log.info("Скачивание GigaAM: \(file.remoteName) (\(file.size) байт)")
            let base = completed
            try await ModelStore.downloadFile(from: url, to: destination, onProgress: { written, _ in
                let current = min(Int64(file.size), max(0, written))
                progress(min(0.99, Double(base) + Double(current) / Double(total)))
            })
            completed += file.size
            progress(min(0.99, Double(completed) / Double(total)))
        }

        let fm = FileManager.default
        guard files.allSatisfy({ fm.fileExists(atPath: directory.appendingPathComponent($0.localName).path) }) else {
            throw ModelStoreError.missingFiles
        }

        let marker = "\(variant)\n\(Date().ISO8601Format())\n"
        try marker.write(to: directory.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        progress(1)
        Log.info("Модель GigaAM скачана: \(directory.path)")
        return directory
    }
}
