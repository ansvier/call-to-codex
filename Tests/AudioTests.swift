import Foundation
import AVFoundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProcessingError.message("FAIL: " + message) }
}

private func writeCAF(_ url: URL, amplitude: Float, channels: AVAudioChannelCount = 1) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    buffer.frameLength = 48000
    for channel in 0..<Int(channels) { buffer.floatChannelData![channel].update(repeating: amplitude, count: 48000) }
    try file.write(from: buffer)
}

private func samples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    try expect(file.processingFormat.sampleRate == 16000, "output must be 16 kHz")
    try expect(file.processingFormat.channelCount == 1, "output must be mono")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

@main struct AudioTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("call-to-codex-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mix = root.appendingPathComponent("mix")
        try FileManager.default.createDirectory(at: mix, withIntermediateDirectories: true)
        try writeCAF(mix.appendingPathComponent("system.caf"), amplitude: 0.1)
        try writeCAF(mix.appendingPathComponent("microphone.caf"), amplitude: 0.2)
        let manifest: [String: Any] = ["tracks": [["file": "system.caf", "start": 100.0], ["file": "microphone.caf", "start": 100.5]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: mix.appendingPathComponent("capture.json"))
        let result = try await AudioPreparation.prepare(folder: mix)
        let audio = try samples(mix.appendingPathComponent("audio.wav"))
        try expect(abs(Int(result.frames) - 24000) < 64, "independent tracks must retain their 0.5 s offset")
        try expect(abs(audio[4000] - 0.1) < 0.01, "early section must contain system audio only")
        try expect(abs(audio[12000] - 0.3) < 0.01, "overlap must contain both voices")
        try expect(abs(audio[20000] - 0.2) < 0.01, "late section must contain microphone only")
        try expect(result.hasSignal, "normal speech level must be accepted")
        print("PASS: native resampling and two-track clock alignment")

        let silent = root.appendingPathComponent("silent")
        try FileManager.default.createDirectory(at: silent, withIntermediateDirectories: true)
        try writeCAF(silent.appendingPathComponent("original.caf"), amplitude: 0)
        let silence = try await AudioPreparation.prepare(folder: silent)
        try expect(!silence.hasSignal, "silence must be detected before transcription")
        print("PASS: silent input detection")

        let compressed = root.appendingPathComponent("compressed")
        try FileManager.default.createDirectory(at: compressed, withIntermediateDirectories: true)
        let input = AVURLAsset(url: mix.appendingPathComponent("system.caf"))
        guard let exporter = AVAssetExportSession(asset: input, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProcessingError.message("Could not create the AAC test fixture.")
        }
        try await exporter.export(to: compressed.appendingPathComponent("original.m4a"), as: .m4a)
        let decoded = try await AudioPreparation.prepare(folder: compressed)
        try expect(decoded.frames > 15500 && decoded.frames < 16500, "compressed imports must preserve duration")
        try expect(decoded.hasSignal, "AAC imports must contain decoded audio")
        print("PASS: native AAC/M4A import without FFmpeg")

        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("{\"tracks\":[]}".utf8).write(to: empty.appendingPathComponent("capture.json"))
        var rejected = false
        do { _ = try await AudioPreparation.prepare(folder: empty) } catch { rejected = true }
        try expect(rejected, "missing tracks must fail with an actionable error")
        print("PASS: missing capture tracks rejected")
    }
}
