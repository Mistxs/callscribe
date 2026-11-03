import Foundation

public enum AudioExportError: LocalizedError {
    case emptyAudio
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "В записи нет аудио для объединения."
        case .cannotWrite(let reason):
            return "Не удалось записать объединённый файл: \(reason)"
        }
    }
}

public enum AudioExporter {
    /// Mixes the system-audio track and the microphone track into one
    /// speech-friendly WAV file (16 kHz, mono, PCM 16-bit).
    @discardableResult
    public static func exportMixedWAV(
        primary: URL,
        microphone: URL?,
        microphoneOffset: TimeInterval,
        to output: URL
    ) async throws -> URL {
        let primarySamples = try await AudioDecoder.loadSamples16k(from: primary)
        var tracks: [(samples: [Float], offset: TimeInterval)] = [(primarySamples, 0)]

        if let microphone {
            let micSamples = try await AudioDecoder.loadSamples16k(from: microphone)
            tracks.append((micSamples, microphoneOffset))
        }

        let mixed = AudioDecoder.mix(tracks)
        guard !mixed.isEmpty else {
            throw AudioExportError.emptyAudio
        }

        try writeWAV(samples: mixed, sampleRate: AudioDecoder.sampleRate, to: output)
        Log.info("Объединённый файл сохранён: \(output.path), \(mixed.count) сэмплов")
        return output
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, to output: URL) throws {
        let fm = FileManager.default
        do {
            try AppPaths.ensureDirectory(output.deletingLastPathComponent())
            if fm.fileExists(atPath: output.path) {
                try fm.removeItem(at: output)
            }
            guard fm.createFile(atPath: output.path, contents: nil) else {
                throw AudioExportError.cannotWrite("не удалось создать файл")
            }
        } catch let error as AudioExportError {
            throw error
        } catch {
            throw AudioExportError.cannotWrite(error.localizedDescription)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: output)
        } catch {
            throw AudioExportError.cannotWrite(error.localizedDescription)
        }
        defer { try? handle.close() }

        let dataSize = samples.count * MemoryLayout<Int16>.size
        let header = makeHeader(dataSize: dataSize, sampleRate: sampleRate)

        do {
            try handle.write(contentsOf: header)

            var chunk = [Int16]()
            chunk.reserveCapacity(8192)
            for sample in samples {
                let clamped = max(-1.0, min(1.0, sample))
                chunk.append(Int16(clamped * 32767.0))
                if chunk.count == 8192 {
                    try writeChunk(chunk, to: handle)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                try writeChunk(chunk, to: handle)
            }
        } catch {
            throw AudioExportError.cannotWrite(error.localizedDescription)
        }
    }

    private static func writeChunk(_ chunk: [Int16], to handle: FileHandle) throws {
        let littleEndian = chunk.map { $0.littleEndian }
        let data = littleEndian.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        try handle.write(contentsOf: data)
    }

    private static func makeHeader(dataSize: Int, sampleRate: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data) // PCM
        appendLE(UInt16(1), to: &data) // mono
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(sampleRate * 2), to: &data) // byte rate
        appendLE(UInt16(2), to: &data) // block align
        appendLE(UInt16(16), to: &data) // bits per sample

        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(dataSize), to: &data)
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
