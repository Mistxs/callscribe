import AVFoundation
import Foundation

public enum AudioDecoderError: LocalizedError {
    case noAudioTrack(URL)
    case cannotCreateOutput
    case readFailed(URL, Error?)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack(let url):
            return "В файле нет аудиодорожки: \(url.lastPathComponent)"
        case .cannotCreateOutput:
            return "Не удалось подготовить аудиопоток для расшифровки."
        case .readFailed(let url, let error):
            return "Не удалось прочитать аудио из \(url.lastPathComponent): \(error?.localizedDescription ?? "неизвестная ошибка")"
        }
    }
}

public enum AudioDecoder {
    public static let sampleRate: Int = 16_000

    /// Decodes the first audio track of a media file into 16 kHz mono Float32 samples.
    public static func loadSamples16k(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioDecoderError.noAudioTrack(url)
        }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioDecoderError.readFailed(url, error)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioDecoderError.cannotCreateOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecoderError.readFailed(url, reader.error)
        }

        var samples: [Float] = []
        if duration.isFinite, duration > 0 {
            samples.reserveCapacity(Int(duration * Double(sampleRate)) + sampleRate)
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            if status == kCMBlockBufferNoErr {
                samples.append(contentsOf: chunk)
            }
        }

        if reader.status == .failed {
            throw AudioDecoderError.readFailed(url, reader.error)
        }
        return samples
    }

    /// Mixes tracks that may have slightly different start times.
    /// `offset` is the track's start time in seconds relative to the primary track.
    public static func mix(_ tracks: [(samples: [Float], offset: TimeInterval)]) -> [Float] {
        guard !tracks.isEmpty else { return [] }
        if tracks.count == 1 { return tracks[0].samples }

        var total = 0
        for track in tracks {
            let pad = Int(max(0, track.offset) * Double(sampleRate))
            total = max(total, pad + track.samples.count)
        }
        guard total > 0 else { return [] }

        var mixed = [Float](repeating: 0, count: total)
        for track in tracks {
            let pad = Int(max(0, track.offset) * Double(sampleRate))
            guard pad < total else { continue }
            let available = min(track.samples.count, total - pad)
            track.samples.withUnsafeBufferPointer { source in
                mixed.withUnsafeMutableBufferPointer { destination in
                    guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
                    for index in 0..<available {
                        dst[pad + index] += src[index]
                    }
                }
            }
        }

        // Two close voices can sum above 1.0. Normalize once instead of clipping.
        var peak: Float = 0
        for sample in mixed {
            let value = abs(sample)
            if value > peak { peak = value }
        }
        if peak > 0.99 {
            let scale = 0.99 / peak
            for index in mixed.indices {
                mixed[index] *= scale
            }
        }
        return mixed
    }

    public static func duration(samples: [Float]) -> TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }
}
