import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

enum MicrophoneHardware {
    static func device(for uid: String) -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { return nil }
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        for device in devices {
            var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>? = nil
            var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &key, 0, nil, &bytes, &value) == noErr,
               let value, value.takeRetainedValue() as String == uid { return device }
        }
        return nil
    }

    static func isMuted(uid: String) -> Bool {
        guard let device = device(for: uid) else { return false }
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr && value != 0
    }

    static func unmute(uid: String) throws {
        guard let device = device(for: uid) else { throw AppError.message("The selected microphone was not found.") }
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        let status = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw AppError.message("Could not unmute the microphone in macOS (\(status)).") }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

func captureErrorDescription(_ error: Error) -> String {
    let failure = error as NSError
    if failure.domain == SCStreamErrorDomain {
        if failure.code == SCStreamError.Code.userDeclined.rawValue {
            return "System audio access was declined. Allow CallToCodex in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
        }
        return "System audio capture failed (\(failure.code)). Check Audio Access and try again."
    }
    return error.localizedDescription
}

// Sample data is confined to queue; session lifecycle to sessionQueue; the shared clock is locked.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "local.answer.microphone-session")
    private let clockLock = NSLock()
    private var microphoneClock: CMClock?
    private let queue = DispatchQueue(label: "local.answer.capture")
    private var files: [SCStreamOutputType: AVAudioFile] = [:]
    private var starts: [SCStreamOutputType: Double] = [:]
    private var folder: URL?
    private var writeError: Error?
    var onFailure: ((Error) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    private var systemLevel: Float = 0
    private var micLevel: Float = 0
    private var lastLevelTime = Date.distantPast
    private var maxMicPeak: Float = 0
    private var maxSystemPeak: Float = 0
    private var microphoneName = ""
    private var microphoneFrames = 0
    var microphoneCheck: [String: Any] { queue.sync { ["peak": maxMicPeak, "frames": microphoneFrames, "device": microphoneName] } }

    private func saveManifest() throws {
        guard let folder else { return }
        let tracks = starts.map { type, start in
            ["file": type == .audio ? "system.caf" : "microphone.caf", "start": start] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["tracks": tracks, "microphone": microphoneName,
            "microphone_peak": maxMicPeak, "system_peak": maxSystemPeak], options: .prettyPrinted)
        try data.write(to: folder.appendingPathComponent("capture.json"), options: .atomic)
    }

    func start(in folder: URL, microphoneID: String) async throws {
        self.folder = folder
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppError.message("No active display is available for system audio capture.") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Keep the selected microphone independent of system audio so microphone-only
        // diagnostics and recordings use the same capture path.
        config.captureMicrophone = false
        config.sampleRate = 48000
        config.channelCount = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
            try await startMicrophone(deviceID: microphoneID)
        } catch {
            await stopMicrophone()
            try? await stream.stopCapture()
            self.stream = nil
            throw error
        }
    }

    func testMicrophone(deviceID: String) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.") }
        try await startMicrophone(deviceID: deviceID)
    }

    private func startMicrophone(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
                    guard let device = devices.first(where: { $0.uniqueID == deviceID }) else {
                        throw AppError.message("The selected microphone is unavailable. Refresh the list and choose a connected input.")
                    }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsNonInterleaved: false]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        throw AppError.message("Could not connect the selected microphone.")
                    }
                    session.beginConfiguration()
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                    self.queue.async { self.microphoneName = device.localizedName }
                    self.microphoneSession = session
                    session.startRunning()
                    self.clockLock.withLock { self.microphoneClock = session.synchronizationClock }
                    guard session.isRunning else { throw AppError.message("The microphone could not start. Check macOS permission and the device connection.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func stopMicrophone() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.microphoneSession?.stopRunning()
                self.microphoneSession = nil
                self.clockLock.withLock { self.microphoneClock = nil }
                continuation.resume()
            }
        }
    }

    func stop() async throws {
        await stopMicrophone()
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        try queue.sync {
            files.removeAll() // AVAudioFile finalizes headers here.
            try saveManifest()
            if let error = writeError { throw error }
        }
        if let error = stopError { throw error }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        receive(sampleBuffer, type: .audio, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime: CMTime
        if let clock = clockLock.withLock({ microphoneClock }) {
            hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        } else { hostTime = CMClockGetTime(CMClockGetHostTimeClock()) }
        receive(sampleBuffer, type: .microphone, timestamp: hostTime)
    }

    private func receive(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType, timestamp: CMTime) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), writeError == nil,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        do {
            if type == .microphone { microphoneFrames += frames }
            if let folder, files[type] == nil {
                let filename = type == .audio ? "system.caf" : "microphone.caf"
                files[type] = try AVAudioFile(forWriting: folder.appendingPathComponent(filename), settings: format.settings,
                                              commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                starts[type] = timestamp.seconds
                try saveManifest()
            }
            try files[type]?.write(from: buffer)
            if let channels = buffer.floatChannelData {
                var peak: Float = 0
                let channelCount = format.isInterleaved ? 1 : Int(format.channelCount)
                let sampleCount = format.isInterleaved ? frames * Int(format.channelCount) : frames
                for channel in 0..<channelCount {
                    for index in stride(from: 0, to: sampleCount, by: 16) { peak = max(peak, abs(channels[channel][index])) }
                }
                if type == .audio { systemLevel = peak; maxSystemPeak = max(maxSystemPeak, peak) }
                else { micLevel = peak; maxMicPeak = max(maxMicPeak, peak) }
                if Date().timeIntervalSince(lastLevelTime) > 0.15 {
                    lastLevelTime = Date()
                    onLevel?(micLevel, systemLevel)
                }
            }
        } catch {
            writeError = error
            onFailure?(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error) }
}

struct SavedCall: Identifiable {
    let id: URL
    let title: String
    let status: String
    let threadID: String?
    let error: String?
}

struct AudioInput: Identifiable { let id: String; let name: String }

@MainActor final class AppModel: ObservableObject {
    @Published var recording = false
    @Published var busy = false
    @Published var title = ""
    @Published var status = "Ready to record"
    @Published var errorMessage: String?
    @Published var elapsed = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var calls: [SavedCall] = []
    @Published var inputs: [AudioInput] = []
    @Published var microphoneID = "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID"); refreshMicrophoneState() }
    }
    @Published var systemMicrophoneMuted = false
    @Published var testingMicrophone = false
    @Published var removedCallTitle: String?
    let isDemoMode = ProcessInfo.processInfo.environment["CALLTOCODEX_DEMO"] == "1"
    private var trashedCall: (original: URL, trashed: URL)?
    private var testPeak: Float = 0
    private var recorder: Recorder?
    private var folder: URL?
    private var process: Process?
    private var timer: Timer?
    private var began: Date?
    private var assertion: NSObjectProtocol?
    private var outputBuffer = Data()
    let root: URL

    init() {
        if let previewRoot = ProcessInfo.processInfo.environment["CALLTOCODEX_RECORDINGS_ROOT"] {
            root = URL(fileURLWithPath: previewRoot, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CallToCodex/Recordings", isDirectory: true)
        }
        refresh(); refreshInputs()
    }
    var canQuit: Bool { !recording && !busy }

    func checkSystemAudioAccess() {
        guard !busy && !recording else { return }
        busy = true; errorMessage = nil; status = "Checking system audio access…"
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                status = "System audio access confirmed"
            } catch {
                let failure = error as NSError
                if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
                    status = "macOS has not granted access to this app session"
                    errorMessage = "After allowing Screen & System Audio Recording in System Settings, quit the app completely and reopen it. If access is already on after an update, re-grant it to the current build."
                } else {
                    status = "Could not check system audio access"
                    errorMessage = captureErrorDescription(error)
                }
            }
            busy = false
        }
    }

    func refreshMicrophoneState() { systemMicrophoneMuted = MicrophoneHardware.isMuted(uid: microphoneID) }

    func enableMicrophone() {
        do {
            try MicrophoneHardware.unmute(uid: microphoneID)
            refreshMicrophoneState()
            status = "Microphone unmuted — test your voice"
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshInputs() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        inputs = devices.enumerated().map { index, device in
            AudioInput(id: device.uniqueID, name: isDemoMode ? (index == 0 ? "Built-in Microphone" : "External Microphone") : device.localizedName)
        }
        let preferred = microphoneID.isEmpty ? UserDefaults.standard.string(forKey: "microphoneID") : microphoneID
        if let preferred, devices.contains(where: { $0.uniqueID == preferred }) { microphoneID = preferred }
        else { microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? devices.first?.uniqueID ?? "" }
    }

    func checkMicrophone() {
        guard !busy && !recording else { return }
        refreshMicrophoneState()
        guard !systemMicrophoneMuted else { status = "Microphone is muted in macOS"; return }
        busy = true; testingMicrophone = true; testPeak = 0; micLevel = 0; errorMessage = nil
        status = "Mic check · say a few words"
        Task {
            let capture = Recorder(); recorder = capture
            capture.onLevel = { [weak self] mic, _ in Task { @MainActor in
                guard let self else { return }; self.micLevel = mic; self.testPeak = max(self.testPeak, mic)
            } }
            do {
                try await capture.testMicrophone(deviceID: microphoneID)
                try await Task.sleep(for: .seconds(8))
                try await capture.stop()
                let check = capture.microphoneCheck
                testPeak = (check["peak"] as? Float) ?? testPeak
                try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: check, options: .prettyPrinted) {
                    try? data.write(to: root.deletingLastPathComponent().appendingPathComponent("last-microphone-check.json"), options: .atomic)
                }
                if testPeak > 0.003 { status = "Microphone is working — ready to record" }
                else {
                    status = "No microphone signal detected"
                    errorMessage = "Choose another input or check the microphone level in System Settings → Sound → Input."
                }
            } catch {
                try? await capture.stop(); status = "Could not test the microphone"; errorMessage = error.localizedDescription
            }
            recorder = nil; testingMicrophone = false; busy = false
        }
    }

    func refresh() {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        calls = directories.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = meta["title"] as? String else { return nil }
            return SavedCall(id: dir, title: title, status: meta["status"] as? String ?? "recorded",
                             threadID: meta["thread_id"] as? String, error: meta["error"] as? String)
        }
    }

    func newFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let now = Date()
        let dir = root.appendingPathComponent(formatter.string(from: now) + "_" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "d MMMM, HH:mm"
        let callTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        let meta = ["title": callTitle.isEmpty ? "Call · " + display.string(from: now) : callTitle,
                    "created_at": iso.string(from: now), "status": "recording"]
        try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
        return dir
    }

    func mark(_ dir: URL, status: String, error: String? = nil) {
        let path = dir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: path), var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        meta["status"] = status
        meta["error"] = error
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) { try? data.write(to: path, options: .atomic) }
    }

    func startRecording() {
        guard !busy && !recording else { return }
        guard !isDemoMode else { status = "Demo preview — open CallToCodex to record"; return }
        refreshMicrophoneState()
        guard !systemMicrophoneMuted else { status = "Microphone is muted in macOS"; return }
        busy = true; errorMessage = nil; status = "Connecting microphone and system audio…"
        Task {
            do {
                let dir = try newFolder(); folder = dir
                let capture = Recorder()
                capture.onLevel = { [weak self] mic, system in Task { @MainActor in self?.micLevel = mic; self?.systemLevel = system } }
                capture.onFailure = { [weak self] error in Task { @MainActor in
                    guard let self else { return }
                    self.errorMessage = "Recording interrupted: \(captureErrorDescription(error)). Captured audio is available in the call folder."
                    if self.recording { self.stopRecording(processAfter: false) }
                } }
                recorder = capture
                try await capture.start(in: dir, microphoneID: microphoneID)
                recording = true; busy = false; elapsed = 0; began = Date(); status = "Recording"
                assertion = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a call")
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in
                    guard let self, let began = self.began else { return }; self.elapsed = Int(Date().timeIntervalSince(began))
                } }
                refresh()
            } catch {
                recorder = nil; busy = false; status = "Could not start recording"
                errorMessage = captureErrorDescription(error)
                if let folder { mark(folder, status: "error", error: captureErrorDescription(error)) }
                refresh()
            }
        }
    }

    func stopRecording(processAfter: Bool = true) {
        guard recording, let recorder, let folder else { return }
        recording = false; busy = true; timer?.invalidate(); status = "Saving recording…"
        if let assertion { ProcessInfo.processInfo.endActivity(assertion); self.assertion = nil }
        Task {
            do {
                try await recorder.stop(); self.recorder = nil
                mark(folder, status: "recorded")
                if processAfter { processCall(folder) } else { busy = false; status = "Recording saved"; refresh() }
            } catch {
                self.recorder = nil; busy = false; status = "Recording partially saved"
                errorMessage = error.localizedDescription; mark(folder, status: "error", error: error.localizedDescription); refresh()
            }
        }
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Choose a call recording"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let dir = try newFolder()
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent("original." + source.pathExtension))
            mark(dir, status: "recorded"); processCall(dir)
        } catch { errorMessage = error.localizedDescription }
    }

    func processCall(_ dir: URL) {
        guard process == nil else { return }
        busy = true; errorMessage = nil; status = "Preparing recording…"; folder = dir
        let task = Process()
        guard let resources = Bundle.main.resourceURL else { busy = false; errorMessage = "The app resources are missing. Reinstall CallToCodex."; return }
        let processor = resources.appendingPathComponent("CallToCodexProcessor")
        guard FileManager.default.isExecutableFile(atPath: processor.path) else { busy = false; errorMessage = "The audio processor is missing. Reinstall CallToCodex."; return }
        task.executableURL = processor
        task.arguments = ["--session", dir.path, "--resources", resources.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        task.environment = env
        let pipe = Pipe(); task.standardOutput = pipe
        let log = dir.appendingPathComponent("pipeline.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        task.standardError = try? FileHandle(forWritingTo: log)
        outputBuffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data) }
        }
        task.terminationHandler = { [weak self] p in Task { @MainActor in
            guard let self else { return }
            self.process = nil; self.busy = false; self.refresh()
            if p.terminationStatus != 0 {
                self.status = "Processing can be retried"
                if self.errorMessage == nil { self.errorMessage = "Processing stopped. Your recording is saved; see the call folder for details." }
            } else { self.status = "Done — summary is in Codex" }
        } }
        do { process = task; try task.run() } catch { process = nil; busy = false; errorMessage = error.localizedDescription }
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer[..<newline]; outputBuffer.removeSubrange(...newline)
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch event["stage"] as? String {
            case "preparing": status = "Preparing audio…"
            case "transcribing": status = "Transcribing locally on your Mac…"
            case "summarizing": status = "Codex is preparing your TL;DR…"
            case "chat": status = "New chat created · preparing summary…"
            case "done": status = "Done — summary is in Codex"
            case "error": errorMessage = event["message"] as? String
            default: break
            }
        }
    }

    func openChat(_ call: SavedCall) {
        if isDemoMode { status = "Demo data — no Codex chat is attached"; return }
        if let id = call.threadID, let url = URL(string: "codex://threads/" + id) { NSWorkspace.shared.open(url) }
    }
    func openFolder(_ call: SavedCall) { NSWorkspace.shared.open(call.id) }
    func openTranscript(_ call: SavedCall) { NSWorkspace.shared.open(call.id.appendingPathComponent("transcript.md")) }

    func deleteCall(_ call: SavedCall) {
        guard canQuit else { return }
        let location = call.id.standardizedFileURL
        guard location.deletingLastPathComponent().path == root.standardizedFileURL.path,
              location.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path,
              calls.contains(where: { $0.id == call.id }) else {
            errorMessage = "Could not locate this call folder safely."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove “\(call.title)” from history?"
        alert.informativeText = "The recording, transcript and summary will move to Trash and can be restored. The Codex chat will remain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var destination: NSURL?
            try FileManager.default.trashItem(at: location, resultingItemURL: &destination)
            if let destination {
                trashedCall = (location, destination as URL)
                removedCallTitle = call.title
            }
            errorMessage = nil
            refresh()
        } catch { errorMessage = "Could not move the call to Trash: \(error.localizedDescription)" }
    }

    func undoDelete() {
        guard canQuit, let entry = trashedCall else { return }
        do {
            guard !FileManager.default.fileExists(atPath: entry.original.path) else {
                throw AppError.message("A folder with this name already exists. The recording is still in Trash.")
            }
            try FileManager.default.moveItem(at: entry.trashed, to: entry.original)
            trashedCall = nil; removedCallTitle = nil; errorMessage = nil
            refresh()
        } catch { errorMessage = "Could not restore the call: \(error.localizedDescription)" }
    }
}

enum Amp {
    static let body = Color(red: 0.16, green: 0.16, blue: 0.23)
    static let panel = Color(red: 0.22, green: 0.22, blue: 0.30)
    static let edge = Color(red: 0.49, green: 0.48, blue: 0.57)
    static let ink = Color(red: 0.025, green: 0.045, blue: 0.025)
    static let green = Color(red: 0.61, green: 0.94, blue: 0.28)
    static let dimGreen = Color(red: 0.16, green: 0.23, blue: 0.10)
    static let silver = Color(red: 0.80, green: 0.80, blue: 0.84)
    static let muted = Color(red: 0.64, green: 0.64, blue: 0.71)
    static let amber = Color(red: 1, green: 0.76, blue: 0.24)
    static let red = Color(red: 1, green: 0.35, blue: 0.30)
    static func font(_ size: CGFloat = 11) -> Font { .custom("Menlo", size: size) }
}

struct AmpBevel: ViewModifier {
    var inset = false
    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height))
                    path.addLine(to: .zero)
                    path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                }.stroke(inset ? Color.black.opacity(0.9) : Amp.edge, lineWidth: 2)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                }.stroke(inset ? Amp.edge.opacity(0.7) : Color.black.opacity(0.85), lineWidth: 2)
            }.allowsHitTesting(false)
        }
    }
}

struct AmpButton: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Amp.font(10).weight(.bold))
            .foregroundStyle(primary ? Color.black : Color(red: 0.12, green: 0.12, blue: 0.18))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 27)
            .background(LinearGradient(colors: primary ? [Amp.green, Color(red: 0.36, green: 0.65, blue: 0.16)] :
                [Color(red: 0.80, green: 0.80, blue: 0.85), Color(red: 0.49, green: 0.49, blue: 0.59)],
                startPoint: .top, endPoint: .bottom))
            .modifier(AmpBevel(inset: configuration.isPressed))
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(enabled ? 1 : 0.4)
    }
}

struct AmpHeader: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(spacing: 9) {
            grooves
            Text(title).font(Amp.font(10).weight(.bold)).tracking(1.4).foregroundStyle(Amp.silver)
                .fixedSize(horizontal: true, vertical: false)
            grooves
            if !detail.isEmpty { Text(detail).font(Amp.font(9)).foregroundStyle(Amp.muted) }
        }.padding(.horizontal, 8).frame(height: 23)
            .background(LinearGradient(colors: [Amp.edge.opacity(0.4), Amp.body], startPoint: .top, endPoint: .bottom))
    }
    var grooves: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Amp.edge.opacity(0.7)).frame(height: 1) }
        }.frame(maxWidth: .infinity)
    }
}

struct DigitalClock: View {
    let seconds: Int
    private let digits = ["1111110", "0110000", "1101101", "1111001", "0110011", "1011011", "1011111", "1110000", "1111111", "1111011"]
    var body: some View {
        Canvas { context, size in
            let value = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let scale = min(size.width / 189, size.height / 38)
            var cursor: CGFloat = 0
            for character in value {
                if character == ":" {
                    for y in [CGFloat(12), CGFloat(25)] {
                        context.fill(Path(CGRect(x: (cursor + 3) * scale, y: y * scale, width: 3 * scale, height: 3 * scale)), with: .color(Amp.green))
                    }
                    cursor += 10
                } else if let number = character.wholeNumberValue {
                    let rects = [CGRect(x: 3, y: 0, width: 17, height: 3), CGRect(x: 20, y: 3, width: 3, height: 14),
                        CGRect(x: 20, y: 21, width: 3, height: 14), CGRect(x: 3, y: 35, width: 17, height: 3),
                        CGRect(x: 0, y: 21, width: 3, height: 14), CGRect(x: 0, y: 3, width: 3, height: 14),
                        CGRect(x: 3, y: 18, width: 17, height: 3)]
                    for (index, state) in digits[number].enumerated() {
                        let rect = rects[index]
                        let scaled = CGRect(x: (cursor + rect.minX) * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                        context.fill(Path(scaled), with: .color(state == "1" ? Amp.green : Amp.dimGreen.opacity(0.5)))
                    }
                    cursor += 28
                }
            }
        }.frame(width: 284, height: 57)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording time")
            .accessibilityValue(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
    }
}

struct AmpMeter: View {
    let name: String
    let value: Float
    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(Amp.font(9)).foregroundStyle(Amp.muted).frame(width: 30, alignment: .leading)
            GeometryReader { geometry in
                let count = 18
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { index in
                        Rectangle().fill(index < Int(min(1, sqrt(max(0, value)) * 2.5) * Float(count)) ?
                            (index > 15 ? Amp.red : index > 12 ? Amp.amber : Amp.green) : Amp.dimGreen.opacity(0.5))
                    }
                }.frame(width: geometry.size.width, height: 8)
            }.frame(height: 8)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(name == "MIC" ? "Microphone level" : "System audio level")
            .accessibilityValue(String(format: "%.0f percent", min(1, value) * 100))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: URL?
    private var selected: SavedCall? { model.calls.first(where: { $0.id == selectedID }) ?? model.calls.first }
    private var active: Bool { model.recording || model.testingMicrophone }

    var body: some View {
        VStack(spacing: 8) {
            player
            inputPanel
            if model.systemMicrophoneMuted { mutedNotice }
            if let message = model.errorMessage { errorNotice(message) }
            playlist
            utilityPanel
            HStack {
                Rectangle().fill(model.recording ? Amp.red : Amp.green).frame(width: 5, height: 5)
                Text(model.recording ? "REC" : model.busy ? "BUSY" : "READY").font(Amp.font(9)).foregroundStyle(Amp.green)
                Spacer()
                Text("AUDIO ON YOUR MAC · TEXT TO CODEX").font(Amp.font(9)).foregroundStyle(Amp.muted)
                Text("v0.3").font(Amp.font(9)).foregroundStyle(Amp.edge)
                if model.isDemoMode { Text("DEMO").font(Amp.font(9)).foregroundStyle(Amp.amber) }
            }.padding(.horizontal, 3).frame(height: 15)
        }
        .padding(9).frame(width: 600, height: 738)
        .background(Amp.body).modifier(AmpBevel())
        .preferredColorScheme(.dark)
    }

    private var player: some View {
        VStack(spacing: 0) {
            AmpHeader(title: "CALL → CODEX", detail: "RECORDER")
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Circle().fill(model.recording ? Amp.red : Amp.green).frame(width: 6, height: 6)
                        Text(model.recording ? "RECORDING" : model.busy ? "PROCESSING" : "STANDBY")
                            .font(Amp.font(9)).tracking(1.2).foregroundStyle(model.recording ? Amp.red : Amp.green)
                    }
                    DigitalClock(seconds: model.elapsed)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("MIC + SYSTEM AUDIO").font(Amp.font(9)).foregroundStyle(Amp.green)
                    AmpMeter(name: "MIC", value: active ? model.micLevel : 0)
                    AmpMeter(name: "CALL", value: model.recording ? model.systemLevel : 0)
                    Text("LOCAL RECORDING").font(Amp.font(9)).foregroundStyle(Amp.muted)
                }.frame(maxWidth: .infinity).padding(.top, 2)
            }.padding(13).background(Amp.ink).modifier(AmpBevel(inset: true)).padding(.horizontal, 8)
            HStack(spacing: 6) {
                Text("›").foregroundStyle(Amp.green)
                Text(model.status).font(Amp.font(10)).foregroundStyle(Amp.green).lineLimit(1).help(model.status)
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.mini).tint(Amp.green).scaleEffect(0.7) }
            }.padding(.horizontal, 10).frame(height: 27)
            HStack(spacing: 6) {
                Button { model.startRecording() } label: {
                    HStack(spacing: 6) { Circle().fill(Color(red: 0.55, green: 0.05, blue: 0.04)).frame(width: 9, height: 9); Text("RECORD") }
                }.buttonStyle(AmpButton(primary: true)).disabled(model.busy || model.recording)
                    .accessibilityLabel("Record a call")
                Button { model.stopRecording() } label: { Label("STOP", systemImage: "stop.fill") }
                    .buttonStyle(AmpButton()).disabled(!model.recording || model.busy)
                    .help("Stop and automatically process the recording")
                Spacer(minLength: 4)
                Button { model.importAudio() } label: { Label("OPEN", systemImage: "eject.fill") }
                    .buttonStyle(AmpButton()).disabled(model.busy || model.recording).help("Process an existing recording")
                Button { openRecordings() } label: { Image(systemName: "folder.fill") }
                    .buttonStyle(AmpButton()).help("All recordings").accessibilityLabel("All recordings")
            }.padding(.horizontal, 8).padding(.bottom, 9)
        }.background(Amp.panel).modifier(AmpBevel())
    }

    private var inputPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("TITLE").font(Amp.font(9)).foregroundStyle(Amp.muted).frame(width: 65, alignment: .leading)
                TextField("Untitled call", text: $model.title)
                    .font(Amp.font(11)).textFieldStyle(.plain).foregroundStyle(Amp.green)
                    .padding(.horizontal, 7).frame(height: 25).background(Amp.ink).modifier(AmpBevel(inset: true))
                    .disabled(model.recording || model.busy).accessibilityLabel("Call title")
            }
            HStack(spacing: 8) {
                Text("MICROPHONE").font(Amp.font(9)).foregroundStyle(Amp.muted).frame(width: 65, alignment: .leading)
                Picker("Microphone", selection: $model.microphoneID) {
                    ForEach(model.inputs) { input in Text(input.name).tag(input.id) }
                    if model.inputs.isEmpty { Text("Not found").tag("") }
                }.labelsHidden().font(Amp.font(10)).frame(maxWidth: .infinity, alignment: .leading).disabled(model.busy || model.recording)
                Button { model.refreshInputs() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(AmpButton()).disabled(model.busy || model.recording)
                    .accessibilityLabel("Refresh microphone list")
            }
        }.padding(10).background(Amp.panel).modifier(AmpBevel())
    }

    private var playlist: some View {
        VStack(spacing: 0) {
            AmpHeader(title: "CALL PLAYLIST", detail: String(format: "%03d", model.calls.count))
            ScrollView {
                LazyVStack(spacing: 1) {
                    if model.calls.isEmpty {
                        VStack(spacing: 8) {
                            Text("PLAYLIST EMPTY").font(Amp.font(12)).foregroundStyle(Amp.green)
                            Text("Press RECORD to start a call").font(Amp.font(10)).foregroundStyle(Amp.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(Array(model.calls.enumerated()), id: \.element.id) { index, call in
                        historyRow(index, call)
                    }
                }.padding(4)
            }.background(Amp.ink).modifier(AmpBevel(inset: true)).padding(.horizontal, 7)
            if let selected {
                HStack(spacing: 5) {
                    Button("CHAT") { model.openChat(selected) }.disabled(selected.threadID == nil)
                    Button("TRANSCRIPT") { model.openTranscript(selected) }
                        .disabled(!FileManager.default.fileExists(atPath: selected.id.appendingPathComponent("transcript.md").path))
                    Button("FOLDER") { model.openFolder(selected) }
                    Spacer(minLength: 0)
                    if selected.status != "done" {
                        Button { model.processCall(selected.id) } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(model.busy || model.recording).help("Retry the selected call")
                            .accessibilityLabel("Retry processing")
                    }
                    Button { model.deleteCall(selected) } label: { Image(systemName: "trash") }
                        .disabled(model.busy || model.recording).help("Remove the selected call from history")
                        .accessibilityLabel("Remove selected call")
                }.buttonStyle(AmpButton()).padding(8)
            }
            if let title = model.removedCallTitle {
                HStack {
                    Text("IN TRASH: " + title).font(Amp.font(9)).foregroundStyle(Amp.muted).lineLimit(1)
                    Spacer()
                    Button("UNDO") { model.undoDelete() }.buttonStyle(AmpButton()).disabled(model.busy || model.recording)
                        .accessibilityLabel("Undo deletion")
                }.padding(.horizontal, 8).padding(.bottom, 7)
            }
        }.frame(maxHeight: .infinity).background(Amp.panel).modifier(AmpBevel())
    }

    private func historyRow(_ index: Int, _ call: SavedCall) -> some View {
        let highlighted = selected?.id == call.id
        return HStack(spacing: 0) {
            Button { selectedID = call.id } label: {
                HStack(spacing: 8) {
                    Text(String(format: "%02d.", index + 1)).font(Amp.font(10)).foregroundStyle(highlighted ? Amp.silver : Amp.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.title).font(Amp.font(11)).foregroundStyle(highlighted ? .white : Amp.green).lineLimit(1)
                        Text(historyStatus(call)).font(Amp.font(9)).foregroundStyle(call.status == "error" ? Amp.amber : Amp.muted).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Text(shortDate(call)).font(Amp.font(9)).foregroundStyle(Amp.muted)
                }.padding(.horizontal, 7).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(call.title)
            Button { model.deleteCall(call) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 25, height: 34) }
                .buttonStyle(.plain).foregroundStyle(Amp.muted).disabled(model.busy || model.recording)
                .help("Move to Trash: " + call.title).accessibilityLabel("Remove “" + call.title + "”")
        }.background(highlighted ? Color(red: 0.15, green: 0.19, blue: 0.30) : Color.clear)
    }

    private var utilityPanel: some View {
        HStack(spacing: 6) {
            Text("CHECK").font(Amp.font(9)).foregroundStyle(Amp.muted).padding(.trailing, 3)
            Button("MIC CHECK · 8 SEC") { model.checkMicrophone() }
                .disabled(model.busy || model.recording || model.microphoneID.isEmpty).help("Test the microphone without saving audio")
            Button("AUDIO ACCESS") { model.checkSystemAudioAccess() }.disabled(model.busy || model.recording)
                .help("Check system audio permission without recording")
            Spacer(minLength: 0)
            Text("◢◢◢").font(Amp.font(12)).foregroundStyle(Amp.edge)
        }.buttonStyle(AmpButton()).padding(8).background(Amp.panel).modifier(AmpBevel())
    }

    private var mutedNotice: some View {
        HStack(spacing: 10) {
            Text("MICROPHONE MUTED IN macOS").font(Amp.font(10)).foregroundStyle(Amp.amber)
            Spacer(minLength: 0)
            Button("UNMUTE") { model.enableMicrophone() }.buttonStyle(AmpButton()).disabled(model.busy || model.recording)
                .help("This also unmutes the microphone for other apps that already have access")
        }.padding(8).background(Amp.ink).modifier(AmpBevel(inset: true))
    }

    private func errorNotice(_ message: String) -> some View {
        ScrollView {
            Text(message).font(Amp.font(10)).foregroundStyle(Amp.amber).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 64).padding(8).background(Amp.ink).modifier(AmpBevel(inset: true))
    }

    private func historyStatus(_ call: SavedCall) -> String {
        switch call.status {
        case "done": return "READY · TL;DR + MD"
        case "error": return call.error ?? "PROCESSING ERROR"
        case "recording": return "RECORD"
        case "transcribed": return "TRANSCRIPT READY"
        default: return "RECORDING SAVED"
        }
    }
    private func shortDate(_ call: SavedCall) -> String {
        let name = call.id.lastPathComponent
        guard name.count >= 16 else { return "" }
        return String(name.dropFirst(8).prefix(2)) + "." + String(name.dropFirst(5).prefix(2)) + " " +
            String(name.dropFirst(11).prefix(5)).replacingOccurrences(of: "-", with: ":")
    }
    private func openRecordings() {
        try? FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(model.root)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow!
    var item: NSStatusItem!
    private var screenshotCount = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 738), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "CallToCodex"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.23, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center(); showWindow()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "CallToCodex")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open CallToCodex", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApplication.shared
        item.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        if model.isDemoMode {
            appMenu.addItem(withTitle: "Save Demo Screenshot", action: #selector(exportDemoScreenshot), keyEquivalent: "").target = self
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "Quit CallToCodex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApplication.shared
        let editItem = NSMenuItem(); main.addItem(editItem); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (name, action, key) in [("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        NSApplication.shared.mainMenu = main
        if model.isDemoMode { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.exportDemoScreenshot() } }
    }
    @objc func exportDemoScreenshot() {
        guard model.isDemoMode, let directory = ProcessInfo.processInfo.environment["CALLTOCODEX_SCREENSHOT_DIR"],
              let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = screenshotCount == 0 ? "main-window.png" : screenshotCount == 1 ? "history-trash.png" : "screen-\(screenshotCount).png"
        try? png.write(to: folder.appendingPathComponent(name), options: .atomic)
        screenshotCount += 1
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); model.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.canQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.recording ? "Stop the recording first" : "Wait for processing to finish"
        alert.informativeText = "You can close the window. The app will keep running in the menu bar."
        alert.addButton(withTitle: "Continue")
        alert.runModal(); return .terminateCancel
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
