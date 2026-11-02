import AVFoundation
import CallScribeCore
import CoreMedia
import Foundation

final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let url: URL
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.mistxs.callscribe.microphone")
    private var writer: MediaWriter?
    private var firstSampleTime: CMTime = .invalid

    var onFailure: ((Error) -> Void)?

    init(url: URL) {
        self.url = url
    }

    var firstPresentationTime: CMTime {
        queue.sync { firstSampleTime }
    }

    func start() async throws {
        guard await Permissions.requestMicrophone() else {
            throw RecordingError.microphonePermission
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.noMicrophone
        }

        let writer = try MediaWriter(url: url, videoSize: nil, audioChannels: 1)
        self.writer = writer

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)

            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw MediaWriterError.cannotAddInput
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    self.session.startRunning()
                    continuation.resume()
                }
            }

            guard session.isRunning else {
                throw RecordingError.captureFailed(
                    NSError(domain: "CallScribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон не запустился"])
                )
            }
            Log.info("Микрофон запущен: \(self.url.lastPathComponent)")
        } catch {
            writer.cancel()
            self.writer = nil
            throw error
        }
    }

    func stop() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
        guard let writer else { return }
        try await writer.finish()
        self.writer = nil
        Log.info("Микрофон сохранён: \(self.url.lastPathComponent)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if firstSampleTime == .invalid {
            firstSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
        writer?.appendAudio(sampleBuffer)
    }
}
