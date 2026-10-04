import Foundation
import AVFoundation
import AudioToolbox
#if NATIVE_PLAYBACK_TESTING
import Darwin
import CoreAudio

/// Test-only observations. The render snapshot can precede wall time by a
/// device quantum; capturing both timestamps makes that age measurable.
struct NativeSpeechRenderProbe {
    let observedHostTime: UInt64
    let renderHostTime: UInt64?
    let playerFrame: AVAudioFramePosition?
    let playerSampleRate: Double?

    var renderAgeMilliseconds: Double? {
        guard let renderHostTime else { return nil }
        if observedHostTime >= renderHostTime {
            return AVAudioTime.seconds(forHostTime: observedHostTime - renderHostTime) * 1000
        }
        // Some hardware renders ahead of wall time. Preserve that negative
        // age rather than treating a future render snapshot as unavailable.
        return -AVAudioTime.seconds(forHostTime: renderHostTime - observedHostTime) * 1000
    }
}

struct NativeSpeechScheduleProbe {
    let sequence: Int
    let startFrame: AVAudioFramePosition
    let endFrame: AVAudioFramePosition
    let playing: Bool
    let chosen: NativeSpeechRenderProbe
    let submitting: NativeSpeechRenderProbe
    let submittedHostTime: UInt64
    let presentationLatency: Double
}
#endif

struct NativeSpeechChunk: Decodable {
    let seq: Int
    let sentence_id: String
    let revision: Int
    let source_order: Int
    let index: Int
    let count: Int
    let sample_rate: Int
    let pcm: Data
    let duration_ms: Double
    let text: String
    let sentence_text: String?
    let created_at_ms: Double
}

struct NativeSpeechSnapshot: Decodable {
    let epoch: String
    let cursor: Int
    let chunks: [NativeSpeechChunk]
}

/// Accept a snapshot atomically so a malformed later chunk cannot lose earlier audio.
struct NativeSpeechCursor {
    let epoch: String
    private(set) var receivedSequence: Int
    private var lastChunk: NativeSpeechChunk?
    var completeSentence: Bool { lastChunk.map { $0.index + 1 == $0.count } ?? true }

    init(epoch: String, cursor: Int) throws {
        guard !epoch.isEmpty, cursor >= 0 else { throw ServiceError.message("朗读会话信息无效。") }
        self.epoch = epoch; receivedSequence = cursor
    }

    mutating func accept(_ snapshot: NativeSpeechSnapshot) throws -> [NativeSpeechChunk] {
        guard snapshot.epoch == epoch, snapshot.cursor >= receivedSequence,
              snapshot.chunks.count <= 4 else { throw ServiceError.message("朗读会话已变化，请重新开始传译。") }
        var next = self
        var accepted: [NativeSpeechChunk] = []
        for chunk in snapshot.chunks {
            if chunk.seq <= receivedSequence { continue }
            guard chunk.seq == next.receivedSequence + 1, chunk.sample_rate == 24000,
                  !chunk.pcm.isEmpty, chunk.pcm.count % 2 == 0, chunk.pcm.count <= 2_880_000,
                  chunk.duration_ms.isFinite, chunk.created_at_ms.isFinite,
                  abs(chunk.duration_ms - Double(chunk.pcm.count) / 48) <= 1,
                  !chunk.sentence_id.isEmpty, chunk.revision >= 0, chunk.source_order >= 0,
                  chunk.count > 0, chunk.count <= 256, chunk.index >= 0, chunk.index < chunk.count else {
                throw ServiceError.message("朗读音频缺失或格式错误，已停止以避免漏读。")
            }
            if let previous = next.lastChunk {
                if previous.index + 1 < previous.count {
                    guard chunk.sentence_id == previous.sentence_id, chunk.revision == previous.revision,
                          chunk.source_order == previous.source_order, chunk.count == previous.count,
                          chunk.index == previous.index + 1 else {
                        throw ServiceError.message("朗读分段顺序错误。")
                    }
                } else {
                    guard chunk.source_order > previous.source_order, chunk.index == 0 else {
                        throw ServiceError.message("朗读句子重复或顺序错误。")
                    }
                }
            } else if chunk.index != 0 {
                throw ServiceError.message("朗读缺少句首，请重新开始传译。")
            }
            next.receivedSequence = chunk.seq; next.lastChunk = chunk; accepted.append(chunk)
        }
        guard snapshot.cursor == next.receivedSequence else { throw ServiceError.message("朗读连续序号不匹配。") }
        self = next
        return accepted
    }
}

enum NativeSpeechSchedule {
    static func start(previousEnd: AVAudioFramePosition, rendered: AVAudioFramePosition,
                      playing: Bool) -> AVAudioFramePosition {
        if previousEnd > rendered { return previousEnd }
        return rendered + (playing ? 480 : 0)
    }
}

enum NativeSpeechStartupRecovery {
    static func recover(deviceAvailable: Bool, isRunning: Bool, hasScheduledAudio: Bool,
                        attempts: inout Int, restart: () throws -> Void) throws {
        guard deviceAvailable else { throw ServiceError.message("所选朗读输出设备不可用。") }
        guard !isRunning else { return }
        // HAL may stop the engine while negotiating an explicitly selected
        // device's format. Restart only before any PCM has ever been scheduled:
        // rebuilding a live queue could otherwise discard or repeat speech.
        guard !hasScheduledAudio, attempts < 2 else {
            throw ServiceError.message("朗读输出设备配置已变化，请重新开始传译。")
        }
        attempts += 1
        try restart()
    }
}

@MainActor final class NativeSpeechPlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var cursor: NativeSpeechCursor?
    private var generation = UUID()
    private var scheduledEnd: AVAudioFramePosition = 0
    private var completed = Set<Int>()
    private var configurationObserver: NSObjectProtocol?
    private var outputDeviceID: UInt32?
    private var startupRecoveryAttempts = 0
    private struct Scheduled {
        let seq: Int
        let start: AVAudioFramePosition
        let end: AVAudioFramePosition
    }
    private var pending: [Scheduled] = []
    private(set) var playedSequence = 0
    private(set) var scheduledChunks: [[String: Any]] = []
    var onFailure: ((String) -> Void)?
    #if NATIVE_PLAYBACK_TESTING
    var onPCMChunk: ((NativeSpeechChunk) -> Void)?
    var onScheduleProbe: ((NativeSpeechScheduleProbe) -> Void)?
    var onMixerOutput: AVAudioNodeTapBlock?
    var outputDeviceProbe: [String: Any] {
        guard let engine, let id = Self.currentOutputDevice(engine) else { return [:] }
        var rate = Float64(0)
        var frames = UInt32(0)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rateSize = UInt32(MemoryLayout.size(ofValue: rate))
        var frameSize = UInt32(MemoryLayout.size(ofValue: frames))
        let rateStatus = AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate)
        let frameStatus = AudioObjectGetPropertyData(id, &frameAddress, 0, nil, &frameSize, &frames)
        let device = try? AudioDevices.outputs().first { $0.id == id }
        var result: [String: Any] = ["id": id, "uid": device?.uid ?? "", "name": device?.name ?? "",
            "engine_output_sample_rate": engine.outputNode.outputFormat(forBus: 0).sampleRate]
        if rateStatus == noErr { result["nominal_sample_rate"] = rate }
        if frameStatus == noErr { result["io_buffer_frames"] = frames }
        if rateStatus == noErr, frameStatus == noErr, rate > 0 {
            result["io_quantum_ms"] = Double(frames) / rate * 1000
        }
        return result
    }

    private func renderProbe(_ player: AVAudioPlayerNode) -> NativeSpeechRenderProbe {
        let render = player.lastRenderTime
        let time = render.flatMap { player.playerTime(forNodeTime: $0) }
        return NativeSpeechRenderProbe(observedHostTime: mach_absolute_time(),
            renderHostTime: render.flatMap { $0.isHostTimeValid ? $0.hostTime : nil },
            playerFrame: time?.sampleTime, playerSampleRate: time?.sampleRate)
    }
    #endif

    var epoch: String { cursor?.epoch ?? "" }
    var receivedSequence: Int { cursor?.receivedSequence ?? 0 }
    var isPlaying: Bool { engine?.isRunning == true && node?.isPlaying == true && !pending.isEmpty }
    var renderedFrame: AVAudioFramePosition {
        guard let node, let time = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: time) else { return 0 }
        return max(0, playerTime.sampleTime)
    }
    /// Observation only: compensate for the render pipeline before selecting a
    /// subtitle. A negative position means the first sound has not reached output.
    var subtitlePresentedFrame: AVAudioFramePosition? {
        guard let node, node.isPlaying, let time = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: time) else { return nil }
        let latency = node.outputPresentationLatency
        guard latency.isFinite, latency >= 0, latency < 60 else { return nil }
        return playerTime.sampleTime - AVAudioFramePosition(ceil(latency * 24000))
    }
    var bufferedMilliseconds: Double {
        let rendered = renderedFrame
        return Double(pending.reduce(AVAudioFramePosition(0)) { $0 + max(0, $1.end - max($1.start, rendered)) }) / 24
    }
    var completeSentence: Bool { cursor?.completeSentence ?? true }
    var drained: Bool { pending.isEmpty && receivedSequence == playedSequence && completeSentence }

    func start(outputUID: String, epoch: String, cursor: Int) throws {
        stop()
        self.cursor = try NativeSpeechCursor(epoch: epoch, cursor: cursor)
        playedSequence = cursor
        let audio = AVAudioEngine(), player = AVAudioPlayerNode()
        if outputUID != "default" {
            guard let selected = try AudioDevices.outputs().first(where: { $0.uid == outputUID }),
                  let unit = audio.outputNode.audioUnit else { throw ServiceError.message("所选朗读输出设备不可用。") }
            var id = selected.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
            guard status == noErr else { throw ServiceError.message("无法设置朗读输出设备（\(status)）。") }
        }
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        #if NATIVE_PLAYBACK_TESTING
        if let onMixerOutput {
            audio.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: onMixerOutput)
        }
        #endif
        try audio.start()
        engine = audio; node = player
        outputDeviceID = Self.currentOutputDevice(audio)
        let run = generation
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == run else { return }
                do { try self.recoverInitialOutputConfiguration() }
                catch { self.onFailure?(error.localizedDescription) }
            }
        }
    }

    private static func currentOutputDevice(_ audio: AVAudioEngine) -> UInt32? {
        guard let unit = audio.outputNode.audioUnit else { return nil }
        var id: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &id, &size) == noErr else { return nil }
        return id
    }

    private func recoverInitialOutputConfiguration() throws {
        guard let audio = engine, let selected = outputDeviceID else {
            throw ServiceError.message("所选朗读输出设备不可用。")
        }
        let available = try AudioDevices.outputs().contains { $0.id == selected }
        try NativeSpeechStartupRecovery.recover(
            deviceAvailable: available && Self.currentOutputDevice(audio) == selected,
            isRunning: audio.isRunning, hasScheduledAudio: !scheduledChunks.isEmpty,
            attempts: &startupRecoveryAttempts) { try audio.start() }
    }

    func accept(_ snapshot: NativeSpeechSnapshot) throws {
        // A poll may arrive before the queued configuration notification.
        if let engine, !engine.isRunning { try recoverInitialOutputConfiguration() }
        guard let node, let engine, engine.isRunning, var candidate = cursor else {
            throw ServiceError.message("本机朗读播放器尚未就绪。")
        }
        let chunks = try candidate.accept(snapshot)
        let incomingMs = chunks.reduce(0) { $0 + $1.duration_ms }
        guard bufferedMilliseconds + incomingMs <= 120000 else { throw ServiceError.message("本机待播音频过多，已停止以避免漏读。") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        var buffers: [AVAudioPCMBuffer] = []
        for chunk in chunks {
            let frames = chunk.pcm.count / 2
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let output = buffer.floatChannelData?[0] else { throw ServiceError.message("无法分配朗读音频缓冲。") }
            buffer.frameLength = AVAudioFrameCount(frames)
            chunk.pcm.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in 0..<frames {
                    let word = UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8
                    output[i] = Float(Int16(bitPattern: word)) / 32768
                }
            }
            buffers.append(buffer)
        }
        cursor = candidate
        let run = generation
        for (chunk, buffer) in zip(chunks, buffers) {
            #if NATIVE_PLAYBACK_TESTING
            let chosenProbe = renderProbe(node)
            let rendered = max(0, chosenProbe.playerFrame ?? 0)
            let wasPlaying = node.isPlaying
            #else
            let rendered = renderedFrame
            #endif
            // Schedule adjacent blocks at exactly the same sample boundary. When
            // starved, add only one render-quantum margin rather than a carrier.
            let start = NativeSpeechSchedule.start(previousEnd: scheduledEnd, rendered: rendered, playing: node.isPlaying)
            let end = start + AVAudioFramePosition(buffer.frameLength)
            pending.append(Scheduled(seq: chunk.seq, start: start, end: end))
            scheduledEnd = end
            var subtitleSchedule: [String: Any] = ["seq": chunk.seq, "sentence_id": chunk.sentence_id,
                                    "source_order": chunk.source_order, "revision": chunk.revision,
                                    "index": chunk.index, "count": chunk.count, "text": chunk.text,
                                    "start_frame": start, "end_frame": end,
                                    "created_at_ms": chunk.created_at_ms,
                                    "scheduled_at_ms": Date().timeIntervalSince1970 * 1000]
            if let sentence = chunk.sentence_text { subtitleSchedule["sentence_text"] = sentence }
            scheduledChunks.append(subtitleSchedule)
            if scheduledChunks.count > 256 { scheduledChunks.removeFirst() }
            #if NATIVE_PLAYBACK_TESTING
            let submittingProbe = renderProbe(node)
            #endif
            node.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: start, atRate: 24000), options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run else { return }
                    self.pending.removeAll { $0.seq == chunk.seq }
                    self.completed.insert(chunk.seq)
                    while self.completed.remove(self.playedSequence + 1) != nil { self.playedSequence += 1 }
                }
            }
            #if NATIVE_PLAYBACK_TESTING
            let submittedHostTime = mach_absolute_time()
            onScheduleProbe?(NativeSpeechScheduleProbe(sequence: chunk.seq,
                startFrame: start, endFrame: end, playing: wasPlaying,
                chosen: chosenProbe, submitting: submittingProbe,
                submittedHostTime: submittedHostTime,
                presentationLatency: node.outputPresentationLatency))
            // Observers may hash/scan PCM. Run them after enqueueing, so test
            // instrumentation cannot consume this block's scheduling margin.
            onPCMChunk?(chunk)
            #endif
        }
        if !chunks.isEmpty && !node.isPlaying { node.play() }
    }

    func stop() {
        generation = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        node?.stop(); engine?.stop(); node = nil; engine = nil; cursor = nil
        outputDeviceID = nil; startupRecoveryAttempts = 0
        scheduledEnd = 0; playedSequence = 0; pending.removeAll(); completed.removeAll(); scheduledChunks.removeAll()
    }
}
