import Foundation
import AVFoundation
import AudioToolbox
import ScreenCaptureKit
import CoreMedia

/// OS permission dialogs may outlive an interpretation run. Release the caller
/// when it stops, without granting access or depending on the user's response.
@MainActor final class AudioPermissionWaiter {
    private var continuation: CheckedContinuation<Bool, Error>?
    private var cancelled = false

    func wait(request: (@escaping @Sendable (Bool) -> Void) -> Void) async throws -> Bool {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                request { [weak self] allowed in
                    Task { @MainActor [weak self] in self?.complete(allowed) }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        cancelled = true
        let pending = continuation; continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func complete(_ allowed: Bool) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: allowed)
    }
}

/// Stateful sample-rate conversion and PCM framing. Use from one serial queue.
final class PCM16Encoder {
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var pending = Data()
    private var finished = false
    private var inputFrames: UInt64 = 0
    private var outputFrames: UInt64 = 0
    private(set) var level: Float = 0

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw NativeAudioError.message("无法建立音频采样转换器。")
        }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
        converter.primeMethod = .none
    }

    func append(channels: [[Float]]) throws -> [Data] {
        guard !finished, let count = channels.first?.count, count > 0 else { return [] }
        guard channels.allSatisfy({ $0.count == count }), count <= Int(UInt32.max),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let samples = input.floatChannelData?[0] else {
            throw NativeAudioError.message("音频数据格式无效。")
        }
        input.frameLength = AVAudioFrameCount(count)
        inputFrames += UInt64(count)
        var energy: Float = 0
        for frame in 0..<count {
            var mixed: Float = 0
            for channel in channels { mixed += channel[frame].isFinite ? channel[frame] / Float(channels.count) : 0 }
            samples[frame] = max(-1, min(1, mixed))
            energy += samples[frame] * samples[frame]
        }
        level = min(1, sqrt(energy / Float(count)))
        return try convert(input: input, ending: false)
    }

    func finish() throws -> [Data] {
        guard !finished else { return [] }
        finished = true
        var blocks = try convert(input: nil, ending: true)
        if !pending.isEmpty { blocks.append(pending); pending.removeAll() }
        return blocks
    }

    private func convert(input: AVAudioPCMBuffer?, ending: Bool) throws -> [Data] {
        var supplied = false
        var blocks: [Data] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                throw NativeAudioError.message("无法分配音频转换缓冲区。")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input = input, !supplied { supplied = true; inputStatus.pointee = .haveData; return input }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            if let error = error { throw error }
            guard status != .error else { throw NativeAudioError.message("音频采样转换失败。") }
            if let floats = output.floatChannelData?[0] {
                for frame in 0..<Int(output.frameLength) {
                    // AVAudioConverter includes filter padding at EOF; preserve source duration.
                    if ending && outputFrames >= UInt64((Double(inputFrames) * 16000 / inputFormat.sampleRate).rounded(.down)) { break }
                    outputFrames += 1
                    let value = floats[frame].isFinite ? floats[frame] : 0
                    let integer = Int16(max(-32768, min(32767, (Double(value) * 32768).rounded())))
                    let bits = UInt16(bitPattern: integer)
                    pending.append(UInt8(bits & 255)); pending.append(UInt8(bits >> 8))
                    if pending.count == 3200 { blocks.append(pending); pending = Data() }
                }
            }
            if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { break }
        }
        return blocks
    }
}

/// Owns copied buffers until consumed; at most eight callbacks (and 1 MiB each) may be queued.
/// Overflow stops acceptance and reports failure instead of silently dropping speech.
final class AudioCaptureRun: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.voxbridge.capture.convert", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var queued = 0
    private var encoder: PCM16Encoder?
    private var sampleRate: Double = 0
    private let pcm: (Data) -> Void
    private let level: (Float) -> Void
    private let failure: (String) -> Void

    init(pcm: @escaping (Data) -> Void, level: @escaping (Float) -> Void, failure: @escaping (String) -> Void) {
        self.pcm = pcm; self.level = level; self.failure = failure
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard queued < 8, UInt64(buffer.frameLength) * UInt64(buffer.format.channelCount) * 4 <= 1_048_576 else {
            accepting = false; lock.unlock()
            failure("音频处理速度不足，采集已停止。请重新开始。")
            return
        }
        queued += 1
        // Enqueue under the same lock used by finish: draining cannot overtake an accepted callback.
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, channels > 0 else {
            queued -= 1; accepting = false; lock.unlock()
            failure("音频设备未提供浮点 PCM 数据。")
            return
        }
        let copied: [[Float]]
        if buffer.format.isInterleaved {
            copied = (0..<channels).map { channel in (0..<count).map { data[0][$0 * channels + channel] } }
        } else {
            copied = (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: count)) }
        }
        let rate = buffer.format.sampleRate
        queue.async { [self] in
            defer { lock.lock(); queued -= 1; lock.unlock() }
            do {
                if encoder == nil || sampleRate != rate {
                    if let encoder = encoder { for block in try encoder.finish() { pcm(block) } }
                    encoder = try PCM16Encoder(sampleRate: rate); sampleRate = rate
                }
                if let encoder = encoder {
                    for block in try encoder.append(channels: copied) { pcm(block) }
                    level(encoder.level)
                }
            } catch { fail(error.localizedDescription) }
        }
        lock.unlock()
    }

    func fail(_ message: String) {
        lock.lock(); let report = accepting; accepting = false; lock.unlock()
        if report { failure(message) }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            lock.lock(); accepting = false
            queue.async { [self] in
                do { if let encoder = encoder { for block in try encoder.finish() { pcm(block) } } }
                catch { failure(error.localizedDescription) }
                encoder = nil
                continuation.resume()
            }
            lock.unlock()
        }
    }
}

private final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let run: AudioCaptureRun
    init(run: AudioCaptureRun) { self.run = run }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        run.fail("系统音频采集已中断：\(error.localizedDescription)")
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        var required = 0
        var retainedBlock: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &required, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retainedBlock)
        guard status == noErr, required > 0 else { run.fail("无法读取系统音频缓冲区（\(status)）。"); return }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retainedBlock)
        guard status == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { run.fail("系统音频数据格式无效。"); return }
        withExtendedLifetime(retainedBlock) { run.submit(buffer) }
    }
}

enum MicrophoneReconfiguration {
    static func recover(deviceAvailable: Bool, isRunning: Bool, restart: () throws -> Void) throws {
        guard deviceAvailable else {
            throw NativeAudioError.message("所选输入设备已断开，请重新连接或选择输入设备。")
        }
        // Device selection can deliver a late notification after start() succeeds.
        // AVAudioEngine also stops itself for real sample-rate/channel changes.
        if !isRunning { try restart() }
    }
}

/// Main-actor lifecycle; PCM callbacks execute on a bounded background serial queue.
@MainActor final class AudioCapture {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private var generation = UUID()
    private var run: AudioCaptureRun?
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var sink: SystemAudioSink?
    private var systemTap: SystemAudioTap?
    private var stopping: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var permissionWaiter: AudioPermissionWaiter?

    func start(inputUID: String) async throws {
        let token = UUID(); generation = token
        await stopResources()
        guard generation == token else { throw CancellationError() }
        let pcm = onPCM
        let run = AudioCaptureRun(pcm: { pcm?($0) }, level: { [weak self] value in
            DispatchQueue.main.async { [weak self] in guard let self = self, self.generation == token else { return }; self.onLevel?(value) }
        }, failure: { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == token else { return }
                self.onFailure?(message)
                Task { guard self.generation == token else { return }; await self.stop() }
            }
        })
        self.run = run
        do {
            if inputUID == "system-muted" {
                let tap = SystemAudioTap(); systemTap = tap
                try await tap.start(run: run)
            }
            else if inputUID == "system" { try await startSystem(run: run, token: token) }
            else { try await startMicrophone(inputUID: inputUID, run: run, token: token) }
            guard generation == token else { throw CancellationError() }
        } catch {
            if generation == token { await stop() }
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        await stopResources()
    }

    private func stopResources() async {
        permissionWaiter?.cancel(); permissionWaiter = nil
        if let stopping = stopping { await stopping.value; return }
        let oldRun = run; run = nil
        let oldEngine = engine; engine = nil
        let oldStream = stream; stream = nil
        let oldSink = sink; sink = nil
        let oldTap = systemTap; systemTap = nil
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        oldEngine?.inputNode.removeTap(onBus: 0)
        oldEngine?.stop()
        let task = Task {
            if let oldTap { await oldTap.stop() }
            if let oldStream = oldStream { try? await oldStream.stopCapture() }
            if let oldRun = oldRun { await oldRun.finish() }
            withExtendedLifetime(oldSink) {}
            stopping = nil
            onLevel?(0)
        }
        stopping = task
        await task.value
    }

    private func startMicrophone(inputUID: String, run: AudioCaptureRun, token: UUID) async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined:
            let waiter = AudioPermissionWaiter(); permissionWaiter = waiter
            defer { if permissionWaiter === waiter { permissionWaiter = nil } }
            allowed = try await waiter.wait { reply in
                AVCaptureDevice.requestAccess(for: .audio, completionHandler: reply)
            }
        default: allowed = false
        }
        guard generation == token else { throw CancellationError() }
        guard allowed else { throw NativeAudioError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许“同声传译” 访问麦克风。") }
        let uid = inputUID == "default" ? AudioDevices.defaultInputUID() : inputUID
        guard let uid = uid, let selected = try AudioDevices.inputs().first(where: { $0.uid == uid }) else {
            throw NativeAudioError.message("所选输入设备不可用，请连接该设备后重试。")
        }
        let engine = AVAudioEngine()
        try selectMicrophone(selected.id, in: engine)
        try installMicrophoneTap(engine, run: run)
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Never restart/tear down the engine on its internal notification queue.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, let engine = self.engine else { return }
                do {
                    let available = try AudioDevices.inputs().contains { $0.uid == selected.uid }
                    try MicrophoneReconfiguration.recover(deviceAvailable: available, isRunning: engine.isRunning) {
                        engine.inputNode.removeTap(onBus: 0)
                        try self.selectMicrophone(selected.id, in: engine)
                        try self.installMicrophoneTap(engine, run: run)
                        engine.prepare()
                        try engine.start()
                    }
                } catch { run.fail("麦克风恢复失败：\(error.localizedDescription)") }
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func selectMicrophone(_ id: AudioDeviceID, in engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else { throw NativeAudioError.message("无法创建音频输入。") }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr, current == id { return }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size)
        guard status == noErr else { throw NativeAudioError.message("无法打开所选音频设备（\(status)）。") }
    }

    private func installMicrophoneTap(_ engine: AVAudioEngine, run: AudioCaptureRun) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw NativeAudioError.message("所选输入设备没有可用的音频通道。")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in run.submit(buffer) }
    }

    private func startSystem(run: AudioCaptureRun, token: UUID) async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw NativeAudioError.message("无法采集系统音频。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许“同声传译”。\n\(error.localizedDescription)") }
        guard generation == token else { throw CancellationError() }
        guard let display = content.displays.first else { throw NativeAudioError.message("未找到可用于系统音频采集的显示器。") }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let sink = SystemAudioSink(run: run)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "org.voxbridge.capture.system"))
        self.stream = stream; self.sink = sink
        try await stream.startCapture()
        guard generation == token else { try? await stream.stopCapture(); throw CancellationError() }
    }
}
