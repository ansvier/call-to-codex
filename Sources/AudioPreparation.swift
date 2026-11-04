import Foundation
import AVFoundation
import CoreMedia

enum ProcessingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Streaming native decoding: no Python, FFmpeg, or whole-recording allocation.
final class MonoAudioSource {
    let reader: AVAssetReader
    let output: AVAssetReaderAudioMixOutput
    private var buffer: AVAudioPCMBuffer?
    private var position = 0
    private(set) var ended = false

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProcessingError.message("The selected file contains no audio track.") }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProcessingError.message("This audio format could not be decoded by macOS.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProcessingError.message("Audio decoding could not start.") }
        try advance()
    }

    private func advance() throws {
        while let sample = output.copyNextSampleBuffer() {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.commonFormat == .pcmFormatFloat32, format.channelCount == 1,
                  let next = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw ProcessingError.message("macOS returned an unsupported decoded audio format.")
            }
            next.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: next.mutableAudioBufferList) == noErr else {
                throw ProcessingError.message("Could not read decoded audio samples.")
            }
            buffer = next; position = 0
            return
        }
        if reader.status == .failed { throw reader.error ?? ProcessingError.message("Audio decoding failed.") }
        ended = true; buffer = nil
    }

    func read(into target: UnsafeMutablePointer<Float>, count: Int) throws -> Int {
        var written = 0
        while written < count, !ended {
            guard let current = buffer, let samples = current.floatChannelData?[0] else { break }
            let amount = min(count - written, Int(current.frameLength) - position)
            target.advanced(by: written).update(from: samples.advanced(by: position), count: amount)
            written += amount; position += amount
            if position == Int(current.frameLength) { try advance() }
        }
        return written
    }
}

enum AudioPreparation {
    private struct Track { let source: MonoAudioSource; let delay: Int64 }
    struct Result { let frames: Int64; let peak: Float; var hasSignal: Bool { peak > 16.0 / 32768.0 } }

    static func prepare(folder: URL) async throws -> Result {
        let manager = FileManager.default
        let manifest = folder.appendingPathComponent("capture.json")
        var inputs: [(URL, Double)] = []
        if manager.fileExists(atPath: manifest.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
                  let tracks = object["tracks"] as? [[String: Any]] else {
                throw ProcessingError.message("The recording's audio manifest is invalid.")
            }
            for track in tracks {
                guard let file = track["file"] as? String, !file.contains("/"), file != ".", file != "..",
                      let start = track["start"] as? Double, start.isFinite else { continue }
                let url = folder.appendingPathComponent(file)
                if manager.fileExists(atPath: url.path) { inputs.append((url, start)) }
            }
            guard !inputs.isEmpty else { throw ProcessingError.message("No audio was captured. Check microphone and system audio permission in macOS.") }
        } else {
            let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            guard let original = files.first(where: { $0.lastPathComponent.hasPrefix("original.") }) else {
                throw ProcessingError.message("The original recording could not be found.")
            }
            inputs = [(original, 0)]
        }
        let origin = inputs.map(\.1).min() ?? 0
        var tracks: [Track] = []
        for (url, start) in inputs {
            let offset = start - origin
            guard offset >= 0, offset <= 86400 else { throw ProcessingError.message("The audio tracks have incompatible timestamps.") }
            let source = try await MonoAudioSource(url: url)
            if !source.ended { tracks.append(Track(source: source, delay: Int64((offset * 16000).rounded()))) }
        }
        guard !tracks.isEmpty else { throw ProcessingError.message("The recording is empty.") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let output = try AVAudioFile(forWriting: folder.appendingPathComponent("audio.wav"), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let capacity = 4096
        let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity))!
        var scratch = [Float](repeating: 0, count: capacity)
        var position: Int64 = 0
        var peak: Float = 0
        while !tracks.allSatisfy({ $0.source.ended }) {
            mix.frameLength = AVAudioFrameCount(capacity)
            let destination = mix.floatChannelData![0]
            destination.update(repeating: 0, count: capacity)
            var length = 0
            for track in tracks where !track.source.ended {
                let padding = Int(min(Int64(capacity), max(0, track.delay - position)))
                if padding == capacity { length = capacity; continue }
                let count = try scratch.withUnsafeMutableBufferPointer { pointer in
                    try track.source.read(into: pointer.baseAddress!, count: capacity - padding)
                }
                for index in 0..<count { destination[padding + index] += scratch[index] }
                if count > 0 { length = max(length, padding + count) }
            }
            guard length > 0 else { break }
            for index in 0..<length {
                let sample = destination[index].isFinite ? destination[index] : 0
                destination[index] = max(-0.98, min(0.98, sample))
                peak = max(peak, abs(destination[index]))
            }
            mix.frameLength = AVAudioFrameCount(length)
            try output.write(from: mix)
            position += Int64(length)
        }
        return Result(frames: position, peak: peak)
    }
}
