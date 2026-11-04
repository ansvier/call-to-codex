import Foundation
import AVFoundation

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw NSError(domain: "TranscriptionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func fixture(_ url: URL, speech: AVAudioPCMBuffer?, noise: Bool) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
    let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var seed: UInt64 = 42
    func background(_ seconds: Int) throws {
        var remaining = seconds * 16000
        while remaining > 0 {
            let count = min(4096, remaining)
            block.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1
                block.floatChannelData![0][index] = noise ? Float(Int((seed >> 32) & 65535) - 32768) / 32768 * 0.002 : 0
            }
            try file.write(from: block); remaining -= count
        }
    }
    if let speech {
        try background(8); try file.write(from: speech)
        try background(35); try file.write(from: speech); try background(10)
    } else { try background(15) }
}

private func process(_ folder: URL, resources: URL) throws -> Int32 {
    let metadata: [String: Any] = ["title": "Speech detection regression", "status": "recorded"]
    try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("session.json"))
    let logURL = folder.appendingPathComponent("test.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
    let task = Process(); task.executableURL = resources.appendingPathComponent("CallToCodexProcessor")
    task.arguments = ["--session", folder.path, "--resources", resources.path, "--local-only"]
    task.standardOutput = log; task.standardError = log
    try task.run(); task.waitUntilExit()
    return task.terminationStatus
}

private func segments(_ folder: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: folder.appendingPathComponent("recognition.json"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["transcription"] as? [[String: Any]] ?? []
}

@main struct TranscriptionTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: TranscriptionTests RESOURCES JFK_WAV") }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]), commonFormat: .pcmFormatFloat32, interleaved: false)
        try check(source.processingFormat.sampleRate == 16000 && source.processingFormat.channelCount == 1, "Expected the upstream 16 kHz mono JFK fixture")
        let speech = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: speech)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("call-to-codex-speech-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let padded = root.appendingPathComponent("padded")
        try FileManager.default.createDirectory(at: padded, withIntermediateDirectories: true)
        try fixture(padded.appendingPathComponent("original.wav"), speech: speech, noise: false)
        try check(try process(padded, resources: resources) == 0, "Speech processing failed")
        let recognized = try segments(padded)
        let text = recognized.compactMap { $0["text"] as? String }.joined().lowercased()
        try check(text.contains("country"), "Speech content must survive detection")
        let markdown = try String(contentsOf: padded.appendingPathComponent("transcript.md"), encoding: .utf8)
        let marker = try NSRegularExpression(pattern: #"\*\*\[(\d{2}):(\d{2}):(\d{2})\]\*\*"#)
        let starts = marker.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).map { match -> Double in
            let values = (1...3).map { Int((markdown as NSString).substring(with: match.range(at: $0)))! }
            return Double(values[0] * 3600 + values[1] * 60 + values[2]) * 1000
        }
        let secondStart = (8 + Double(speech.frameLength) / 16000 + 35) * 1000
        try check(starts.contains { $0 >= 7000 && $0 <= 10000 }, "Leading silence must remain in original timestamps")
        try check(starts.contains { $0 >= secondStart - 1000 }, "Speech after the long pause must retain its original timestamp: starts=\(starts), second=\(secondStart)")
        print("PASS: speech retained across a 35-second pause; original timestamps preserved")

        let quiet = root.appendingPathComponent("quiet")
        try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
        try fixture(quiet.appendingPathComponent("original.wav"), speech: nil, noise: true)
        try check(try process(quiet, resources: resources) != 0, "Noise-only input must not become a successful transcript")
        try check(try segments(quiet).isEmpty, "Quiet background noise must not produce invented words")
        try check(!FileManager.default.fileExists(atPath: quiet.appendingPathComponent("transcript.md").path), "Do not save a transcript when no speech is detected")
        print("PASS: quiet background noise produces no transcript")
    }
}
